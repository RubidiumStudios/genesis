#!/usr/bin/env perl
# Proves T240: with a record naming a qa/bosh commit older than the tip,
# --redeploy checks that commit out detached inside the session, deploys it
# rather than the tip, writes a fresh record naming the same two hashes, and
# restores the operator's starting branch at finish.
#
# What the rows catch: an implementation that deployed the tip under the flag,
# which puts the coming content in the manifest; one that moved the certified
# commit on a redeploy, which the control-commit row catches and which would
# wake every dependent for content that never moved; one that overwrote the
# previous record rather than adding to the set, which the count row catches;
# and one that never told the operator it was redeploying something other than
# what they have on their branch.
#
# Four of the first subtest's eight rows were red when it was written and four
# were green, and it says which were which rather than reading as a proof of
# everything below it.  The exit row, the sentence row, the row asking what
# BOSH received, and the record-count row were red, and all four were red for
# one reason: the pre-flight asked whether it was standing on the deployment
# branch by name, a redeploy stands detached on a commit of that branch, and
# so every redeploy was refused as a branch carrying no repository.  Widening
# that question to accept a resolved commit is what lets the run reach BOSH,
# and the notice in the deploy's pre-flight is what turns the sentence row
# green.
#
# The four that arrived green are guards, each holding still a behaviour the
# steps after this one must not change.  The row that the undeployed content
# never reached BOSH was green because nothing reached BOSH at all, and it now
# says the tip's content stays out of the manifest.  The two record rows were
# green because the refusal wrote no record and the seeded one already named
# both hashes, and they now say a redeploy records the same deployed commit
# and moves no certified commit.  The restoration row was green because a
# refusal restores the working state as a success does, and it now says finish
# puts the operator back on the branch they started on.
#
# The kit is the one fixture_bosh builds rather than a named kit of this
# file's own, which is what the deployed-commit file does for the same reason:
# the two manifest rows read a marker the blueprint hook prints, and that hook
# is given to the builder's kit.
#
# The two subtests below it are T241's, and they say the same thing about
# themselves.  The two silence rows of the first were red, and the one caller
# of the three warnings is what turns them green.  Everything else there was
# green on arrival: the row that reads the notice back, which keeps the two
# silence rows honest about what the run resolved; the two rows asserting that
# an ordinary deploy of the same tree still prints both warnings; the five
# rows of the second subtest, which are the provider gate and the
# stale-pipeline warning a redeploy keeps; and the exit-code row beside each
# run.  Each of those stands as a guard, holding still the behaviour a
# narrower redeploy must not have taken out with it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the redeploy deploys the recorded commit and not the tip' => sub {
	plan tests => 8;

	# The discriminator is a marker line in the environment file, read and
	# printed by the kit's blueprint hook on its way to writing a manifest,
	# which is how the deploy's own output names the version it rendered.
	# The manifest itself is the harness kit's fixed two lines, so a row
	# asking what BOSH received asks the hook that read the tree rather than
	# a manifest that says the same thing whichever commit it was rendered
	# from.
	my $deployed_env = <<'YAML';
---
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      qa
params:
  marker: the-deployed-version
YAML
	my $tip_env = <<'YAML';
---
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      qa
params:
  marker: the-coming-version
YAML

	my $h = make_harness(envs => ['qa'], type => 'bosh');

	my $control = commit_on_control($h,
		files   => {'qa.yml' => $deployed_env},
		message => 'the certified content',
		push    => 1,
	);
	init_branch($h, 'qa');
	my $deployed = deliver($h, 'qa', control => $control);
	certify($h, 'qa', commit => $deployed, control_commit => $control);

	my $later = commit_on_control($h,
		files   => {'qa.yml' => $tip_env},
		message => 'the undeployed content',
		push    => 1,
	);
	deliver($h, 'qa', control => $later);
	refresh($h, 'a');

	# The director, the bosh, and the kit a whole deploy needs, with a
	# blueprint hook that prints the marker of the tree it ran in.  The
	# builder's catch-up brings the operator's copy of the deployment branch
	# up to the delivery, which is what a pull would have done, and it runs
	# before the row stands anywhere.
	fixture_bosh($h,
		hooks => {
			blueprint =>
				qq{grep '^  marker:' "\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml" >&2\n}.
				qq{cat > manifest.yml <<'MANIFEST'\n---\nharness: deployed\nMANIFEST\n}.
				qq{echo manifest.yml\n},
		},
	);

	stand_on($h, $h->control);
	my $before = snapshot_w($h);

	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '--redeploy', '--no-propagate', '-y');

	is($exit, 0, 'the redeploy succeeded')
		or diag("what the redeploy said:\n$err");

	# Genesis prints its notices through the log, which is standard error, so
	# the sentence is read off both streams together rather than off standard
	# output alone.
	like("$out$err", qr/\Q$deployed\E/,
		'the run says which commit it is redeploying');

	like("$out$err", qr/marker:\s*the-deployed-version/,
		'BOSH received the content of the commit that was running');
	unlike("$out$err", qr/marker:\s*the-coming-version/,
		'BOSH did not receive the undeployed content');

	my $records = $h->env_path('qa') . '/deployments';
	is(scalar(@{record_keys($h, $records)}), 2,
		'a fresh record was written beside the first');

	my $newest = newest_record($h, $records);
	is($newest->{git}{commit}, $deployed,
		'the fresh record names the same deployed commit');
	is($newest->{git}{control_commit}, $control,
		'the certified commit did not move');

	assert_w_restored($before, 'finish restored the branch the operator started on');
};

# Proves T241: a redeploy prints neither the due-commits warning nor the
# drifted warning, both of which describe the branch tip that a redeploy is
# not shipping, while an ordinary deploy of the same tree prints both.
#
# What the rows catch: an implementation that skipped no warning, which the
# two silence rows catch; and one that skipped them for every deploy rather
# than for a run that resolved a deployed commit, which the ordinary deploy
# in the same tree catches.
#
# Both silence rows are backed by two rows beside them, so a run that said
# nothing for a reason of its own cannot pass them.  The exit code says the
# run reached its end rather than dying before the warnings, and the notice
# the step above the warnings prints says the run resolved a deployed commit
# rather than falling back to the tip.
subtest 'the redeploy skips the two warnings about the tip' => sub {
	# Seven rows, and one more for each of the two runs' own restoration
	# assertions.
	plan tests => 9;

	# due_harness seeds the environment, delivers it, certifies it, and then
	# lays two control commits that write the environment's own file, so both
	# route to qa and neither has reached its branch.  bosh => 1 stands the
	# director, the fake bosh, and the kit up before the seeding, which is
	# what lets each run below reach its end.
	my ($h) = due_harness(bosh => 1);

	# The seeding certifies the environment without naming a deployed
	# commit, and a redeploy of an environment that names none resolves
	# nothing and deploys the tip, which is the one run this subtest cannot
	# be made of.  So the record is written again over the delivery the
	# seeding made, naming the commit that delivery put on the branch and the
	# control commit that commit's own marker names.
	my $deployed = tip_of($h, $h->slug('qa'));
	certify($h, 'qa',
		commit         => $deployed,
		control_commit => harness_marker($h, $h->slug('qa')));

	# And the branch has drifted as well, so one tree holds both of the
	# states this subtest is about.  The hand commit edits the one member of
	# the propagation set a row may safely edit, which is the environment's
	# own file, and it keeps what that file already said, because an
	# environment replaced wholesale is one no deploy can read.
	#
	# It is made in the operator's own copy rather than in the teammate's,
	# which is where the hatch is usually opened, because the redeploy below
	# stands detached and makes no fast-forward.  A hand commit this clone
	# had not pulled would leave the drifted warning reading the branch as
	# the delivery left it, and the silence row would then pass over a branch
	# that had not drifted at all.
	my $drifted = edited_file($h, 'qa');
	my $was     = blob_at($h->a, $h->slug('qa'), $drifted)
		// die "the branch carries no $drifted to edit\n";
	hand_commit($h, $h->slug('qa'), copy => 'a',
		files   => {$drifted => $was."\n# opened by hand during the incident\n"},
		message => 'open the hatch');
	stand_on($h, $h->control);
	refresh($h, 'a', $h->control, $h->slug('qa'));

	# The director's record stands at the environment's own exodus path, and
	# a deploy that reaches its end writes the environment's exodus data over
	# it, so the second run below would find no director at all.  The url is
	# read off the record the builder wrote, because it names the port the
	# harness listener took and no row can know that port in advance.
	my $url = record_at($h, $h->env_path('qa'))->{url};

	# Every run passes --no-propagate, for the reason the file above gives:
	# the auto-cascade hands off to a child genesis propagate that M15 owns
	# and that fails today, and a row about what the deploy said should not
	# be reading the child's failure as the deploy's.
	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--redeploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the redeploy proceeded')
		or diag("what the redeploy said:\n$err");
	# The notice the step above the warnings prints, and the guard that
	# keeps the two silence rows honest.  It prints only where a deployed
	# commit was resolved, so a fixture whose record named none would deploy
	# the tip, both warnings would be right to print, and this row rather
	# than those two would say so.
	like(unfolded($err), qr/at its deployed commit/,
		'the redeploy resolved the recorded commit and says so')
		or diag("what the redeploy said:\n$err");
	unlike(unfolded($err), qr/commits? due to/,
		'the due-commits warning is skipped')
		or diag("what the redeploy said:\n$err");
	unlike(unfolded($err), qr/differs from/,
		'and so is the drifted warning')
		or diag("what the redeploy said:\n$err");

	# The same tree, the same two states, and no flag.  The phrase read for
	# the due warning is the warning's own opening rather than the bare word
	# due, because the commit subjects this harness lays carry that word too.
	fixture_director($h, 'qa', url => $url);
	my (undef, $plain, $plain_exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($plain_exit, 0, 'the ordinary deploy proceeded')
		or diag("what the deploy said:\n$plain");
	like(unfolded($plain), qr/commits? due to/,
		'an ordinary deploy still warns about the commits due')
		or diag("what the deploy said:\n$plain");
	like(unfolded($plain), qr/differs from/,
		'and still warns that the branch drifted')
		or diag("what the deploy said:\n$plain");
};

# Proves the other half of T241: the two checks a redeploy keeps.  The
# provider gate still refuses it, because a redeploy under an automated
# provider still does the pipeline's work without taking the pipeline's
# locks; and the stale-pipeline warning still prints, because a pipeline
# whose definition has moved is stale whichever commit is being deployed.
#
# Both rows were green on arrival, and they are stated as such.  Nothing in
# this task touches the gate, and the wrong implementation nearest to hand is
# one that reads "a redeploy is narrower" as licence to skip everything the
# pre-flight would otherwise say, which is what these hold still.
#
# The second run carries GENESIS_PIPELINE_TASK, which is the one way a
# spawned command gets past an automated provider's gate: --force needs a
# terminal to take the acknowledgement from, and
# Genesis::Term::in_controlling_terminal answers false for every run this
# suite makes, as t/integration-tests/genesis_commands_env-deploy_provider_gate.t
# records.  The gate is step 7 of the pre-flight and the warning is step 9,
# so a run the gate refuses never reaches the warning to be read for it.
subtest 'the redeploy keeps the provider gate and the stale warning' => sub {
	# Four rows, and one more for each of the two runs' own restoration
	# assertions.
	plan tests => 7;

	my $g = ready_harness(envs => ['qa'], bosh => 1, provider => 'concourse');

	# The one thing that moves the repository out of step with its own
	# applied record.  The environment's own file is a pipeline-defining
	# path, and this writes it on control alone, so the change is one only a
	# reader of control can see.  It is written through the harness, so what
	# lands is a file Genesis can still read.
	write_env_file($g, 'qa', pipeline => {require_pr => 'true'});
	push_from($g, 'a', $g->control);
	refresh($g, 'a', $g->control);

	my (undef, $gerr, $gexit) = run_genesis($g,
		'qa', 'deploy', '--redeploy', '--no-propagate', '-y', 'r');

	is($gexit, Genesis::Exit::NOPERM,
		'the provider gate still refuses the redeploy')
		or diag("what the redeploy said:\n$gerr");
	like(unfolded($gerr), qr/pipeline/,
		'naming the pipeline that owns the deploy')
		or diag("what the redeploy said:\n$gerr");

	my (undef, $jerr, $jexit) = run_genesis($g, {pipeline_task => 'deploy-qa'},
		'qa', 'deploy', '--redeploy', '--no-propagate', '-y', 'r');

	is($jexit, 0, 'the redeploy proceeded past the gate inside a pipeline job')
		or diag("what the redeploy said:\n$jerr");
	like(unfolded($jerr), qr/genesis pipeline-apply/,
		'and the stale-pipeline warning still names the remedy')
		or diag("what the redeploy said:\n$jerr");
	like(unfolded($jerr), qr/\bqa: configuration-changed\b/,
		'naming the environment whose shape changed and why it changed')
		or diag("what the redeploy said:\n$jerr");
};


done_testing;

# vim: ts=2 sw=2 sts=2 noet
