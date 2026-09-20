#!/usr/bin/env perl
# Proves T252, T256, and T253: what withholds the propagate child, and what
# catches up afterwards.
#
# The flag withholds the child and nothing else.  The gate the hand-off is
# spawned behind already refuses on it, so nothing here makes a row go red
# against the tree as it stands.  What these rows catch is a later change
# that drops the clause, whether by removing it or by reordering the gate so
# that something answers before it.  Such a change would leave the first
# subtest looking at a child it should never have seen, with R moved beneath
# it, and it would leave the hand run in the second subtest with nothing left
# to carry.
#
# The two halves sit in one file because neither can be asserted without the
# other.  The flag is only half an answer, and the other half is the hand run,
# which has to reach the same branches and the same markers the child would
# have produced.  A run that spawned the child anyway would leave that hand
# run nothing to deliver, and a hand run that delivered nothing would say
# nothing about whether the flag had withheld anything.
#
# The third subtest is the other thing that withholds the child, which is a
# defect rather than a flag anybody typed.  A kit hook writes into the
# repository, the session finds the tracked modification when it ends, and
# the tree it hands back is not one to fan out from.  It belongs beside the
# other two because it is the same question asked of a run that failed, and
# because the hand run it ends with is the same catch-up the second subtest
# reads.
#
# The fixture is the chained shape rather than a bare make_harness.  A
# harness that stands up no director, no bosh, and no kit deploys nothing, and
# a deploy that never succeeds hands off to no child at all, so every row here
# would read a silence it had built itself.  ready_harness with bosh names qa
# as prod's predecessor through chained, delivers and certifies both of them,
# and commits the kit on control before the seeding.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

use Genesis;

plan tests => 3;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest '--no-propagate deploys and spawns nothing' => sub {
	plan tests => 5;

	my $h = ready_harness(envs => ['qa', 'prod'], chained => 1, bosh => 1);
	due_on_control($h);
	my $before = $h->git('a')->sha('refs/remotes/origin/'.$h->slug('prod'));

	child_recorder($h);
	stand_on($h, $h->control);
	my $w = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '-y', '--no-propagate');

	is($exit, 0, 'the deploy command succeeded')
		or diag("what the deploy said:\n$err");
	is_deeply([child_runs($h)], [], 'no child was spawned');
	like($out.$err, qr/deployed successfully/,
		'the deploy reported itself done');

	refresh($h, 'a', $h->slug('prod'));
	is($h->git('a')->sha('refs/remotes/origin/'.$h->slug('prod')), $before,
		'nothing on R moved');
	assert_w_restored($w,
		'the operator is back on the branch they started from');
};

subtest 'the hand run delivers what the child would have' => sub {
	plan tests => 9;

	my $h = ready_harness(envs => ['qa', 'prod'], chained => 1, bosh => 1);
	my $control = due_on_control($h);

	child_recorder($h);
	stand_on($h, $h->control);
	# This run spawns nothing, so the runner takes its own snapshot and
	# makes the one restoration assertion for it.
	my (undef, $said, $exit) = run_genesis($h, 'qa', 'deploy', '-y',
		'--no-propagate');
	is($exit, 0, 'the deploy command succeeded')
		or diag("what the deploy said:\n$said");

	my ($out, $err, $run) = run_genesis($h, {restore => 0}, 'propagate', '-y');
	is($run, 0, 'the hand run succeeded')
		or diag("what the hand run said:\n$err");
	like($out.$err, qr/\bprod\b.*\bpropagated\b/,
		'the hand run delivered to prod');

	refresh($h, 'a', $h->slug('prod'));
	is(harness_marker($h, 'origin/'.$h->slug('prod')), $control,
		'prod carries the marker naming the certified commit');
	assert_snapshot_invariant($h, 'prod',
		name => 'prod mirrors control over its propagation set');

	my ($again, $again_err, $second) = run_genesis($h, {restore => 0},
		'propagate', '-y');
	is($second, 0, 'the second hand run succeeded')
		or diag("what the second hand run said:\n$again_err");
	like($again.$again_err, qr/\bprod\b.*\bidempotent\b/,
		'the second run found nothing left to do');
	unlike($again.$again_err, qr/\bpropagated\b/,
		'the second run delivered nothing, so the run is level triggered');
};

subtest 'a tracked modification at finish withholds the child' => sub {
	plan tests => 7;

	# A kit hook that writes into the repository is the defect, and it leaves
	# the tracked modification finish will find.  The hook is handed to the
	# bosh fixture rather than laid by a call of its own, because that fixture
	# writes the kit itself and commits it on control, and a second kit written
	# afterwards would take the blueprint hook with it and stand its commit on
	# whatever branch the row had reached.
	my $h = ready_harness(envs => ['qa', 'prod'], chained => 1, bosh => {
		hooks => {
			'post-deploy' => 'echo "# tampered" >> "$GENESIS_ROOT/qa.yml"',
		},
	});
	my $control = due_on_control($h);

	child_recorder($h);
	stand_on($h, $h->control);
	my $w = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '-y');

	isnt($exit, 0, 'the command exited non-zero, because a kit wrote to the repo');
	my $report = $out.$err;
	# The sentence read for this is the abort's own rather than the tail of
	# the command, because the abort ends the command where it stands and
	# the line that says "deployed successfully" is below it and never
	# printed.  What the operator is told is that the environment is running
	# and needs no redeploying, which is the same fact said where they will
	# actually read it.
	like($report, qr/deployed and its deployment record is written/,
		'the deploy is still reported as having succeeded');
	like($report, qr/qa\.yml/, 'the abort named the file that was modified');
	is_deeply([child_runs($h)], [], 'no child was spawned');
	assert_w_restored($w, 'the starting branch was restored anyway');

	my (undef, $hand_err, $run) = run_genesis($h, {restore => 0},
		'propagate', '-y');
	is($run, 0, 'the hand run afterwards succeeded')
		or diag("what the hand run said:\n$hand_err");
	refresh($h, 'a', $h->slug('prod'));
	is(harness_marker($h, 'origin/'.$h->slug('prod')), $control,
		'the hand run delivered what the child would have');
};

# vim: ts=2 sw=2 sts=2 noet
