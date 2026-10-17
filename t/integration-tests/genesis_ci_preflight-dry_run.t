#!/usr/bin/env perl
# Proves the preview's reads and its assumed moves (D115 and D44, both noted
# 2026-10-09), and T116's no-write half for them.  A dry run reads R once,
# brings T up to that read, and creates, resets and fast-forwards nothing.
# It warns for each move it assumes, in the conditional.  It also proves T374
# (D112, D30 and D44, noted 2026-10-16): the preview reads control's commits
# and switches nothing, reads control on T where the clone has no control,
# and asks of the tree only that its own root is committed.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# lab then qa, with a shared ops file both carry, so one control commit is due
# to both and each preview has something to say about each branch.
sub two_stage {
	my $h = ready_harness(
		envs    => ['lab', 'qa'],
		kit     => 'omega-v2.7.0',
		chained => 1,
		tracked => ['ops/shared.yml'],
	);
	commit_on_control($h, files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'Bump shared ops', push => 1);
	return $h;
}

sub heads_of {
	my ($h) = @_;
	my ($out) = run({dir => $h->a}, 'git', 'for-each-ref',
		'--format=%(refname) %(objectname)', 'refs/heads');
	return $out;
}

sub snapshots_left {
	my ($h) = @_;
	my ($out) = run({dir => $h->a}, 'git', 'for-each-ref', 'refs/genesis');
	return $out // '';
}

subtest 'a preview reads R once and brings T up to it' => sub {
	# Five rows, and the run's own restoration assertion.
	plan tests => 6;

	# A teammate's commit lands on qa/bosh on R, which the clone has not
	# seen.  The remote is severed from its second call onward, and the
	# snapshot is the run's first and only read of R, so a preview that read
	# R again before it reported would meet the severed remote.
	my $h  = two_stage();
	my $qa = $h->slug('qa');
	hand_commit($h, $qa, copy => 'b', push => 1, message => 'qa moves on R');
	stand_on($h, $h->control);
	my $heads = heads_of($h);

	sever_remote($h, after => 2);
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');
	restore_remote($h);

	is($exit, 0, 'the preview needs one read of R') or diag($err);
	is(ref_in($h->a, "refs/remotes/origin/$qa"), ref_in($h->r, "refs/heads/$qa"),
		"T holds what the preview read of R");
	is(heads_of($h), $heads, 'no local branch moved, and none was created');
	like(unfolded($err), qr/assumes\s+\Q$qa\E\s+is\s+fast-forwarded/,
		'the branch now behind T is assumed fast-forwarded');
	is(snapshots_left($h), '', 'and no snapshot is left behind');
};

subtest 'a branch the clone lacks is previewed from T, not created' => sub {
	# Four rows, and the run's own restoration assertion.
	plan tests => 5;

	my $h   = two_stage();
	my $lab = $h->slug('lab');
	stand_on($h, $h->control);
	delete_local($h, 'a', $lab);

	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');
	my $said = unfolded($err);

	is($exit, 0, 'the preview runs') or diag($err);
	like($said, qr/assumes\s+\Q$lab\E\s+is\s+created/,
		'and assumes the branch is created from T');
	like($err, qr/^\s*lab: would propagate/m, 'previewing its delivery');
	ok(!defined ref_in($h->a, "refs/heads/$lab"), 'without creating it');
};

subtest "the preview's lines say what would happen, not what did" => sub {
	# Five rows, and the run's own restoration assertion.
	plan tests => 6;

	# qa carries a marker-only local commit, which a real run resets, and
	# lab is behind R, which a real run fast-forwards.
	my $h   = two_stage();
	my $lab = $h->slug('lab');
	my $qa  = $h->slug('qa');
	local_only_commit($h, $qa, marker => ref_in($h->a, 'refs/heads/' . $h->control));
	hand_commit($h, $lab, copy => 'b', push => 1, message => 'lab moves on R');
	stand_on($h, $h->control);

	my (undef, $err) = run_genesis($h, 'propagate', '--dry-run');
	my $said = unfolded($err);

	like($said, qr/would reset \Q$qa\E to origin\/\Q$qa\E/, 'the reset reads as one that would be made');
	like($said, qr/would fast-forward \Q$lab\E to origin\/\Q$lab\E/,
		'and so does the fast-forward');
	unlike($err, qr/^\s*reset \Q$qa\E/m, 'neither is said to have been made');
	unlike($err, qr/^\s*fast-forwarded \Q$lab\E/m, 'in either tense');
	like($said, qr/assumes\s+\Q$qa\E\s+is\s+reset/, 'and each still earns its caveat');
};

subtest 'a preview with control ahead reads the shape it stands on' => sub {
	# Three rows, and the run's own restoration assertion.
	plan tests => 4;

	# Under R's shape qa follows lab, which has not deployed the shared
	# bump, so qa is held behind it.  An unpushed commit on control makes qa
	# a root.  The preview assumes that commit pushed, so it reads the shape
	# from the control it stands on, and qa is no longer held (D30, noted
	# 2026-10-10).
	my $h = two_stage();
	stand_on($h, $h->control);
	commit_on_control($h,
		files => {'qa.yml' => join("\n", '---', 'kit:', '  name:    dev',
			'  version: latest', '  features: []', 'genesis:', '  env: qa',
			'  pipeline:', '    track_additional_files:',
			'      - ops/shared.yml', '')},
		message => 'qa follows nobody', push => 0);

	my (undef, $err) = run_genesis($h, 'propagate', '--dry-run');
	my $said = unfolded($err);

	like($said, qr/assumes the commit on \Q@{[$h->control]}\E is pushed/,
		'the preview warns that it assumes the push');
	like($err, qr/^\s*qa: would propagate/m,
		'and routes qa as the pushed shape would, a root');
	unlike($err, qr/^\s*qa: held/m, 'not held behind lab, as R\'s shape has it');
};

# T374: the preview reads control's commits and switches nothing (D112, D30
# and D44, all noted 2026-10-16).  HEAD's reflog is the witness: a switch to
# control and back writes two entries into it even where it ends where it
# began.
sub reflog_of {
	my ($h) = @_;
	my ($out) = run({dir => $h->a}, 'git', 'reflog', '--format=%H %gs', 'HEAD');
	return $out;
}

subtest '(a) a preview on a feature branch switches nothing' => sub {
	# Three rows, and the run's own restoration assertion.
	plan tests => 4;

	my $h = two_stage();
	run({dir => $h->a}, 'git', 'checkout', '-q', '-b', 'feature/watch', $h->control);
	my $reflog = reflog_of($h);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');
	is($exit, 0, 'the preview succeeds') or diag($err);
	like(unfolded($out, $err), qr/qa/, 'and reports the environments');
	is(reflog_of($h), $reflog, 'and HEAD never moved');
};

subtest '(b) a clone with no local control previews control on T' => sub {
	# Three rows, and the run's own restoration assertion.
	plan tests => 4;

	# The operator stands on a feature branch cut from control, and control
	# itself is gone from the clone.  A real run creates it from T before it
	# switches; a preview reads T, since it stands on nothing.
	my $h       = two_stage();
	my $control = $h->control;
	run({dir => $h->a}, 'git', 'checkout', '-q', '-b', 'feature/watch', $control);
	delete_local($h, 'a', $control);
	my $heads = heads_of($h);

	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');
	is($exit, 0, 'the preview succeeds') or diag($err);
	like(unfolded($err), qr{no local \Q$control\E, so this preview reads origin/\Q$control\E},
		'saying it read control on T');
	is(heads_of($h), $heads, 'and no local branch was created');
};

subtest '(c) an uncommitted change in the root is refused for the preview' => sub {
	# Two rows, and the run's own restoration assertion.
	plan tests => 3;

	my $h = two_stage();
	mkfile_or_fail($h->a . '/ops/shared.yml', "---\nshared: 2\n");

	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');
	is($exit, Genesis::Exit::DATAERR, 'the preview refuses as data');
	like(unfolded($err), qr/needs the change committed and not pushed/,
		'saying a preview of propagation needs a commit, not a push');
};

subtest "(d) another root's uncommitted change is not the preview's" => sub {
	# One row, and the run's own restoration assertion.
	plan tests => 2;

	my $h = ready_harness(envs => ['lab', 'qa'], kit => 'omega-v2.7.0',
		chained => 1, tracked => ['ops/shared.yml'], root => 'bosh');
	commit_on_control($h, files => {
		'bosh/ops/shared.yml' => "---\nshared: 1\n",
		'vault/notes.yml'     => "--- {}\n",
	}, message => 'Bump shared ops, beside a second root', push => 1);
	mkfile_or_fail($h->a . '/vault/notes.yml', "--- {changed: true}\n");

	my (undef, $err, $exit) = run_genesis($h, {dir => 'bosh'}, 'propagate', '--dry-run');
	is($exit, 0, 'the preview in bosh/ succeeds') or diag($err);
};

done_testing;
