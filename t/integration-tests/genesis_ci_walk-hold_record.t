#!/usr/bin/env perl
# Proves T151 and T153: a hold record stops delivery in both modes while the
# branch stays deployable, --dry-run still lists what waits, and the hold
# outranks idempotent with the three detail wordings.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The four calls name the environment the hold stands against and the words
# the operator wrote on it, because the helper's own defaults hold prod for
# the reason on-hold and every row here argues about qa waiting on a person.
# The kit goes with them, since a run that delivers loads each environment
# and an environment with no kit on disk cannot be loaded.
sub held {
	return held_harness(envs => ['lab', 'qa'], env => 'qa',
		reason => 'waiting on the DBA', kit => 'omega-v2.7.0', @_);
}

subtest 'a hold stops delivery in direct mode' => sub {
	# One more than the rows, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	# Every subtest in this file is counted the same way.
	plan tests => 4;

	my $h = held();
	my $tip_before = harness_marker($h, $h->slug('qa'));
	two_due($h, env => 'qa');

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	is(harness_marker($h, $h->slug('qa')), $tip_before,
		'nothing was written to the branch');
	like($err, qr/held, needs clearing \(waiting on the DBA\)/,
		'the qualifier carries the reason');
	assert_snapshot_invariant($h, 'qa',
		name => 'the existing tip stays deployable');
};

subtest 'a hold stops a pull request being opened or updated' => sub {
	plan tests => 3;

	# The walk reads the hold in pull request mode and stops there, so the
	# rows below discriminate.  A run over the same fixture with the hold
	# lifted opens a pull request and pushes its branch, and each of these
	# three would fail on it.
	my $h = held(mode => 'pr', github => 1);
	my $gh = github_double($h);
	two_due($h, env => 'qa');

	run_genesis($h, {answers => ['y']}, 'propagate');

	my @writes = grep {$_->{method} ne 'GET'} gh_calls($gh);
	is(scalar(@writes), 0, 'no pull request was opened or updated');
	# --verify --quiet, because a bare rev-parse echoes the name it could not
	# resolve back on stdout and a row reading that would call an absent
	# branch present.
	my ($exists) = run({dir => $h->a, passfail => 0, stderr => 0},
		'git', 'rev-parse', '--verify', '--quiet',
		'refs/remotes/origin/'.$h->pr_branch('qa'));
	ok(!$exists, 'no PR branch was pushed');
};

subtest 'the preview still shows what waits behind the hold' => sub {
	plan tests => 3;

	# The walk goes on computing what is due while the hold stands, so the
	# preview lists the same commits whether they are pending or held, and
	# the two rows below name the commits rather than the list they are in
	# for exactly that reason.

	my $h = held();
	my @due = two_due($h, env => 'qa');

	my (undef, $err) = run_genesis($h, 'propagate', '--dry-run');
	like($err, qr/\Q@{[substr($due[0], 0, 7)]}\E/, 'the first waiting commit is listed');
	like($err, qr/\Q@{[substr($due[1], 0, 7)]}\E/, 'the second is listed too');
};

subtest 'the hold outranks idempotent, with two detail wordings' => sub {
	plan tests => 6;

	my $nothing_due = held();
	my (undef, $quiet) = run_genesis($nothing_due, {answers => ['y']},
		'propagate');
	# Nothing on the walk's path prints that word today, so this row guards
	# against a later stage teaching it one.  A held environment must never
	# read as though it were fine.
	unlike($quiet, qr/qa.*idempotent/, 'a held environment never reads idempotent');
	like($quiet,
		qr/nothing is due now, and anything that becomes due stays blocked/,
		'the nothing-due wording');

	my $busy = held();
	two_due($busy, env => 'qa');
	my (undef, $loud) = run_genesis($busy, {answers => ['y']}, 'propagate');
	like($loud, qr/2 commits are blocked until this hold is released/,
		'the count is named');
	# The command is named inside the detail line rather than on a line of
	# its own, and that sentence is longer than the eighty columns these rows
	# run at, so the report wraps it and a literal match would miss on
	# wherever the break fell.  Every run of spaces in the expected words is
	# matched as any whitespace instead, which is the idiom the third subtest
	# below reads its own wrapped line with.
	(my $command = quotemeta 'genesis qa pipeline-release') =~ s/(?:\\ )+/\\s+/g;
	like($loud, qr/$command/, 'the command is named');
};

subtest 'a hold over commits another reason holds says so' => sub {
	# Three: one row, and one restoration assertion for each of the two runs.
	plan tests => 3;

	# The first run delivers up to the gate and leaves qa's marker standing
	# on it, so the second run has one commit due and the gate falls on it.
	# Nothing is pending behind the hold, and the held list is not empty, and
	# the nothing-due wording would tell the operator that nothing is due
	# directly above the commit line saying one thing is.
	my ($h) = gated_harness(stage => 'schema change', kit => 'omega-v2.7.0');
	run_genesis($h, {answers => ['y']}, 'propagate');
	fixture_hold($h, 'qa', reason => 'waiting on the DBA');

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	# The line is longer than the eighty columns these rows run at, so the
	# report wraps it and a literal match would miss on wherever the break
	# fell.  Every run of spaces in the expected words is matched as any
	# whitespace instead, which reads the line whole however it is wrapped.
	my $words = '1 commit is blocked for a reason of its own, and stays '
	          . 'blocked while this hold stands';
	(my $wrapped = quotemeta $words) =~ s/(?:\\ )+/\\s+/g;
	like($err, qr/$wrapped/,
		'the commit another reason holds is named as such');
};

done_testing;
