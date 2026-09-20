#!/usr/bin/env perl
# Proves T243: each of the four commands takes the target its registration
# declares, which is the deployed commit for info and the bosh subcommands,
# the branch tip for deploy, and the deployed commit for the secrets family
# only where --as-deployed opts it in.
#
# Proves T244: both flags refuse at Genesis::Exit::CONFIG when the pipeline is
# not enabled, each naming the recorded deployed commit and the session that
# opens only under a pipeline, and each writes nothing.
#
# Proves T245: a record naming a commit the repository can no longer reach is
# refused by name at Genesis::Exit::DATAERR, naming the record as well as the
# commit, with nothing deployed and the working tree left as it was.
#
# What the rows catch: an implementation that declared the two flags and left
# them inert, which exits 0 rather than CONFIG; one that refused with a bare
# usage error, which exits 2 and names neither the record nor the session; one
# that refused every use of the flags rather than the ones outside a pipeline,
# which the enabled-pipeline row at the end of the first subtest catches; and
# one that gave each flag its own wording, which the second subtest catches by
# comparing the two sentences.
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

subtest 'both flags refuse where the pipeline is not enabled' => sub {
	plan tests => 11;

	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0', pipeline => 0);
	init_branch($h, 'qa');
	certify($h, 'qa',
		commit         => 'deadbee',
		control_commit => 'cafef00',
	);
	stand_on($h, $h->control);

	my $before = snapshot_w($h);

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'qa', 'deploy', '--redeploy');
	is($exit, Genesis::Exit::CONFIG, 'the redeploy exits CONFIG');
	like($err, qr/deployed commit is recorded/,
		'the redeploy says the deployed commit is recorded');
	like($err, qr/opens only under a pipeline/,
		'the redeploy names the session that opens only under a pipeline');
	unlike($out, qr/bosh deploy/i, 'nothing reached BOSH');
	assert_w_restored($before, 'the redeploy left working state alone');

	($out, $err, $exit) = run_genesis($h, {restore => 0}, 'qa', 'info', '--as-deployed');
	is($exit, Genesis::Exit::CONFIG, 'the info run exits CONFIG');
	like($err, qr/deployed commit is recorded/,
		'the info run says the deployed commit is recorded');
	like($err, qr/opens only under a pipeline/,
		'the info run names the session that opens only under a pipeline');
	assert_w_restored($before, 'the info run left working state alone');

	# The same flag in a repository whose pipeline is on, so that the two
	# refusals above are about the pipeline being off and not about a flag
	# the parser never heard of.  Green before the flags existed, when an
	# unknown option exited at the usage error rather than at CONFIG, and a
	# guard rather than a proof.  What it catches is a refusal written to
	# meet every use of the flags rather than the ones outside a pipeline.
	my $g = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $gc = commit_on_control($g,
		files   => {'ops/base.yml' => "---\nversion: one\n"},
		message => 'the certified content',
		push    => 1,
	);
	init_branch($g, 'qa');
	deliver($g, 'qa', control => $gc);
	refresh($g, 'a');
	stand_on($g, $g->control);

	my (undef, undef, $on_exit) = run_genesis($g, 'qa', 'info', '--as-deployed');
	isnt($on_exit, Genesis::Exit::CONFIG,
		'the same flag under an enabled pipeline meets no such refusal');
};

subtest 'the two flags share one help sentence' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);

	# Genesis renders help through the log, which is standard error, so the
	# two sentences are read off the second return value and not the first.
	my (undef, $deploy_help) = run_genesis($h, 'qa', 'deploy', '--help-full');
	my (undef, $info_help)   = run_genesis($h, 'qa', 'info', '--help-full');

	my ($deploy_sentence) = $deploy_help =~ /--redeploy\s+(.*?)(?:\n\s*\n|\z)/s;
	my ($info_sentence)   = $info_help   =~ /--as-deployed\s+(.*?)(?:\n\s*\n|\z)/s;

	ok(defined $deploy_sentence, 'the deploy help carries --redeploy');
	ok(defined $info_sentence, 'the info help carries --as-deployed');

	# Green on arrival, because both captures were undefined before the
	# flags existed and two undefined captures squash to one empty string.
	# It stands as a guard on the one constant.  What it catches is a step
	# that gives each flag a wording of its own.
	my $squash = sub { my $t = shift // ''; $t =~ s/\s+/ /g; $t =~ s/^\s|\s$//g; $t };
	is($squash->($info_sentence), $squash->($deploy_sentence),
		'both flags print the same sentence about the deployed commit');
};

subtest 'each command takes the target its registration declares' => sub {
	plan tests => 17;

	# The discriminator is a line in the environment file rather than a
	# printed sha, because no command in this family prints the commit its
	# tree is standing on and a row asserting that it did would assert
	# nothing.  The two versions of the file name two different directors
	# and carry two different markers, so each command below says which of
	# the two it served in its own output.
	my $deployed_env = <<'YAML';
---
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      qa
  bosh_env: deployed-director
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
  bosh_env: coming-director
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

	# Both directors are written, and both answer, because a row that made
	# one of them unreachable would read a refusal where it means to read a
	# choice.  The two hooks are the kit's own reading of the working tree:
	# the info hook prints the marker the tree it was run in carries, and the
	# blueprint hook says the same thing on its way to writing a manifest,
	# which is how the deploy's own output names the version it rendered.
	# The kit is untracked, so it is the same kit on every branch while the
	# file it reads is not.  The builder's catch-up brings the operator's
	# copy of the deployment branch up to the delivery, which is what a
	# pull would have done, and it runs before the row stands anywhere.
	fixture_bosh($h,
		envs  => ['qa', 'deployed-director', 'coming-director'],
		hooks => {
			info      => qq{grep '^  marker:' "\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml"\n},
			blueprint =>
				qq{grep '^  marker:' "\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml" >&2\n}.
				qq{cat > manifest.yml <<'MANIFEST'\n---\nharness: deployed\nMANIFEST\n}.
				qq{echo manifest.yml\n},
		},
	);
	stand_on($h, $h->control);

	my ($info_out, $info_err, $info_exit) = run_genesis($h, 'qa', 'info');
	is($info_exit, 0, 'the info run succeeded');
	like("$info_out$info_err", qr/marker:\s*the-deployed-version/,
		'info reports the marker the deployed version carries');
	unlike("$info_out$info_err", qr/marker:\s*the-coming-version/,
		'info does not report the marker only the coming version carries');

	# --connect is the one shape of the bosh subcommand that says which
	# director it was pointed at, and it is pointed at it by the environment
	# file in the tree the session stood on.  The director's own answer
	# names neither, because the harness director answers every run alike.
	my ($bosh_out, $bosh_err, $bosh_exit) = run_genesis($h, 'qa', 'bosh', '--connect');
	is($bosh_exit, 0, 'the bosh run succeeded');
	like("$bosh_out$bosh_err", qr/\bdeployed-director\b/,
		'bosh targets the director the deployed version names');
	unlike("$bosh_out$bosh_err", qr/\bcoming-director\b/,
		'bosh does not target the director only the coming version names');

	my ($dep_out, $dep_err, $dep_exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');
	is($dep_exit, 0, 'the deploy succeeded');
	like("$dep_out$dep_err", qr/marker:\s*the-coming-version/,
		'deploy renders the branch tip with no flag');
	unlike("$dep_out$dep_err", qr/marker:\s*the-deployed-version/,
		'deploy does not render the deployed version without --redeploy');

	# The secrets family is pre-deploy by class and opts into the deployed
	# commit with the flag, so its two runs read two different feature sets
	# and write two different credentials.  They need a kit that declares
	# credentials per feature, which the dev kit above does not, so they run
	# against a repository of their own.
	my $deployed_secrets = $deployed_env =~ s/features: \[\]/features: [gh-oauth]/r;
	my $tip_secrets      = $tip_env      =~ s/features: \[\]/features: [cf-uaa]/r;

	my $s = make_harness(envs => ['qa'], type => 'bosh', kit => 'omega-v2.7.0');
	my $s_control = commit_on_control($s,
		files   => {'qa.yml' => $deployed_secrets},
		message => 'the certified content',
		push    => 1,
	);
	init_branch($s, 'qa');
	my $s_deployed = deliver($s, 'qa', control => $s_control);
	certify($s, 'qa', commit => $s_deployed, control_commit => $s_control);

	my $s_later = commit_on_control($s,
		files   => {'qa.yml' => $tip_secrets},
		message => 'the undeployed content',
		push    => 1,
	);
	deliver($s, 'qa', control => $s_later);
	refresh($s, 'a');

	# The kit the harness installed is the one these rows want, so the
	# builder is told to leave it alone; it is called for the catch-up that
	# brings the operator's copy of the deployment branch up to the
	# delivery, without which there is no repository on the branch to switch
	# onto.
	fixture_bosh($s, kit => 0);
	stand_on($s, $s->control);

	my $before = snapshot_w($s);
	run_genesis($s, {restore => 0}, 'qa', 'rotate-secrets', '--as-deployed', '-y');
	ok(record_at($s, '/secret/qa/bosh/auth/github/oauth'),
		'the secrets family opts in with --as-deployed');
	ok(!record_at($s, '/secret/qa/bosh/auth/cf/uaa'),
		'and reads none of the features only the coming version selects');
	assert_w_restored($before, 'finish restored the branch the operator started on');

	run_genesis($s, 'qa', 'rotate-secrets', '-y');
	ok(record_at($s, '/secret/qa/bosh/auth/cf/uaa'),
		'the secrets family stays pre-deploy without the flag');
};

# Proves T245: a record naming a commit a rewritten branch no longer reaches
# refuses by name at Genesis::Exit::DATAERR, with nothing deployed.
#
# What the rows catch: an implementation that switched first and discovered
# the missing commit afterwards, which leaves the tree detached and fails the
# restoration row; one that refused without the record path, which names the
# commit and leaves the operator no record to go and look at; and one that let
# the branch decide, which answers a branch carrying nothing with the deploy's
# own complaint rather than with the refusal about the recorded commit.
subtest 'an unreachable deployed commit refuses by name' => sub {
	plan tests => 8;

	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');

	# Two deliveries, because the rewrite below takes the second one out and
	# the branch has to be left carrying a repository.  A branch holding its
	# init commit alone is the shape the second half of this subtest builds,
	# and reading the two shapes off one fixture would leave neither of them
	# saying which arm answered it.
	my $earlier = commit_on_control($h,
		files   => {'ops/base.yml' => "---\nversion: zero\n"},
		message => 'the content delivered before it',
		push    => 1,
	);
	init_branch($h, 'qa');
	deliver($h, 'qa', control => $earlier);

	my $control = commit_on_control($h,
		files   => {'ops/base.yml' => "---\nversion: one\n"},
		message => 'the content that was deployed',
		push    => 1,
	);
	my $deployed = deliver($h, 'qa', control => $control);
	certify($h, 'qa', commit => $deployed, control_commit => $control);

	# The teammate rewrites the deployment branch on R, so the commit the
	# record names is no longer reachable once copy A refreshes.
	rewrite_branch($h, 'qa/bosh', drop => $deployed);
	refresh($h, 'a');

	stand_on($h, $h->control);
	my $before = snapshot_w($h);

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'qa', 'deploy', '--redeploy');

	is($exit, Genesis::Exit::DATAERR, 'the redeploy exits DATAERR');
	like($err, qr/\Q$deployed\E/, 'the refusal names the commit');
	like($err, qr{/secret/exodus/qa/bosh/deployments},
		'the refusal names the record the commit came from');
	unlike($out, qr/bosh deploy/i, 'nothing was deployed');
	assert_w_restored($before, 'the refusal left working state alone');

	# The same refusal from a branch carrying nothing but what the apply cut,
	# which is the arm the gate answers by running where the operator stands.
	# One delivery here, and the rewrite takes it out, so the branch falls
	# back to its init commit while the record still names the commit that was
	# deployed off it.  A resolved target does not ask the branch what it
	# carries now, because the commit it switches onto carried the repository
	# when it was deployed, so the refusal an operator meets is the one about
	# the commit their record names and not the deploy's own complaint about
	# a branch nothing has been delivered to.
	my $g = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $gc = commit_on_control($g,
		files   => {'ops/base.yml' => "---\nversion: one\n"},
		message => 'the content that was deployed',
		push    => 1,
	);
	init_branch($g, 'qa');
	my $gd = deliver($g, 'qa', control => $gc);
	certify($g, 'qa', commit => $gd, control_commit => $gc);

	rewrite_branch($g, 'qa/bosh', drop => $gd);
	refresh($g, 'a');
	stand_on($g, $g->control);

	my (undef, $gerr, $gexit) = run_genesis($g, {restore => 0},
		'qa', 'deploy', '--redeploy');
	is($gexit, Genesis::Exit::DATAERR,
		'a branch left carrying no repository refuses the same way');
	like($gerr, qr/\Q$gd\E/, 'that refusal names the commit too');
	like($gerr, qr{/secret/exodus/qa/bosh/deployments},
		'and the record the commit came from');
};

# Proves T243's remaining half, which is that the branch the operator is
# standing on does not decide the question once a target has been resolved.
# A command that named a flag, or whose registration declares the deployed
# commit, stands on that commit even from the deployment branch itself, and
# the arm that switches nothing is for the runs that mean the tip.
#
# What the rows catch: an implementation that kept the standing-on-the-branch
# arm ahead of the resolved target, which answers --as-deployed out of the
# working tree and so reads whatever the operator happened to have checked
# out, while saying in its own line that it made no branch change at all.
subtest 'a branch the operator stands on does not decide the target' => sub {
	plan tests => 7;

	# The marker line is the discriminator, as it is above: each hook prints
	# the one the tree it ran in carries, so the output says which version of
	# the file the command read.
	my $deployed_env = <<'YAML';
---
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      qa
  bosh_env: deployed-director
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
  bosh_env: coming-director
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

	# The blueprint hook is here as well as the info hook, because the last
	# rows deploy and the deploy reads its version on the way to a manifest.
	fixture_bosh($h,
		envs  => ['qa', 'deployed-director', 'coming-director'],
		hooks => {
			info      => qq{grep '^  marker:' "\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml"\n},
			blueprint =>
				qq{grep '^  marker:' "\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml" >&2\n}.
				qq{cat > manifest.yml <<'MANIFEST'\n---\nharness: deployed\nMANIFEST\n}.
				qq{echo manifest.yml\n},
		},
	);

	# The operator is standing on the deployment branch itself, which is the
	# arm that opens no session at all where the run targets the tip.
	stand_on($h, 'qa/bosh');

	my ($out, $err, $exit) = run_genesis($h, 'qa', 'info', '--as-deployed');
	is($exit, 0, 'the flagged read succeeds from the deployment branch');
	like("$out$err", qr/marker:\s*the-deployed-version/,
		'the flag is answered from the deployed commit, not the tree stood on');
	unlike("$out$err", qr/marker:\s*the-coming-version/,
		'so the branch tip the operator was standing on is not what it read');

	# The rows above read through info, whose registration already declares
	# the deployed commit, so they show the arm yielding without separating
	# the flag from the default.  The deploy's registration declares the tip,
	# so this run reaches the deployed commit only because the flag asked for
	# it, from the branch whose tip carries the other version.
	my ($dep_out, $dep_err, $dep_exit) = run_genesis($h,
		'qa', 'deploy', '--redeploy', '--no-propagate', '-y');
	is($dep_exit, 0, 'the flagged deploy succeeds from the deployment branch')
		or diag("what the deploy said:\n$dep_err");
	like("$dep_out$dep_err", qr/marker:\s*the-deployed-version/,
		'a command whose default is the tip still reaches the deployed commit');
};

# Proves that an environment whose file is not on the branch the
# operator is standing on is never read through a bare environment built on
# that tree.  A run that resolved its target from its registration's default
# yields, so the gate switches to the deployment branch and the command reads
# what was delivered there, and a run that named a flag is refused by name at
# Genesis::Exit::CONFIG.
#
# What the rows catch: a resolver that built the bare environment above the
# file test, which dies over a file that is missing exactly as intended and
# answers a question about flags with a complaint about a missing file; and
# one that wrapped the build in an eval instead, which swallows a vault the
# repository cannot reach and quietly takes the tip on a run that should have
# said so out loud.
subtest 'an environment file off the branch is not read through it' => sub {
	plan tests => 6;

	# Two environments, each with its own marker, because the whole question
	# is what happens when the operator stands on one of them and names the
	# other.
	my $qa_env = <<'YAML';
---
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      qa
params:
  marker: the-qa-version
YAML
	my $prod_env = <<'YAML';
---
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      prod
params:
  marker: the-prod-version
YAML

	my $h = make_harness(envs => ['qa', 'prod'], type => 'bosh');

	my $control = commit_on_control($h,
		files   => {'qa.yml' => $qa_env, 'prod.yml' => $prod_env},
		message => 'the certified content',
		push    => 1,
	);
	init_branch($h, $_) for qw/qa prod/;
	for my $env (qw/qa prod/) {
		my $delivered = deliver($h, $env, control => $control);
		certify($h, $env, commit => $delivered, control_commit => $control);
	}
	refresh($h, 'a');

	fixture_bosh($h,
		hooks => {
			info => qq{grep '^  marker:' "\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml"\n},
		},
	);

	# The operator is standing on one environment's deployment branch, which
	# carries that environment's file and no other.
	stand_on($h, 'qa/bosh');

	my ($out, $err, $exit) = run_genesis($h, 'info', 'prod');
	is($exit, 0, 'a default target yields where the file is not on this branch');
	like("$out$err", qr/marker:\s*the-prod-version/,
		'so the gate switches and the command reads what that branch carries');

	# Both runs name the environment after the command rather than before it.
	# The prefix form asks the CLI to recognise the name as an environment,
	# which it does by looking for the file in the tree it was started in, so
	# from this branch it would answer with a usage error about an
	# unrecognised command before any gate had run at all.
	my $before = snapshot_w($h);
	(undef, $err, $exit) = run_genesis($h, {restore => 0},
		'info', 'prod', '--as-deployed');
	is($exit, Genesis::Exit::CONFIG, 'a flagged run is refused instead');
	like($err, qr{prod/bosh}, 'and the refusal names the branch to stand on');
	assert_w_restored($before, 'the refusal left working state alone');
};

done_testing;
