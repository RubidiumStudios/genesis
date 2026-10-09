#!/usr/bin/env perl
# Proves T348 and T349: genesis propagate asks every question first and then
# either refuses once with every problem it found, at the highest-ranked code,
# or acts (D115, D106).  A refused run leaves the operator's clone exactly as
# it found it, every ref included, with no snapshot left behind, and a run
# that proceeds promotes what it read of R into the tracking refs and repairs
# the branches as the initial state classified them.
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
use Genesis::CI::Marker;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub two_stage {
	return ready_harness(
		envs    => ['lab', 'qa'],
		kit     => 'omega-v2.7.0',
		chained => 1,
	);
}

# Every local branch and tracking ref the clone has, and every ref under the
# snapshot namespace, so a row can say a refusal moved none of them and left
# no snapshot behind.
sub refs_of {
	my ($h) = @_;
	my ($out) = run({dir => $h->a}, 'git', 'for-each-ref',
		'--format=%(refname) %(objectname)', 'refs/heads', 'refs/remotes');
	return $out;
}
sub snapshots_left {
	my ($h) = @_;
	my ($out) = run({dir => $h->a}, 'git', 'for-each-ref', 'refs/genesis');
	return $out // '';
}

subtest 'several problems are named in one refusal' => sub {
	# Twelve rows, and the restoration assertion of each of the three runs.
	plan tests => 15;

	my $h = two_stage();
	hand_commit($h, $h->slug('qa'), copy => 'a', push => 0);
	stand_on($h, $h->control);
	break_vault($h, envs => [], applied => 1);

	my (undef, $err, $exit) = run_genesis($h, 'propagate');
	my $said = unfolded($err);
	is($exit, Genesis::Exit::CONFIG,
		'the run exits CONFIG, the configuration problem outranking the state');
	like($said, qr/never been run against this repository/, 'naming the pipeline never applied');
	like($said, qr/\Q@{[$h->slug('qa')]}\E.*Fix it by hand/s, 'and the hand commit');
	is(() = $said =~ /Refusing to /g, 1, 'in one refusal');

	my (undef, $dry_err, $dry_exit) = run_genesis($h, 'propagate', '--dry-run');
	my $dry = unfolded($dry_err);
	is($dry_exit, Genesis::Exit::CONFIG, 'a dry run refuses the same way');
	like($dry, qr/never been run against this repository/, 'naming the pipeline never applied');
	like($dry, qr/Fix it by hand/, 'and the hand commit');

	# Control diverged from R leaves every question that reads control without
	# a control anyone can trust, so they are named as not checked, and the
	# hand commit, which is one of them, is not reported.
	commit_on_control($h, files => {'ops/mine.yml' => "---\nmine: 1\n"},
		message => 'mine, not pushed');
	commit_from_b($h, branch => $h->control,
		files => {'ops/theirs.yml' => "---\ntheirs: 1\n"}, message => 'theirs, pushed');
	push_from($h, 'b', $h->control);
	my (undef, $gate_err, $gate_exit) = run_genesis($h, 'propagate');
	my $gate = unfolded($gate_err);
	is($gate_exit, Genesis::Exit::CONFIG, 'with control diverged as well, still CONFIG');
	like($gate, qr/both unpublished and stale/, 'naming the divergence');
	like($gate, qr/Not checked, because/, 'and what it left unasked');
	unlike($gate, qr/Fix it by hand/, 'without the hand commit, which reads control');
	like($gate, qr/never been run against this repository/,
		'while the applied record, which does not, is still named');
};

subtest 'a refused run leaves the clone as it found it, and the next one acts' => sub {
	# Nine rows, and the restoration assertion of each of the two runs.
	plan tests => 11;

	my $h = two_stage();
	my $control = $h->control;
	my $applied = record_at($h, $h->applied_path);

	# R moves on under the clone: a teammate's commit on control, and one on
	# qa/bosh, which leaves the clone's qa/bosh behind.  The clone holds a
	# marker-only commit on lab/bosh and has never had control at all, its
	# operator standing on a feature branch cut from control, which carries the
	# repository's configuration as a deployment branch does not.
	commit_from_b($h, branch => $control,
		files => {'ops/team.yml' => "---\nteam: 1\n"}, message => 'a teammate');
	push_from($h, 'b', $control);
	hand_commit($h, $h->slug('qa'), copy => 'b', push => 1, message => 'qa moves on R');
	my $marker_only = local_only_commit($h, $h->slug('lab'),
		marker => ref_in($h->a, "refs/heads/$control"));
	run({dir => $h->a}, 'git', 'checkout', '-q', '-b', 'feature/watch', $control);
	delete_local($h, 'a', $control);
	break_vault($h, envs => [], applied => 1);

	my $before = refs_of($h);
	my (undef, $err, $exit) = run_genesis($h, 'propagate');
	isnt($exit, 0, 'the run refuses, the pipeline never applied');
	is(refs_of($h), $before,
		'no local branch or tracking ref moved: nothing fetched, created, reset or fast-forwarded');
	is(snapshots_left($h), '', 'and no snapshot is left behind');

	fixture_applied($h, control => $applied->{control_commit});
	my (undef, $go_err, $go_exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($go_exit, 0, 'restored, the run proceeds') or diag($go_err);
	is(ref_in($h->a, "refs/remotes/origin/$control"), ref_in($h->r, "refs/heads/$control"),
		"control's tracking ref holds what R had");
	ok(ref_in($h->a, "refs/heads/$control"), 'the control branch the clone never had is created');
	ok(!run({dir => $h->a, passfail => 1, stderr => 0}, 'git', 'merge-base',
			'--is-ancestor', $marker_only, 'refs/heads/' . $h->slug('lab')),
		"lab/bosh's marker-only commit was reset away, the walk reproducing it");
	ok(run({dir => $h->a, passfail => 1, stderr => 0}, 'git', 'merge-base',
			'--is-ancestor', ref_in($h->r, 'refs/heads/' . $h->slug('qa')),
			'refs/heads/' . $h->slug('qa')),
		'qa/bosh was brought up to what R holds');
	is(snapshots_left($h), '', 'and no snapshot is left behind');
};

done_testing;
