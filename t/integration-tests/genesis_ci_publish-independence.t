#!/usr/bin/env perl
# Proves T191 as far as a run can be watched from outside it: a run that lands
# one branch and has another refused leaves each branch wholly at one control
# commit with a true marker, no printed line of the run names both branches,
# and the next run redelivers to the refused environment alone and converges.
#
# What the row reaches is what the harness can see.  Each environment's marker
# moved or held on its own, and no line the run printed named the two branches
# together.  That no reader consults the two tips together is the walk's own
# design, which gives every environment's reader its own marker, and it is
# settled by reading that code at the final review rather than by a regex over
# what a run said.  Ruling 49 is where that reach is fixed.
#
# I12 is why the row exists.  Under D99 a future proposal to publish every
# branch at once has to name a reader that needs two deployment branches to
# agree, and the state this row watches is the one such a proposal would call
# invalid: one branch landed, one refused, each marker true of the branch
# under it, and I11's next run converging from there.
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

# Wider than the sibling rows, which fold at 80, because this row counts the
# lines that name two branches and a fold puts the second name on a line of
# its own.  A batched publish reporting both branches at once would then be
# read as two innocent lines, and the one assertion that catches it would pass
# for the reason it exists to rule out.  Every line the run prints is well
# inside this, so nothing here is folded at all.
$ENV{GENESIS_OUTPUT_COLUMNS} = 200;
$ENV{NOCOLOR} = 1;

subtest 'one branch landing and another not is a valid state that converges' => sub {
	# Eleven rather than nine, because each of the two runs asserts the
	# restoration of the working state in its own words and both of those
	# assertions are counted here.
	plan tests => 11;

	my $h = make_harness(envs => ['lab', 'prod'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	ready_envs($h);

	# Copy B advances prod/bosh on R between copy A's refresh and its first
	# push, so the remote refuses prod and takes lab in the same run.
	move_on_r_at($h, 'prod/bosh', at => 'push', nth => 1);

	# R is read directly, here and below, rather than through copy A's
	# remote-tracking refs, because those are copy A's record of what it
	# believes R holds and a publish that moved R while leaving them stale
	# would read as correct through them.  The marker is the reader rather
	# than the tip, because the tip says only that a branch moved and the
	# marker says which control commit the branch claims to mirror.
	my $before = harness_marker($h, 'prod/bosh', copy => 'r');
	ok(defined $before, 'prod starts at a control commit R can name');

	my $control = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: sixteen\n"},
		message => 'share an op with both environments',
		push    => 1,
	);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit, Genesis::Exit::TEMPFAIL, 'the run reports itself partial');

	# An all-or-nothing publish leaves lab on R at the marker it started
	# from, which is what these two read apart.
	is(harness_marker($h, 'lab/bosh', copy => 'r'), $control,
		'lab is wholly at the new control commit');
	is(harness_marker($h, 'prod/bosh', copy => 'r'), $before,
		'the run left prod on R where it found it');

	# And the marker lab now carries is true of the branch under it, which is
	# the half of I12 that says a landed branch is a whole mirror and not a
	# tip that merely moved.  It is asserted of lab alone, because the
	# teammate wrote armed.yml onto prod by hand and prod is deliberately not
	# a pure mirror until the next run takes that file back off it.
	assert_snapshot_invariant($h, 'lab',
		name => 'lab mirrors the set at its own marker');

	# Read off what the run printed, because ruling 35 adds no per-ref step to
	# the fault log and ruling 13 leaves the ref specs stringified in it.  A
	# publish that pushed the set as one batch and reported the batch would
	# name both branches on the line it reported, and that is the
	# implementation this catches.
	my @both = grep {m{\blab/bosh\b} && m{\bprod/bosh\b}} split /\n/, ($err // '');
	is(scalar(@both), 0, 'no line of the run reports the two branches together');

	# The second run redelivers to prod alone.  lab has deployed the commit it
	# received, so nothing about prod's refusal is waiting on it.
	certify($h, 'lab', control_commit => $control);
	my (undef, $err2, $exit2) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit2, 0, 'the second run is clean');
	is(harness_marker($h, 'prod/bosh', copy => 'r'), $control, 'prod converged');

	# Matched against the environment's own line in the report, rather than
	# against the word anywhere in the run, because a run that redelivered to
	# lab would print the word beside prod's line as well and an unanchored
	# match cannot tell the two apart.
	unlike($err2 // '', qr/^\s*lab: propagated/m,
		'and lab wrote nothing, because it was already there');
};

done_testing;
