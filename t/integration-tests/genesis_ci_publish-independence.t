#!/usr/bin/env perl
# Proves T191: a run that lands one branch and has another refused leaves each
# branch wholly at one control commit with a true marker, no line of the run
# reports the two branches together, and the next run redelivers to the
# refused environment alone and converges.
#
# This is I12 exercised, and it is the row that makes the atomic publish
# unnecessary rather than merely withdrawn.  Under D99 a future proposal to
# publish every branch at once has to name a reader that needs two deployment
# branches to agree, and this row is where we show there is none: every branch
# is an independent mirror at its own marker, routing between environments
# reads the deployment records rather than another branch, and the state a
# partial run leaves is one that I11 has the next run converge from.
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

subtest 'one branch landing and another not is a valid state that converges' => sub {
	# Ten rather than eight, because each of the two runs asserts the
	# restoration of the working state in its own words and both of those
	# assertions are counted here.
	plan tests => 10;

	my $h = make_harness(envs => ['lab', 'prod'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	ready_envs($h);

	# Copy B advances prod/bosh on R between copy A's refresh and its first
	# push, so the remote refuses prod and takes lab in the same run.
	move_on_r_at($h, 'prod/bosh', at => 'push', nth => 1);

	my $before = harness_marker($h, 'prod/bosh');
	my $control = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: sixteen\n"},
		message => 'share an op with both environments',
		push    => 1,
	);

	my ($out, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit, Genesis::Exit::TEMPFAIL, 'the run reports itself partial');

	# Wholly at one control commit, read through the marker rather than
	# through the tip, because the marker is what names the commit the branch
	# claims to mirror and a tip alone says nothing about whether that claim
	# is true.  An all-or-nothing publish leaves lab's remote-tracking ref at
	# the marker it started from, which is what these two read apart.
	is(harness_marker($h, 'origin/lab/bosh'), $control,
		'lab is wholly at the new control commit');
	is(harness_marker($h, 'origin/prod/bosh'), $before,
		'prod is wholly at the one it was already at');

	# And the marker lab now carries is true of the branch under it, which is
	# the half of I12 that says a landed branch is a whole mirror and not a
	# tip that merely moved.
	assert_snapshot_invariant($h, 'lab',
		name => 'lab mirrors the set at its own marker');

	# No reader consults two deployment branches together, read off what the
	# run printed, because ruling 35 adds no per-ref step to the fault log and
	# ruling 13 leaves the ref specs stringified in it.  A publish that pushed
	# the set as one batch and reported the batch would name both branches on
	# the line it reported, and that is the implementation this catches.
	my @both = grep {m{\blab/bosh\b} && m{\bprod/bosh\b}} split /\n/, ($err // '');
	is(scalar(@both), 0, 'no line of the run reports the two branches together');

	# The second run redelivers to prod alone.  lab has deployed the commit it
	# received, so nothing about prod's refusal is waiting on it.
	certify($h, 'lab', control_commit => $control);
	my ($out2, $err2, $exit2) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit2, 0, 'the second run is clean');
	is(harness_marker($h, 'origin/prod/bosh'), $control, 'prod converged');

	# Matched against the environment's own line in the report, rather than
	# against the word anywhere in the run, because a run that redelivered to
	# lab would print the word beside prod's line as well and an unanchored
	# match cannot tell the two apart.
	unlike($err2, qr/^\s*lab: propagated/m,
		'and lab wrote nothing, because it was already there');
};

done_testing;
