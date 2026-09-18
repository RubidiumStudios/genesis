#!/usr/bin/env perl
# Proves T264 and T265, which are two of the four arms a reviewer's decision
# takes.  T264 has an approved pull request freeze, so the run neither rebuilds
# nor pushes the branch, holds the new due commit with the reason
# awaiting-merge, and records the environment held with the number beside it.
# T265 has a pull request whose reviewer asked for changes rebuilt with the fix
# that answers them, pushed, and its new body naming that review.
#
# The row needs a pull request branch that R already carries and a reviewer who
# has approved what is on it, so the first run is what builds and publishes
# that branch.  The pull request that run opens is unreviewed, and the double
# has no way to add a review to a pull request it already holds, so the row
# closes that one and declares the approved one in its place.  Leaving both
# open would put the several-pull-requests warning in the middle of a row about
# a freeze, and which of two open ones a run acts on is another row's subject.
#
# The due commits are laid through the environment file at the deployment root
# rather than under prod/, because a path under prod/ is in no propagation set
# and a commit written there would route nowhere and leave nothing due.
#
# What the run says is read off standard error, where the report is written,
# and the patterns cross the fold the way the hold rows in
# genesis_ci_walk-holds.t do, so each one names the axis it is asserting.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use JSON::PP;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Every PATCH a run sent, oldest first, as the call log recorded it, so a row
# can read the url it named as well as the body it carried.
sub patch_calls {
	my ($gh) = @_;
	return grep {($_->{method} // '') eq 'PATCH'} gh_calls($gh);
}

# One due control commit, written through the harness and committed by hand,
# because the run reads require_pr out of that very file and a body composed
# here that dropped the key would take the whole arm with it, while the
# harness's own commit carries a message the rows below cannot name.
sub due_commit {
	my ($h, %opts) = @_;
	my $path = $h->write_env_file('prod', params => $opts{params},
		commit => 0);
	return commit_on_control($h,
		files   => {$path => slurp($h->a."/$path")},
		message => $opts{message},
		push    => 1,
	);
}

subtest 'an approved pull request freezes' => sub {
	plan tests => 10;

	my $h   = ready(kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $pr  = $h->pr_branch('prod');

	my $proposed = due_commit($h, params => {instances => 2},
		message => 'Raise the cf instance count');
	run_genesis($h, 'propagate', '-y');
	refresh($h, 'a', $pr);
	my $frozen_at = remote_sha($h, $pr);

	# The pull request that run opened, taken off the pointer the run wrote
	# rather than guessed at, and closed so that the approved one below is the
	# only one open on the branch.
	my $opened = record_at($h, $h->env_path('prod').'/proposed')->{number};
	gh_close_pr($gh, $opened, merged => 0);

	my $number = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'approved', reviewer => 'dbell');
	fixture_proposed($h, 'prod', control => $proposed, pr => $number);

	my $later = due_commit($h, params => {instances => 3},
		message => 'Raise it again');

	# How much of the call log belongs to the run that stood the fixture up,
	# so what is counted below is what the frozen run itself sent.
	my $already = scalar(() = gh_calls($gh));

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');
	is(remote_sha($h, $pr), $frozen_at, 'the branch on R did not move');

	like($err, qr/^\s*prod: held, awaiting merge \(#$number\)$/m,
		'the environment is recorded held, awaiting merge with the number');
	like($err, qr/control\@\Q@{[substr($later, 0, 7)]}\E[^\n]*\bheld\b/,
		'the new due commit is held');
	like($err, qr/control\@\Q@{[substr($later, 0, 7)]}\E[^\n]*\n\s*H awaiting merge \(#$number\)/,
		'and its reason names the merge it is waiting for');
	unlike($err, qr/^\s*prod: propagated\b/m, 'and never propagated');

	my @sent = gh_calls($gh);
	splice(@sent, 0, $already);
	my @writes = grep {($_->{method} // 'GET') ne 'GET'} @sent;
	is(scalar @writes, 0, 'the run touched the pull request not at all');
	is(record_at($h, $h->env_path('prod').'/proposed')->{control_commit},
		$proposed, 'and left the proposed record naming what is open');
};

# Proves T265: a pull request whose reviewer asked for changes is rebuilt with
# the fix that answers them, pushed, and its new body names that review, with
# the reviewer, the date, and the words they wrote.
#
# The pull request is declared on the double and its branch is not yet on R,
# which is the shape the harness's own with_open_pr builds and the shape the
# first row of genesis_ci_pullrequest-title.t takes.  A run that rebuilds a
# branch R already carries needs the lease Task 16.11 puts on the publish
# spec, and until that lands such a push is refused as a non-fast-forward
# before any body is composed.  What the reviewer asked for is therefore a
# fixture on the API side and the branch R gains is this run's own.
#
# Two of the seven assertions start red, which are the two that read the
# quoted review off the body the run sent.  The other five are guards, each
# marked where it stands, because the rebuild, the push, and the update all
# landed with the arm itself.
subtest 'changes requested rebuilds and names the review' => sub {
	plan tests => 8;

	my $h  = ready(kit => 'omega-v2.7.0');
	my $gh = $h->{gh};
	my $pr = $h->pr_branch('prod');

	# What the reviewer read: one due control commit, a pull request open on
	# the branch that proposes it, and a review asking for a change with the
	# reason written out.
	my $proposed = due_commit($h, params => {instances => 2},
		message => 'Raise the cf instance count');

	my $number = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'changes_requested',
		reviewer => 'dbell', at => '2026-09-12T14:05:00Z',
		review_body => 'The instance count should wait for the capacity plan.');
	fixture_proposed($h, 'prod', control => $proposed, pr => $number);

	# The answer to the review, landing on control the way every fix does.
	my $fix = due_commit($h, params => {instances => 1},
		message => 'Hold the instance count at one');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');

	# A guard rather than a row that starts red: everything below is read off
	# a run that got as far as the update, so the exit is read first.
	is($exit, 0, 'the run succeeded');

	# A guard for the same reason: the rebuild and its push are the arm's own
	# work, which landed with Task 16.1, and T265 asks that the fix be what
	# the branch on R now carries, so the clause is read here beside the rest.
	refresh($h, 'a', $pr);
	is(harness_marker($h, "origin/$pr"), $fix,
		'the branch on R was rebuilt at the fix');

	# A guard: which pull request the update named is Task 16.5's work, and it
	# is read because the body asserted below is this call's own.
	my ($call) = patch_calls($gh);
	like($call->{url}, qr{/pulls/$number$},
		'the update named the pull request the reviewer read');

	my $patch = JSON::PP->new->decode($call->{body} // '{}');
	like($patch->{body},
		qr/^Changes were requested on #$number by dbell on 2026-09-12:$/m,
		'the body names the reviewer and the date');
	like($patch->{body},
		qr/^> The instance count should wait for the capacity plan\.$/m,
		'and quotes their words');

	# The two paragraphs come off one renderer, so the one thing that could
	# tell them apart in a body is the opening sentence each caller gives it.
	# A rebuild that answers a reviewer never supersedes anything.
	unlike($patch->{body}, qr/Supersedes/,
		'without the opening a superseding body would have used');

	# A guard: the report goes to standard error and is folded to the terminal
	# width on its way out, so it is read off the run put back on one line.
	like(unfolded($out, $err), qr/\bprod: propagated\b/,
		'and the environment is recorded propagated');
};

done_testing;
