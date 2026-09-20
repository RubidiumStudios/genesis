#!/usr/bin/env perl
# Proves T268: commits on the pull request branch that the run did not write
# are reported by count and author before the rebuild discards them, and the
# report appears beside that environment's outcome rather than as one of its
# own.
#
# The branch is derived state, so the rebuild itself is right and already
# happens.  What the row adds is the sentence.  I4 forbids resolving a
# divergence silently, and before this row the two hand pushes went under the
# reset with nothing said about either of them.
#
# Both due commits are laid through due_commit, which writes the environment
# file at the deployment root, because that file is the only thing a commit
# can touch that routes to this environment at all.
#
# The two rows below it prove T270 and T276, which are the other side of the
# same rebuild: what a run does when the branch it would build is the branch
# that is already there.  The answer is the marker walk on both branches and a
# comparison of the two trees, so a squash, an amended subject, and a
# coincidental short hash in somebody else's subject each get the answer the
# tip's subject could not give.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the rebuild reports what it discards' => sub {
	plan tests => 9;

	my $h   = ready(kit => 'omega-v2.7.0');
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('prod');

	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');

	# The first run opens the pull request and leaves one aggregate on the
	# branch, which is the commit carrying a marker that the report below has
	# to tell apart from the two hand pushes.
	run_genesis($h, 'propagate', '-y');

	hand_commit($h, $pr, copy => 'b',
		files   => {'prod/extra.yml' => "---\nextra: yes\n"},
		message => 'a teammate edits the proposal');
	hand_commit($h, $pr, copy => 'b',
		files   => {'prod/more.yml' => "---\nmore: yes\n"},
		message => 'and again');

	# The clone has seen the branch move, which is the state a run whose
	# refresh reached the pull request branch stands in.  It is here so that
	# the lease the publish pushes under is taken against what R carries now,
	# and this row stays about the report rather than about the lease.
	refresh($h, 'a', $pr);

	due_commit($h, 'prod', params => {instances => 3},
		message => 'Raise it again');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');

	# A guard.  The rebuild already happens, so this row and the three at the
	# foot of the subtest are green before the report exists.  They are here
	# to catch a report that bought its sentence by leaving the hand pushes
	# standing, or by refusing the run it was meant to describe.
	is($exit, 0, 'the run succeeded');

	my $said = unfolded($out, $err);
	like($said, qr/2 commits on \Q$pr\E that this run did not write/,
		'the report gives the count') or diag($said);
	like($said, qr/that this run did not write, by [^,]+,/,
		'and the author who wrote them') or diag($said);
	like($said, qr/prod: propagated, 2 commits on \Q$pr\E/,
		'and it stands beside that environment\'s outcome, not in place of it')
		or diag($said);

	refresh($h, 'a', $pr);
	my @files = $git->ls_tree("origin/$pr", '.');

	# A guard, for the reason the exit row above gives.
	ok(!(grep {m{^prod/}} @files), 'the rebuild discarded them');

	# A guard, for the reason the exit row above gives.  The set is read
	# through the harness's own reader rather than pinned to a literal file
	# name at the repository root, so a deployment root laid in a
	# subdirectory moves the guard with it instead of going red beside it.
	#
	# The set itself has to be non-empty for the guard to mean anything.  A
	# reader that answered nothing would leave nothing missing, and the row
	# would read as green while asserting about no file at all.  Both halves
	# go in the one ok, so saying it costs no assertion.
	my %kept    = map {($_ => 1)} @files;
	my @set     = propagation_set($h, 'prod');
	my @missing = grep {!$kept{$_}} @set;
	ok(@set && !@missing, 'and the set itself is still there')
		or diag(@set ? "missing from the branch: @missing"
		             : 'the propagation set came back empty');

	# A guard, for the reason the exit row above gives.
	is(harness_marker($h, "origin/$pr"), $git->sha($h->control),
		'with the branch rebuilt at the newest due commit');
};


# Proves T270: a repeated run with nothing changed pushes nothing and touches
# no pull request, and a branch whose tip subject was rewritten by a merge
# still reads its marker from the body.
subtest 'a repeated run is idempotent by marker and tree' => sub {
	plan tests => 9;

	my $h   = ready(kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('prod');

	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');

	# The first run opens the pull request itself, through sync_pull_request,
	# so the row opens none of its own.  A second one on the same head and
	# base is a pull request the product never made, and the write count
	# below would read it as this run's work.
	run_genesis($h, 'propagate', '-y');

	refresh($h, 'a', $pr);
	my $tip_before   = $git->sha("origin/$pr");
	my $calls_before = scalar gh_calls($gh);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the second run succeeded');

	my $said = unfolded($out, $err);
	like($said, qr/prod: idempotent/, 'the environment is recorded idempotent')
		or diag($said);

	refresh($h, 'a', $pr);
	is($git->sha("origin/$pr"), $tip_before, 'nothing was pushed');

	# The calls the first run made are behind us, so the slice is what the
	# second run sent and the pull request it opened is not counted again.
	my @calls  = gh_calls($gh);
	my @writes = grep {($_->{method} // 'GET') ne 'GET'}
		@calls[$calls_before .. $#calls];
	is(scalar @writes, 0, 'and no pull request was touched');
	cmp_ok(scalar @calls, '>', $calls_before, 'though the state was read');

	# A merge that rewrites the subject keeps the marker in the body, so the
	# walk still finds it where a subject match would not.
	my $h2  = ready(kit => 'omega-v2.7.0');
	my $due = due_commit($h2, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	run_genesis($h2, 'propagate', '-y');
	squash_merge($h2, 'prod', subject => 'Merge the proposal', keep_marker => 1);
	refresh($h2, 'a', $h2->slug('prod'));
	is(harness_marker($h2, 'origin/'.$h2->slug('prod')), $due,
		'a rewritten subject still reads its marker from the body');
};

# Proves T276: the three shapes that broke idempotency by commit subject, each
# answered by the marker walk.
#
# The first shape is the one that goes through settled.  The aggregate's own
# subject is rewritten and its marker pushed into the body, which is what a
# merge does to a message, so the control commit is still due, the whole arm
# runs, and the run reads idempotent only because settled compared the marker
# on R's copy of the branch against the tree the writer had just built.  The
# other two shapes are end-to-end guards for the hazard rather than tests of
# that sub: the hand edit goes through the discard report, and the coincidence
# goes through the walk's base reader and the marker's own rule about what
# counts as a marker at all.
subtest 'the three subject-match shapes give the right answer now' => sub {
	plan tests => 10;

	# A rewritten subject on the aggregate itself, which is what a squash
	# merge does to a message, because the subject a reader would walk is
	# the merger's and the marker is pushed down into the body.  The
	# subject match re-propagated on it, and this is the shape that reaches
	# settled to say the walk does not.
	#
	# The rewrite is made on the pull request branch rather than by merging
	# onto the deployment branch, and that matters.  A squash merge copies
	# the aggregate's tree onto the deployment branch, so the rebuild's
	# mirror has nothing to write, the single writer refuses an empty commit,
	# and the run aborts before settled is ever asked.  Amending the
	# aggregate in place leaves the deployment branch where it was, so the
	# rebuild is a real commit, and R's copy of the branch still names the
	# control commit in its body and still holds the tree the rebuild
	# produces.  Both halves of settled then agree and the environment reads
	# idempotent.  The discard report stays silent, because the one commit
	# above the deployment branch is the aggregate and its body still carries
	# a marker.
	my $squashed = ready(kit => 'omega-v2.7.0');
	my $squashed_pr = $squashed->pr_branch('prod');
	due_commit($squashed, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	run_genesis($squashed, 'propagate', '-y');
	amend_tip($squashed, $squashed_pr, copy => 'b',
		subject => 'Merge pull request #1');

	# Here so that a run which decides to push is refused for a reason of its
	# own rather than by a lease taken against what this clone last saw.  The
	# row expects no push at all, and this keeps a failure legible.
	refresh($squashed, 'a', $squashed_pr);

	my ($sq_out, $sq_err) = run_genesis($squashed, 'propagate', '-y');
	my $squash_said = unfolded($sq_out, $sq_err);
	like($squash_said, qr/prod: idempotent/,
		'a rewritten subject does not re-propagate') or diag($squash_said);
	unlike($squash_said, qr/prod: propagated/, 'and nothing is delivered again')
		or diag($squash_said);

	# A hand edit on the pull request branch itself, which is a divergence to
	# report and rebuild rather than a state to skip.
	my $edited    = ready(kit => 'omega-v2.7.0');
	my $edited_pr = $edited->pr_branch('prod');
	due_commit($edited, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	run_genesis($edited, 'propagate', '-y');
	hand_commit($edited, $edited_pr, copy => 'b',
		files => {'prod/note.md' => "a note\n"}, message => 'tidy up');

	# The publish leases the branch against the tip this clone last saw, and
	# the run's own refresh fetches control and the deployment branches and
	# no pull request branch, so the clone is shown the hand commit here.
	# Without it the push is refused once and the row reads a refusal where
	# it means to read a rebuild.
	refresh($edited, 'a', $edited_pr);

	my ($ed_out, $ed_err) = run_genesis($edited, 'propagate', '-y');
	my $edited_said = unfolded($ed_out, $ed_err);
	like($edited_said, qr/did not write/,
		'an edited branch is discarded and rebuilt rather than skipped')
		or diag($edited_said);
	unlike($edited_said, qr/prod: idempotent/, 'and never reads as settled')
		or diag($edited_said);

	# A coincidental short hash in an unrelated subject, which suppressed a
	# real propagation at the baseline.  The subject is not marker-shaped,
	# because one that was would be a marker by the reader's own rule.
	my $coincidence = ready(kit => 'omega-v2.7.0');
	my $co_pr       = $coincidence->pr_branch('prod');
	my $due         = due_commit($coincidence, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	my $short       = $coincidence->git('a')->sha($due, short => 1);

	# A hand commit is made on a branch that already stands somewhere, so the
	# branch is cut first, off the deployment branch, which is where the
	# product opens it.
	local_branch($coincidence, $co_pr,
		at => $coincidence->slug('prod'), push => 1);
	hand_commit($coincidence, $co_pr, copy => 'b',
		files   => {'prod/note.md' => "a note\n"},
		message => "see $short for the context of this change");

	# Here for the reason the refresh in the shape above carries: the clone
	# has to have seen the branch move before the publish leases it.
	refresh($coincidence, 'a', $co_pr);

	my ($co_out, $co_err) = run_genesis($coincidence, 'propagate', '-y');
	my $coincidence_said = unfolded($co_out, $co_err);
	like($coincidence_said, qr/prod: propagated/,
		'a coincidental short hash no longer suppresses a real propagation')
		or diag($coincidence_said);
};

# Proves that the discard sentence survives a publish the remote refuses.
# The run is a hand push followed by the next propagate, where
# the clone has not seen the branch move, the lease is taken against what it
# last saw, and the push is turned down.  The refresh the rows above call
# after a hand commit is deliberately absent here, because the refusal is the
# thing being proved.
#
# Two writers then want the environment's outcome_detail, the delivery's
# discard sentence and the publish's own "moved on R", and the qualifier is
# appended rather than assigned so the run says both.  One commit is pushed
# by hand rather than two, so the sentence renders in its singular form.
subtest 'a refused publish keeps the discard sentence' => sub {
	plan tests => 6;

	my $h   = ready(kit => 'omega-v2.7.0');
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('prod');

	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');

	# The first run opens the pull request and leaves the aggregate on the
	# branch, which is what the hand commit lands on top of.
	run_genesis($h, 'propagate', '-y');

	hand_commit($h, $pr, copy => 'b',
		files   => {'prod/extra.yml' => "---\nextra: yes\n"},
		message => 'a teammate edits the proposal');

	my ($out, $err) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);
	# One pattern for the whole line, because what the row is about is the
	# two qualifiers standing together in the order they were written, and
	# two patterns read separately would pass on a line carrying either.
	my $both = join('',
		"prod: publish rejected, ",
		"1 commit on \Q$pr\E that this run did not write, ",
		"by [^;]+, discarded by the rebuild; ",
		"\Q$pr\E moved on R");
	like($said, qr/$both/,
		'the refused run says what it discarded and what refused it')
		or diag($said);

	# The run above fetched the branch on its way to the discard report, so
	# this run reads its lease off what R actually carries and the push lands.
	my ($out2, $err2) = run_genesis($h, 'propagate', '-y');
	my $said2 = unfolded($out2, $err2);
	like($said2, qr/prod: propagated/, 'and the next run lands the rebuild')
		or diag($said2);

	refresh($h, 'a', $pr);
	is(harness_marker($h, "origin/$pr"), $git->sha($h->control),
		'with R carrying the aggregate at the newest due commit');
};

done_testing;
