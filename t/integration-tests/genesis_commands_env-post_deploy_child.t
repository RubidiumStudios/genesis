#!/usr/bin/env perl
# The post-deploy propagate child, and whether it runs, where it runs,
# and what neither process writes.  Proves T248, T249, T254, T255, T257, and
# T258 of the test matrix.
#
# The fixture is the named shape rather than the step file's bare
# make_harness, for the reason Task 14.6 recorded against the same rows.  A
# harness that stands up no director, no bosh, and no kit deploys nothing,
# and a deploy that never succeeds hands off to no child at all, so every
# row here would read a silence it had built itself.  ready_harness with
# bosh names qa as prod's predecessor through chained, delivers and certifies
# both of them, and commits the kit on control before the seeding.
#
# Both are delivered, rather than prod being left at its init commit, because
# the kit is a kind of the propagation set and the seeding's first control
# commit predates it.  An undelivered prod leaves the walk starting from that
# commit, where prod's own file names a kit the tree does not yet carry, and
# the run refuses by name.  So the shape delivers everything at the tip and
# the commit under test is laid afterwards, which is the order a pipeline
# arrives at anyway.
#
# The commit the child carries downstream is due_on_control's, which touches
# both environment files and is delivered to qa alone before the deploy runs.
# That is the cascade in miniature, where the deploy certifies it for qa, and
# the hold on prod, whose predecessor was waiting to deploy the files that
# commit touches, is released by the certification the deploy has just
# written.
#
# The lock-probe hook is installed after that shape rather than through it,
# because the probe's path is the harness's own and cannot be named before
# the harness exists.  It is left uncommitted, which leaves it untracked,
# and D84 ignores untracked files, so the hook the deploy runs is not also
# a tracked modification that aborts the finish it is watching.
#
# The second subtest runs from a branch of the operator's own rather than
# from control, which is the step file's own placement.  The reason is that
# the hand-off we inherit checks control out after the session has already
# restored the operator, so an operator who started on control is standing
# where that checkout leaves them and cannot tell it apart from having been
# put back.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;
use Cwd ();

use Genesis;

plan tests => 5;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# qa and prod both deployed and delivered at control's tip, prod downstream of
# qa, and the director, the fake bosh, and the kit that let a deploy reach its
# end.
sub chained_harness {
	my (%opts) = @_;
	return ready_harness(
		envs    => ['qa', 'prod'],
		chained => 1,
		bosh    => 1,
		%opts,
	);
}

# One control commit that both environments are due, delivered to qa alone, so
# that the deploy under test certifies it and the child has exactly one commit
# to carry to prod.  The bodies come from the harness's own writer rather than
# being spelled out here, since an environment file the walk reads a topology
# out of is the harness's to shape.
sub due_on_control {
	my ($h) = @_;
	write_env_file($h, 'qa', params => {n => 2}, commit => 0);
	write_env_file($h, 'prod', genesis => {pipeline => {prior_env => 'qa'}},
		params => {n => 2}, commit => 0);
	run({dir => $h->a}, 'git', 'add', '--', 'qa.yml', 'prod.yml');
	run({dir => $h->a, onfailure => 'Failed to commit the due change'},
		'git', 'commit', '-q', '-m', 'A change both environments are due');
	push_from($h, 'a', $h->control);

	my $control = $h->git('a')->sha($h->control);
	deliver($h, 'qa', control => $control);
	refresh($h, 'a', $h->control, $h->slug('qa'), $h->slug('prod'));
	return $control;
}

subtest 'one child, genesis propagate, and its own session' => sub {
	plan tests => 7;

	my $h = chained_harness();
	my $control = due_on_control($h);

	child_recorder($h, probe => 1);
	stand_on($h, $h->control);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '-y');
	is($exit, 0, 'the deploy command succeeded')
		or diag("what the deploy said:\n$err");

	my @runs = child_runs($h);
	is(scalar(@runs), 1, 'the deploy spawned exactly one child');
	is_deeply($runs[0]{argv}, ['propagate'],
		'the child ran genesis propagate with no argument and no option');
	# Each sample is the holder or undef, and a sample taken while the lock
	# was free is undef, so the samples are read for truth rather than
	# dereferenced.  The pid inside a sample is the forked genesis and never
	# the recording wrapper's own, so no row compares the two.
	ok(scalar(grep {$_} @{$runs[0]{lock_seen}}),
		'the switch lock was held while the child ran, so it opened a session');
	is($runs[0]{exit}, 0, 'the child ran to completion')
		or diag("what the run said:\n$out\n$err");

	refresh($h, 'a', $h->slug('prod'));
	is(harness_marker($h, 'origin/'.$h->slug('prod')), $control,
		'the child delivered the certified commit to prod');
	assert_snapshot_invariant($h, 'prod',
		name => 'prod mirrors control over its propagation set');
};

subtest 'the child starts after the session, and the lock says so' => sub {
	plan tests => 8;

	my $h = chained_harness();
	fixture_kit($h, hooks => {
		'post-deploy' => sprintf("%s deploy-hook\n", $h->lock_probe_bin),
	});

	child_recorder($h, probe => 1);
	# The operator starts on a branch of their own rather than on control,
	# which is what the last row of this subtest needs.  The hand-off we
	# inherit checks control out one way after the session has already put
	# the operator back, and an operator who started on control is standing
	# where that checkout leaves them, so a row run from there would read a
	# restoration that never happened.
	run({dir => $h->a}, 'git', 'checkout', '-q', '-b', 'wip/a-change');
	stand_on($h, 'wip/a-change');
	my $w = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '-y');
	is($exit, 0, 'the deploy command succeeded')
		or diag("what the deploy said:\n$err");

	my ($child) = child_runs($h);
	# The recorder writes no branch, so where the child started is read from
	# the directory it started in, and whether the operator was put back is
	# read from the run's own restoration below.  abs_path is asked for
	# because the harness builds under a directory that may be reached
	# through a symbolic link and the child answers with the resolved one.
	is($child->{cwd}, Cwd::abs_path($h->a),
		'the child started in the working tree the deploy was run in');
	is($child->{lock_at_start}, undef,
		'the deploy had finished its session before the child started');

	my @samples = lock_probe_log($h);
	is(scalar(@samples), 1, 'the kit hook took one sample during the deploy');
	ok($samples[0]{held}, 'the deploy held the lock while its own session ran');
	ok(scalar(grep {$_} @{$child->{lock_seen}}),
		'the child held the lock while it ran');
	is(lock_probe($h), undef, 'the lock is free again once the child has exited');

	assert_w_restored($w,
		'the operator stood on their own branch again before the child started');
};

subtest 'the two gates keep the child away' => sub {
	plan tests => 6;

	for my $case (
		# The automated arm runs the way the pipeline's own job runs it,
		# with GENESIS_PIPELINE_TASK set, because M13's provider gate
		# refuses an automated provider from the command line and a refusal
		# proves nothing about the gate this step adds.  Under the task
		# variable the gate is skipped, the deploy succeeds, and the
		# question the row asks is whether a child was spawned.
		{name => 'an automated provider',
			opts => {provider => 'concourse'},
			run  => {pipeline_task => 'deploy-qa'}},
		{name => 'a disabled pipeline',
			opts => {pipeline => 0},
			run  => {}},
	) {
		my $h = chained_harness(%{$case->{opts}});

		child_recorder($h, probe => 1);
		stand_on($h, $h->control);
		my (undef, $err, $exit) = run_genesis($h, $case->{run},
			'qa', 'deploy', '-y');
		is($exit, 0, "the deploy succeeded under $case->{name}")
			or diag("what the deploy said:\n$err");
		is_deeply([child_runs($h)], [],
			"no child was spawned under $case->{name}");
	}
};

subtest 'neither process asks the request queue for anything' => sub {
	plan tests => 3;

	my $h = chained_harness();

	# The spy lays an empty log down and names it to the run, so a row that
	# reads no requests back has read a file the spy really wrote rather
	# than a file nobody made.
	my $spy = shuttle_spy($h);
	child_recorder($h, probe => 1);
	stand_on($h, $h->control);
	my (undef, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '-y');
	is($exit, 0, 'the deploy command succeeded')
		or diag("what the deploy said:\n$err");
	my ($child) = child_runs($h);
	is($child->{exit}, 0, 'the child ran to completion');
	is_deeply([shuttle_requests($spy)], [],
		'neither the deploy nor its child put a request to the queue');
};

# Two of the properties the sub already had, guarded here rather than dropped
# and put back later.  What is genuinely new about each belongs to a later
# step, which is the wording of the retry sentence and the hand run that
# catches the withheld propagation up.
#
# The third property, the child's closed standard input, is guarded in
# t/integration-tests/genesis_commands_env-child_non_interactive.t instead,
# together with the publish question that redirect is there to keep from
# being asked.  A row here would have said only that the child was handed no
# terminal, which is true of every command this suite spawns whether the
# redirect is there or not.
subtest 'the move carries the two properties across' => sub {
	plan tests => 4;

	my $flagged = chained_harness();
	child_recorder($flagged, probe => 1);
	stand_on($flagged, $flagged->control);
	my (undef, $said, $exit) = run_genesis($flagged, {restore => 0},
		'qa', 'deploy', '--no-propagate', '-y');
	is($exit, 0, 'a deploy under --no-propagate succeeded')
		or diag("what the deploy said:\n$said");
	is_deeply([child_runs($flagged)], [],
		'and the flag still withheld the child');

	# The child's status is forced rather than earned, so the row reads the
	# parent's answer to a failure and nothing about why one happened.
	my $failing = chained_harness();
	child_recorder($failing, exit => 3);
	stand_on($failing, $failing->control);
	my (undef, $warned, $still) = run_genesis($failing, {restore => 0},
		'qa', 'deploy', '-y');
	is($still, 0, 'a deploy whose child failed still succeeded')
		or diag("what the deploy said:\n$warned");
	like(unfolded($warned), qr/Propagation failed \(rc=3\)/,
		'and the operator was told the child failed, with its status');
};

# vim: ts=2 sw=2 sts=2 noet
