#!/usr/bin/env perl
# Proves T339: a code says whether an unaided retry fixes the condition.  A
# hand commit on a deployment branch is the operator's own state, so the run
# exits DATAERR and refuses again on every run until they clear it.  A second
# clone pushing to control between this run's refresh and its publish is
# nobody's mistake, so the run exits TEMPFAIL and the job's next run publishes
# with nobody having repaired anything first.
#
# The retry is the assertion that matters.  Both refusals name a branch, say
# what moved, and say that nothing was pushed, so an implementation that chose
# each code by reading that prose passes every row about the message and parts
# from this one only when the command is run a second time.
#
# Every phrase is matched across the wrap, because a refusal is folded to the
# terminal width before it reaches standard error.
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

subtest 'a hand commit refuses, and refuses again on an unaided retry' => sub {
	# Five rows, and one more for each run's own restoration assertion.
	plan tests => 7;

	my $h  = make_harness(envs => ['qa']);
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	# An ops file rather than a rewritten environment file, because the
	# pipeline metadata lives in the environment file and overwriting it
	# empties the topology, which bails the run several steps before the
	# refusal this row is about.
	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nfrom: the operator\n"},
		message => 'an operator commit to propagate',
		push    => 1);
	my $hand = local_only_commit($h, $qa,
		marker => 0, message => 'patch the manifest by hand');
	# The commit helper leaves the copy on the branch it wrote, and the init
	# tree carries no deployment root, so the copy stands back on control
	# before the command runs.
	stand_on($h, $h->control);

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR,
		'the run refuses on state only the operator can clear');
	like(unfolded($err), qr/patch the manifest by hand/,
		'and the refusal names the commit');

	# Nobody clears anything between the two runs, which is what unaided
	# means here, so the second run meets exactly what the first one met.
	# This retry runs in copy A on purpose, because the state it refuses on
	# is that clone's own hand commit, where the retry below runs in a fresh
	# clone because the state that one meets is on R.
	my (undef, $err_again, $again) = run_genesis($h, 'propagate');

	is($again, Genesis::Exit::DATAERR, 'the unaided retry refuses again');
	like(unfolded($err_again), qr/patch the manifest by hand/,
		'and it names the same commit');
	is(ref_in($h->a, "refs/heads/$qa"), $hand,
		'the hand commit is still there, because no run touched it');
};

subtest 'a control a teammate moved refuses once, and the retry publishes' => sub {
	# Six rows, and one more for each run's own restoration assertion.
	plan tests => 8;

	my $h = make_harness(envs => ['lab'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	ready_envs($h);

	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: twenty\n"},
		message => 'share an op with every environment',
		push    => 1,
	);

	# A teammate publishes to control while the run is walking.  The entry
	# is armed for the first commit of the run, and the count that fires it
	# lives in the plan file, so it fires once and the second run walks
	# unarmed, which is what makes that run the unaided retry.
	my $theirs = move_on_r_at($h, $h->control, at => 'commit', nth => 1,
		files   => {'ops/theirs.yml' => "---\nby: the teammate\n"},
		message => 'a teammate pushed to control',
	);

	my $before = ref_in($h->r, 'refs/heads/lab/bosh');

	my ($out, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($out, $err);

	is($exit, Genesis::Exit::TEMPFAIL,
		'the run refuses on state nobody has to clear');
	like($said, qr/is behind .* so everything this run computed is stale/,
		'and the refusal names behind as stale');
	is(ref_in($h->r, 'refs/heads/lab/bosh'), $before,
		'nothing reached the remote');
	is(ref_in($h->r, 'refs/heads/'.$h->control), $theirs,
		'and control is where the teammate left it');

	# The retry is a clone cut from R now, because that is what the pipeline
	# job reading this exit code makes on every run.  Genesis never moves
	# control, so this copy's own control stays a commit behind the
	# teammate's and the pre-flight refuses it at DATAERR until the
	# operator rebases it.  A clone made after the teammate pushed starts on
	# what R holds, so it needs nobody to repair anything first.
	my $copy = clone_copy($h);
	my (undef, undef, $again) =
		run_genesis_in($h, $copy, {answers => ['y']}, 'propagate');

	is($again, 0, 'the unaided retry publishes');
	isnt(ref_in($h->r, 'refs/heads/lab/bosh'), $before,
		'because the branch went out on the second run');
};

done_testing;
