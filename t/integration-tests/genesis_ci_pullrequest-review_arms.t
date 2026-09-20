#!/usr/bin/env perl
# Proves T264 and T265, which are two of the four arms a reviewer's decision
# takes.  T264 has an approved pull request freeze, so the run neither rebuilds
# nor pushes the branch, holds the new due commit with the reason
# awaiting-merge, and records the environment held with the number beside it.
# T265 has a pull request whose reviewer asked for changes rebuilt with the fix
# that answers them, pushed, and its new body naming that review.
#
# T264's row needs a pull request branch that R already carries and a reviewer
# who has approved what is on it, so the first run is what builds and publishes
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
#
# Four of the freeze row's assertions are guards rather than its red, and they
# are the branch on R not moving, the environment never being propagated, the
# run touching the pull request not at all, and the proposed record standing
# still.  All four were green before the freeze existed, and every one of them
# for the same wrong reason: an unfrozen run rebuilds the branch and pushes it,
# the push of a branch R already carries is sent without a lease, and git
# refuses it as a non-fast-forward, so the environment's publish is rejected
# before any of the four is reached.  What carries the row's red is the other
# half, which is the exit status, the environment's own line, the held commit,
# and its reason.  The four become discriminating where the publish spec
# carries expect, because the run has then left the branch alone rather than
# been refused.
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

subtest 'an approved pull request freezes' => sub {
	plan tests => 11;

	my $h   = ready(kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $pr  = $h->pr_branch('prod');

	my $proposed = due_commit($h, 'prod', params => {instances => 2},
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

	my $later = due_commit($h, 'prod', params => {instances => 3},
		message => 'Raise it again');

	# How much of the call log belongs to the run that stood the fixture up,
	# so what is counted below is what the frozen run itself sent.
	my $already = scalar(() = gh_calls($gh));

	# What this clone holds for the pull request branch before the run, which
	# is the one thing a read of R cannot say: the arm answers ahead of
	# deliver's switch, so no local branch is cut or moved either.
	my $local_before = ref_in($h->a, "refs/heads/$pr") // '(none)';

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');
	is(remote_sha($h, $pr), $frozen_at, 'the branch on R did not move');

	# Not claimed as red on arrival.  restore_branch puts every publish-set
	# branch back at its pre-run tip, so an unfrozen run's local branch may
	# well have been restored before this read, and what the assertion is here
	# for is to keep saying what it says once the four guards above become
	# discriminating.
	is(ref_in($h->a, "refs/heads/$pr") // '(none)', $local_before,
		'and this clone\'s own copy of it is where it was too');

	like($err, qr/^\s*prod: held, awaiting merge \(#$number\)$/m,
		'the environment is recorded held, awaiting merge with the number');
	like($err, qr/control\@\Q@{[substr($later, 0, 7)]}\E[^\n]*\sheld\s*$/m,
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

# A frozen environment that was already holding something for another reason
# still waits for its merge and for nothing else.
#
# The walk sends every commit from the first hold backwards to held and
# everything ahead of it to pending, so an environment with a gate in range
# reaches the arm with held already full, and the freeze appends its own
# entries behind what is there.  A qualifier that read the front of that list
# would name the gate and send the operator to certify a deployment, while
# what releases this environment is the merge nobody has made.
#
# Three commits stand on control.  The first is deliverable, the second
# carries a Genesis-Stage trailer and is the gate, and the third sits behind
# it.  A delivery runs up to and including its gate, so the first two are
# pending and the third is held as gate-ahead, which is the entry that stands
# at the front of the list before the arm is ever called.
subtest 'a gate ahead of the freeze keeps the merge qualifier' => sub {
	plan tests => 6;

	my $h  = ready(kit => 'omega-v2.7.0');
	my $gh = $h->{gh};
	my $pr = $h->pr_branch('prod');

	my $due = due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	due_commit($h, 'prod',
		params   => {instances => 2, signing => 'rotated'},
		message  => 'Rotate the uaa signing key',
		trailers => {'Genesis-Stage' =>
			'rotate the uaa signing key before anything after it'});
	due_commit($h, 'prod', params => {instances => 3, signing => 'rotated'},
		message => 'Raise the cf instance count again');

	my $number = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'approved', reviewer => 'dbell');
	fixture_proposed($h, 'prod', control => $due, pr => $number);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');

	# A guard rather than a row that starts red: everything below is read off
	# a run that got as far as the report.
	is($exit, 0, 'the run succeeded');

	# A guard, and the one that gives the row its teeth.  Nothing below
	# discriminates unless the held list really does carry the gate ahead of
	# what the freeze appended, and this is what says it does.
	my $said = unfolded($out, $err);
	like($said, qr/gate: rotate the uaa signing key before anything after it/,
		'the gate is held, with the reason the trailer gave');

	like($err, qr/^\s*prod: held, awaiting merge \(#$number\)$/m,
		'the environment waits for its merge');
	unlike($said, qr/awaiting deployment/,
		'rather than for the deployment the gate at the front of the list '.
		'would have named');

	# The per-commit axis is read on its own entry and never on the front of
	# the list, so it says the same thing here that it says with no gate.
	like($err, qr/control\@\Q@{[substr($due, 0, 7)]}\E[^\n]*\n\s*H awaiting merge \(#$number\)/,
		'and the commit the freeze holds still names that merge');
};

# Proves T265: a pull request whose reviewer asked for changes is rebuilt with
# the fix that answers them, pushed, and its new body names that review, with
# the reviewer, the date, and the words they wrote.
#
# The row takes the two-run form over a published branch, which is what a
# reviewer actually reads.  The first run builds the branch, publishes it, and
# opens a pull request of its own, and the second run rebuilds that very
# branch with the fix.  The rewrite lands because the publish spec now pushes
# against the tip the run read, so a branch R already carries is no longer
# refused as a non-fast-forward.
#
# The pull request the first run opened is unreviewed, and the double has no
# way to add a review to a pull request it already holds, so the row closes
# that one and declares the reviewed one in its place, the way the freeze row
# above does.  Leaving both open would put the several-pull-requests warning
# in the middle of a row about a rebuild.
#
# Two of the seven assertions start red, which are the two that read the
# quoted review off the body the run sent.  The other five are guards, each
# marked where it stands, because the rebuild, the push, and the update all
# landed with the arm itself.
subtest 'changes requested rebuilds and names the review' => sub {
	plan tests => 9;

	my $h  = ready(kit => 'omega-v2.7.0');
	my $gh = $h->{gh};
	my $pr = $h->pr_branch('prod');

	# What the reviewer read: one due control commit, and the run that puts
	# the branch proposing it on R.
	my $proposed = due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	run_genesis($h, 'propagate', '-y');
	refresh($h, 'a', $pr);

	# The pull request that run opened, taken off the pointer the run wrote
	# rather than guessed at, and closed so that the reviewed one below is the
	# only one open on the branch.
	my $opened = record_at($h, $h->env_path('prod').'/proposed')->{number};
	gh_close_pr($gh, $opened, merged => 0);

	# The review itself, asking for a change with the reason written out.
	my $number = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'changes_requested',
		reviewer => 'dbell', at => '2026-09-12T14:05:00Z',
		review_body => 'The instance count should wait for the capacity plan.');
	fixture_proposed($h, 'prod', control => $proposed, pr => $number);

	# The answer to the review, landing on control the way every fix does.
	my $fix = due_commit($h, 'prod', params => {instances => 1},
		message => 'Hold the instance count at one');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');

	# A guard rather than a row that starts red: everything below is read off
	# a run that got as far as the update, so the exit is read first.
	is($exit, 0, 'the run succeeded');

	# A guard for the same reason: the rebuild and its push are the arm's own
	# work, and T265 asks that the fix be what the branch on R now carries, so
	# the clause is read here beside the rest.  It says more than it did
	# before the branch was published, because the second push had to beat a
	# tip R already held to get there.
	refresh($h, 'a', $pr);
	is(harness_marker($h, "origin/$pr"), $fix,
		'the branch on R was rebuilt at the fix');

	# A guard.  Which pull request the update named is proved elsewhere, and
	# it is read here because the body asserted below is this call's own.
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
	#
	# A guard, and green on arrival: the supersedes paragraph is composed only
	# where the state is closed unmerged, which this row's state is not, so
	# nothing here has ever put that word in the body.  It is what would catch
	# a renderer that started writing both openings into one body.
	unlike($patch->{body}, qr/Supersedes/,
		'without the opening a superseding body would have used');

	# A guard: the report goes to standard error and is folded to the terminal
	# width on its way out, so it is read off the run put back on one line.
	like(unfolded($out, $err), qr/\bprod: propagated\b/,
		'and the environment is recorded propagated');
};

done_testing;
