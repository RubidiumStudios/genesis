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
# an ordinary deploy of the same tree still prints both warnings; the
# exit-code row beside each of that subtest's two runs; and all five rows of
# the third subtest, which are the provider gate and the stale-pipeline
# warning a redeploy keeps, the exit-code row of each of its own two runs
# among them.  Each of those stands as a guard, holding still the behaviour a
# narrower redeploy must not have taken out with it.
#
# The fourth subtest is T242's, and it says the same thing about itself.
# Three of the seven rows it was written with were red and four were green.
# The red ones are the child count after the redeploy, the row that reads the
# run's own output for a propagation report, and the count after the ordinary
# deploy, which found two children rather than one because the redeploy had
# spawned one of its own.  Withholding the child from a redeploy is what turns
# all three green.
#
# The four that arrived green are guards.  The exit row and the restoration
# row say the redeploy reached its end and put the operator back on the
# branch they started on, and they are what keep the two absence rows beside
# them honest, since a run that died early would say nothing about
# propagation either.  The shuttle row was green because no Genesis command
# has ever written the propagate request queue, and it holds that still
# against an implementation that withheld the child and made a request
# instead.  The marker row was green because the child the hand-off spawns
# today is `genesis propagate <env>`, which the propagate command's usage
# takes no argument for, so it exits 2 without delivering anything; the row
# stands as the guard that catches a hand-off after a redeploy once M15 gives
# that child an argument list the command accepts.
#
# Three rows joined that subtest later, against a tree in which the
# withholding already stood.  The row asking that a --redeploy which resolved
# no commit spawns a child was red there, because the withholding keyed on the
# flag and such a run carries it; keying it on the commit the run resolved is
# what turns it green.  The two restoration rows, beside the ordinary deploy
# and beside that run, arrived green, and they say that the child's one-way
# checkout of control costs a run nothing where the session has already put
# the operator back on control.
#
# A fourth joined them afterwards, the exit row beside that same run, and it
# arrived green.  It is what keeps the child-count row beside it honest, in
# the way every other exit row in this file is, since a run that died before
# it reached the hand-off would spawn no child either and the row would then
# be reading a death as a withholding.
#
# The fifth subtest is T246's, and it says the same thing about itself.  Three
# of its first nineteen rows were red and sixteen were green.  The red ones
# are the three that ask for a flag: redeploy-only on a redeploy, and always
# on each of its two runs.  Reading the repository's setting and folding it
# into the options the deploy forwards is what turns all three green.
#
# The sixteen that arrived green are guards.  The three rows that ask for no
# flag were green because no deploy passed --recreate at all, and they now say
# that a repository which did not ask for one is still not given one.  The
# dry-run row was green because no repository setting reached the options, and
# it now says that the setting is read below the guard which refuses more than
# one of fix, recreate, and dry-run, so a repository set to always can still
# be asked what a deploy would do.  The exit row beside each of the six full
# deploys and the restoration row each of them asserts were green throughout,
# and they are what keep the flag rows honest: each flag row reads the last
# call the harness director was given, and a run that died before reaching
# BOSH would leave the run before it standing as the last.
#
# Three rows joined that subtest afterwards, which are the --fix run's own
# three.  The flag row among them was red when it was written, red having
# been produced by letting the operator's --fix suppress the repository's
# recreate, and the narrowing was undone afterwards.  The exit row and the
# restoration row beside that run arrived green, and they are guards of the
# same kind as the six deploys' own, since a run that died before it reached
# BOSH would leave the run before it standing as the last call the flag row
# reads.
#
# Three more joined it later still.  The row reading --recreate off the dry
# run's own argument list arrived green, because the setting already reached
# the options above the guard, and red was produced for it by making
# _recreate_wanted answer 0 on a dry run and undone afterwards; it says that a
# dry run is given the flag as well as the exit, which is what the exit row
# beside it cannot say on its own.  The row asking that redeploy-only gives
# nothing to a --redeploy which resolved no commit was red when it was
# written, red having been produced by keying that setting on the flag the
# operator typed rather than on the commit the run resolved, and that
# narrowing was undone afterwards too.  The exit row beside its own run
# arrived green, as every other exit row here did.
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
	# Five rows, and one more for each of the two runs' own restoration
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
	# The gate's own sentence, rather than the bare word, which the deploy
	# says in a dozen other places and which a refusal for some other reason
	# would match just as well.
	like(unfolded($gerr), qr/The concourse pipeline owns deploys of this environment/,
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


# Proves T242: a successful --redeploy under the manual provider spawns no
# propagate child, which the rows assert by finding no second genesis process
# and no propagation report, and it makes no run_propagate request either.
#
# What the rows catch: an implementation that handed off after every deploy,
# which the child-count row catches and which the ordinary deploy at the end
# shows is still the behaviour a deploy without the flag gets; one that
# withheld the child but wrote a request to the queue instead, which the
# shuttle row catches; and one that withheld neither, which would leave the
# downstream environment holding content the redeploy never certified, which
# the marker row catches.
#
# The downstream environment is delivered nothing by the seeding and carries
# its init commit alone, so the marker row reads a branch a hand-off really
# would have written to rather than one that was already full.
subtest 'a successful redeploy propagates nothing' => sub {
	# Eight rows, and one more for each of the three runs' own restoration
	# assertions.
	plan tests => 11;

	# Both environments are stood up and only qa is delivered to and
	# certified, so prod's branch carries the init commit alone and a
	# delivery made to it is one this subtest can see.  chained names qa as
	# prod's predecessor, which is the edge a cascade walks.
	my $h = ready_harness(
		envs      => ['qa', 'prod'],
		chained   => 1,
		bosh      => 1,
		delivered => ['qa'],
		certified => ['qa'],
	);
	child_recorder($h);
	my $shuttle = shuttle_spy($h);

	# The seeding certifies without naming a deployed commit, and a redeploy
	# of an environment that names none resolves nothing and deploys the tip,
	# which is the one run this subtest cannot be made of.  So the record is
	# written again over the delivery the seeding made, naming the commit
	# that delivery put on the branch and the control commit its own marker
	# names.
	my $deployed = tip_of($h, $h->slug('qa'));
	certify($h, 'qa',
		commit         => $deployed,
		control_commit => harness_marker($h, $h->slug('qa')));

	# The director's record stands at the environment's own exodus path, and
	# a deploy that reaches its end writes the environment's exodus data over
	# it, so the second run below would find no director.  The url is read
	# off the record the builder wrote, because it names the port the harness
	# listener took and no row can know that port in advance.
	my $url = record_at($h, $h->env_path('qa'))->{url};

	stand_on($h, $h->control);
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'deploy', '--redeploy', '-y');

	is($exit, 0, 'the redeploy succeeded')
		or diag("what the redeploy said:\n$err");

	is(scalar(grep {($_->{argv}[0] // '') eq 'propagate'} child_runs($h)), 0,
		'no second genesis process ran propagate')
		or diag("what the redeploy said:\n$err");
	# The two sentences the hand-off itself prints, rather than the bare word,
	# because the harness kit is called genesis-propagation-harness and the
	# secrets check names it on every run.  Both are matched with their case,
	# since each of them opens a line of Genesis' own.
	unlike("$out$err", qr/Propagating to downstream|Propagation failed/,
		'the run printed no propagation report');
	is(scalar(shuttle_requests($shuttle)), 0,
		'no run_propagate request was made');

	# prod is downstream and stays where it was, since nothing was delivered.
	# The row is true of the tree this subtest starts from, because the child
	# the hand-off spawns is `genesis propagate <env>` and the propagate
	# command's usage takes no argument, so today's child refuses before it
	# delivers anything.  It is here as the guard that catches a hand-off after
	# a redeploy once that child is given an argument list the command accepts,
	# because the marker on prod's branch would then name the control commit
	# the delivery was written from rather than nothing at all.
	is(harness_marker($h, $h->slug('prod')), undef,
		'the downstream environment received nothing');

	# An ordinary deploy in the same fixture does spawn the child, so the row
	# above is about what this run resolved and not about a hand-off nobody
	# ever makes.  The child does check control out one way, but the session
	# has already put the operator back on control by the time it runs and
	# this subtest started there, so the checkout is a no-op and the run
	# restores like any other.  That row is a guard rather than a discovery.
	fixture_director($h, 'qa', url => $url);
	run_genesis($h, 'qa', 'deploy', '-y');
	is(scalar(grep {($_->{argv}[0] // '') eq 'propagate'} child_runs($h)), 1,
		'an ordinary manual deploy still spawns one propagate child');

	# And a --redeploy that resolves no commit deploys the tip, hears both
	# warnings about it, and hands off to a child like the ordinary deploy it
	# is.  The row is what holds the two rows above to the commit this run
	# resolved rather than to the flag it was given.  A fresh harness, whose
	# seeding certifies without naming a deployed commit, because the runs
	# above have since written records that name one.
	my $n = ready_harness(envs => ['qa'], bosh => 1);
	child_recorder($n);
	stand_on($n, $n->control);
	my (undef, $nerr, $nexit) =
		run_genesis($n, 'qa', 'deploy', '--redeploy', '-y');
	is($nexit, 0, 'the redeploy that resolved no commit succeeded')
		or diag("what the redeploy said:\n$nerr");
	is(scalar(grep {($_->{argv}[0] // '') eq 'propagate'} child_runs($n)), 1,
		'a redeploy that resolved no commit spawns one too')
		or diag("what the redeploy said:\n$nerr");
};


# Proves T246: three repositories differing only in
# pipeline.recreate_on_deploy, where redeploy-only passes --recreate on a
# redeploy and not on an ordinary deploy, always passes it on both, and the
# default passes it on neither.
#
# What the rows catch: an implementation that read the key on the wrong run,
# which the redeploy-only pair catches in either direction; one that ignored
# the key and read the command line alone, which the always pair catches; one
# that passed --recreate whatever the key said, which the never pair catches;
# and one that folded the answer into the options above the guard that refuses
# more than one of fix, recreate, and dry-run, which the dry run's two rows
# catch in a repository set to always.  The --fix row beside them
# catches the narrower defect of an implementation that let the operator's
# --fix suppress the repository's own recreate, which is the same guard being
# enforced against a value the operator never typed.
#
# Each run has an exit row of its own beside it, and those rows are what keep
# the nine flag rows honest.  Each flag row reads the last call the harness
# director was given, and a run that died before it reached BOSH would leave
# the run before it standing as the last, so a flag row with no exit row
# beside it could read another run's argument list and pass on it.
#
# The last pair of rows is about the one run that carries the flag without the
# operator having asked for it and without being a redeploy either.  A
# --redeploy of an environment whose record names no commit resolves nothing
# and deploys the tip, so redeploy-only owes it nothing, and the row says that
# the setting turns on the commit the run resolved rather than on the flag it
# was given.
subtest 'recreate_on_deploy reaches every deploy as declared' => sub {
	# Nine flag rows, nine exit rows, and one more for each of the eight runs
	# that assert a restoration.  The dry run asserts none, for the reason
	# given beside it.
	plan tests => 26;

	my %flags;
	for my $setting (qw/redeploy-only always never/) {
		# The three repositories differ in this key and in nothing else.  The
		# director, the fake bosh, and the kit go up with the seeding, which
		# is what lets both runs below reach BOSH at all.
		my $h = ready_harness(envs => ['qa'], bosh => 1,
			pipeline => {recreate_on_deploy => $setting});

		# The seeding certifies without naming a deployed commit, and a
		# redeploy of an environment that names none resolves nothing and
		# deploys the tip.  The record is written again over the delivery the
		# seeding made, naming the commit that delivery put on the branch and
		# the control commit its own marker names, so the second run below is
		# a redeploy of something.
		certify($h, 'qa',
			commit         => tip_of($h, $h->slug('qa')),
			control_commit => harness_marker($h, $h->slug('qa')));

		# The director's record stands at the environment's own exodus path,
		# and a deploy that reaches its end writes the environment's exodus
		# data over it, so the second run would find no director.  The url is
		# read off the record the builder wrote, because it names the port the
		# harness listener took and no row can know that port in advance.
		my $url = record_at($h, $h->env_path('qa'))->{url};

		stand_on($h, $h->control);

		# Both runs pass --no-propagate, for the reason the file above gives:
		# the auto-cascade hands off to a child genesis propagate that M15
		# owns and that fails today, and a row about what BOSH was given
		# should not be reading that child's failure as the deploy's.
		my (undef, $err, $exit) = run_genesis($h,
			'qa', 'deploy', '--no-propagate', '-y');
		is($exit, 0, "the ordinary deploy proceeded under $setting")
			or diag("what the deploy said:\n$err");
		my @deploys = bosh_runs($h, command => 'deploy');
		$flags{$setting}{deploy} = join(' ', @{$deploys[-1]{argv}});

		fixture_director($h, 'qa', url => $url);
		my (undef, $rerr, $rexit) = run_genesis($h,
			'qa', 'deploy', '--redeploy', '--no-propagate', '-y');
		is($rexit, 0, "the redeploy proceeded under $setting")
			or diag("what the redeploy said:\n$rerr");
		@deploys = bosh_runs($h, command => 'deploy');
		$flags{$setting}{redeploy} = join(' ', @{$deploys[-1]{argv}});
	}

	unlike($flags{'redeploy-only'}{deploy}, qr/--recreate/,
		'redeploy-only passes nothing on an ordinary deploy');
	like($flags{'redeploy-only'}{redeploy}, qr/--recreate/,
		'redeploy-only passes --recreate on a redeploy');

	like($flags{always}{deploy}, qr/--recreate/,
		'always passes --recreate on an ordinary deploy');
	like($flags{always}{redeploy}, qr/--recreate/,
		'always passes --recreate on a redeploy');

	unlike($flags{never}{deploy}, qr/--recreate/,
		'never passes nothing on an ordinary deploy');
	unlike($flags{never}{redeploy}, qr/--recreate/,
		'never passes nothing on a redeploy');

	# A repository that always recreates still gets to ask what a deploy
	# would do, because the setting is not something the operator typed.
	my $g = ready_harness(envs => ['qa'], bosh => 1,
		pipeline => {recreate_on_deploy => 'always'});
	stand_on($g, $g->control);

	# A dry run leaves the deployment cache directory behind, because
	# _post_deploy says the post-deployment activities are skipped and exits
	# there, above the cleanup that would have taken it away.  The run is
	# therefore told not to assert a restoration it cannot make, and the tree
	# it leaves is nothing this task changed.
	my (undef, $gerr, $dry_exit) = run_genesis($g, {restore => 0},
		'qa', 'deploy', '--dry-run', '--no-propagate', '-y');
	is($dry_exit, 0, 'a repository set to always still allows a dry run')
		or diag("what the dry run said:\n$gerr");

	# The exit row above says the guard let the run through; this one says
	# what the run then asked BOSH for.  A dry run reaches bosh deploy like
	# any other, only a create-env deployment skipping that call, so the
	# setting rides in the dry run's own argument list and the operator sees
	# what a real deploy would be given.
	my @dry_deploys = bosh_runs($g, command => 'deploy');
	like(join(' ', @{$dry_deploys[-1]{argv}}), qr/--recreate\b/,
		'always passes --recreate to a dry run as well')
		or diag("what the dry run said:\n$gerr");

	# The setting rides beside --fix exactly as it rides beside --dry-run,
	# because BOSH accepts both combinations and the guard is about what the
	# operator asked for.  What this row catches that the dry run does not is
	# an implementation that let the operator's --fix suppress the
	# repository's own recreate, which would read as the guard being enforced
	# against a value the operator never typed.  Its own repository, because
	# the dry run above leaves a deployment cache directory behind and this
	# run asserts the restoration the dry run cannot.
	my $f = ready_harness(envs => ['qa'], bosh => 1,
		pipeline => {recreate_on_deploy => 'always'});
	stand_on($f, $f->control);

	my (undef, $ferr, $fix_exit) = run_genesis($f,
		'qa', 'deploy', '--fix', '--no-propagate', '-y');
	is($fix_exit, 0, 'a repository set to always still allows --fix')
		or diag("what the --fix deploy said:\n$ferr");

	my @fix_deploys = bosh_runs($f, command => 'deploy');
	like(join(' ', @{$fix_deploys[-1]{argv}}), qr/--fix\b.*--recreate\b|--recreate\b.*--fix\b/,
		'always passes --recreate beside the operator\'s --fix');

	# The three repositories above are each re-certified with the commit
	# their delivery put on the branch, so every redeploy in them resolves
	# one.  This repository is left as the seeding made it, certified without
	# a deployed commit named, so the --redeploy below resolves nothing and
	# deploys the tip.  Such a run is an ordinary deploy in every way that
	# matters, and redeploy-only is what the design gives to a redeploy, so
	# the row asks for no flag.  It is what holds the setting to the commit
	# the run resolved rather than to the flag the operator typed.
	my $s = ready_harness(envs => ['qa'], bosh => 1,
		pipeline => {recreate_on_deploy => 'redeploy-only'});
	stand_on($s, $s->control);

	my (undef, $serr, $sexit) = run_genesis($s,
		'qa', 'deploy', '--redeploy', '--no-propagate', '-y');
	is($sexit, 0, 'a redeploy that resolved no commit proceeded')
		or diag("what the redeploy said:\n$serr");

	my @tip_deploys = bosh_runs($s, command => 'deploy');
	unlike(join(' ', @{$tip_deploys[-1]{argv}}), qr/--recreate\b/,
		'redeploy-only passes nothing where the redeploy resolved no commit')
		or diag("what the redeploy said:\n$serr");
};


done_testing;

# vim: ts=2 sw=2 sts=2 noet
