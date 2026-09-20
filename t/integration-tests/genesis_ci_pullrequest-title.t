#!/usr/bin/env perl
# Proves T261, T262, T263, and T275: the pull request's title is the aggregate
# commit's own subject and moves with the marker, a pull request opened after
# every earlier attempt was closed without merging names those attempts and
# carries what their reviewers said, an open pull request nobody has reviewed
# is rebuilt and its title and body updated, and a branch with several pull
# requests open on it warns and is acted on by what a reviewer decided about
# the first.
#
# Neither of the first two rows is green on arrival, and both of them run
# against a pull request that is already open, so both meet the same three
# things in the same order.
# Genesis::curl refuses PATCH outright, so an update of one pull request has
# never left the process and the run dies there.  The double then serves no
# PATCH either, so the request falls through every route it has, is answered an
# empty array and a 200, and dies where the caller reads a number off what it
# was handed.  The title is the third: it was whatever the pull request was
# opened with, so nothing about an open one said which control commit it
# proposed.
#
# The first row's open pull request is declared on the double and its branch is
# not on R, which is the shape the harness's own with_open_pr builds.  The
# earlier run's title and proposed record are what the marker has to move off.
# A run rebuilding a branch R already carries needs the lease the publish spec
# carries, and a push that went without one would be rejected as a
# non-fast-forward before any of this is reached.
#
# The due commits are laid through the environment file at the deployment root
# rather than under prod/, because a path under prod/ is in no propagation set
# and a commit written there would route nowhere and leave nothing due.
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

subtest 'an unreviewed pull request is rebuilt and retitled' => sub {
	plan tests => 10;

	my $h   = ready(kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('prod');

	# What an earlier run left behind: a pull request open on this branch,
	# nobody has reviewed, titled and recorded for the control commit that
	# run proposed.
	my $earlier = $git->sha($h->control);
	my $stale   = sprintf('[pipeline] control@%s -> prod',
		$git->sha($earlier, short => 1));
	my $number  = gh_pull_request($gh,
		env    => 'prod',
		head   => $pr,
		base   => $h->slug('prod'),
		review => 'none',
		title  => $stale,
		body   => "Carries 1 control commit:\n",
	);
	$h->fixture_proposed('prod', pr => $number, control => $earlier);

	my $first = due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	my $second = due_commit($h, 'prod', params => {instances => 3},
		message => 'Raise it again');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');

	refresh($h, 'a', $pr);
	is(harness_marker($h, "origin/$pr"), $second,
		'the branch was rebuilt at the newest due commit');

	my ($call) = patch_calls($gh);
	like($call->{url}, qr{/pulls/$number$},
		'the update named the pull request that was open');

	my $patch = JSON::PP->new->decode($call->{body} // '{}');
	is($patch->{title},
		sprintf('[pipeline] control@%s -> prod', $git->sha($second, short => 1)),
		'the title is the aggregate subject, moved with the marker');
	isnt($patch->{title}, $stale,
		'rather than the one the pull request was opened with');
	like($patch->{body}, qr/Carries 2 control commits:/,
		'and the body lists what the aggregate now carries');
	is(scalar(grep {($_->{method} // '') eq 'POST'} gh_calls($gh)), 0,
		'the open pull request is updated rather than a second one opened');

	# The report goes to standard error and is folded to the terminal width
	# on its way out, so it is read off the run put back on one line.
	like(unfolded($out, $err), qr/\bprod: propagated\b/,
		'the environment is recorded propagated');

	my $rec = record_at($h, $h->env_path('prod').'/proposed');
	is($rec->{control_commit}, $second,
		'and the proposed record moved with it');
};

subtest 'several open pull requests warn and the first decides' => sub {
	plan tests => 6;

	my $h  = ready(kit => 'omega-v2.7.0');
	my $gh = $h->{gh};
	my $pr = $h->pr_branch('prod');

	# Declared oldest first and answered newest first, the way GitHub answers
	# a listing, so the pull request the run acts on is the newer of the two
	# and a row that read position zero of a declaration order would not say
	# the same thing.
	my $older = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'none');
	my $newer = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'none');

	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');

	# The next two are guards rather than rows that start red.  The warning and
	# the numbers beside it are the state reader's own work, which landed with
	# it, and they are read here because this is the one row that stands two
	# pull requests up for the reader to warn about.
	my $said = unfolded($out, $err);
	like($said, qr/several pull requests are open/i, 'it warns');
	like($said, qr/#$newer, #$older/, 'and reports the rest by number');

	my @patched = patch_calls($gh);
	is(scalar(grep {($_->{url} // '') =~ m{/pulls/$newer$}} @patched), 1,
		'and acts on the one the listing answers first');
	is(scalar(grep {($_->{url} // '') =~ m{/pulls/$older$}} @patched), 0,
		'leaving the other one it never touched');
};

# Proves T262: a third pull request names the two closed attempts, carries
# their rejection text or a link, carries nothing from their branches, and
# never names the merged one.
#
# A rejection is closed and gone, so the whole chain is recorded in the pull
# request that follows it, and there is nowhere else to read it from.
#
# The leftover is on the branch this clone still carries and not on the branch
# R carries.  A rebuild of a branch R holds goes under the lease the publish
# spec carries, and one pushed without a lease would be refused as a
# non-fast-forward, with the environment recording that its publish was
# rejected before any of the title or the body is reached.
subtest 'a new pull request supersedes the closed attempts' => sub {
	plan tests => 10;

	my $h   = ready(kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('prod');

	my $merged = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'),
		title => '[pipeline] control@0000000 -> prod');
	gh_merge_pr($gh, $merged, method => 'rebase');

	my $rejected = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'changes_requested',
		reviewer => 'dbell',
		review_body => 'The instance count should wait for the capacity plan.');
	gh_close_pr($gh, $rejected, merged => 0);

	my $bare = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'none');
	gh_close_pr($gh, $bare, merged => 0);

	$h->local_branch($pr, at => $git->sha('origin/'.$h->slug('prod')));
	hand_commit($h, $pr, copy => 'a', push => 0,
		files   => {'prod/stray.yml' => "---\nstray: yes\n"},
		message => 'a leftover from an attempt');
	$h->stand_on($h->control);

	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');

	# A guard rather than a row that starts red: the arm that opens a pull
	# request is already in place, and the exit is read here because
	# everything below it is read off a run that got as far as the create.
	is($exit, 0, 'the run succeeded');

	my ($create) = grep {($_->{method} // '') eq 'POST'} gh_calls($gh);
	my $opened = JSON::PP->new->decode($create->{body});

	# The next two do not start red, because title_for already appends the
	# list.  They are here because this is the first row that reaches its
	# supersedes branch at all: every earlier row runs against an empty
	# superseded list, so take that branch out and nothing but these two
	# notices.  That is T261's supersedes clause, and it is proved here.
	#
	# The two closed attempts are named in whichever order the listing gave
	# them, because which of them GitHub answers first is the API's business
	# and this row is about both of them being there and the merged one not.
	like($opened->{title},
		qr/\(supersedes (?:#$rejected, #$bare|#$bare, #$rejected)\)$/,
		'the title names both closed attempts');
	unlike($opened->{title}, qr/#$merged\b/, 'and never the merged one');
	like($opened->{body},
		qr/Supersedes #$rejected\. Changes were requested on #$rejected by dbell/,
		'the body opens on the attempt it supersedes');
	like($opened->{body},
		qr/^> The instance count should wait for the capacity plan\.$/m,
		'and quotes the words the API gave');
	like($opened->{body}, qr{#$bare, closed without merging: https?://\S+/pull/$bare},
		'and links the attempt that carried no text');

	# The title is checked for the merged number above, and the body is
	# checked for it here.  The body is composed from the rejected list
	# alone, so this holds by construction today, and a change to what that
	# list is built from would otherwise be caught on one axis only.
	unlike($opened->{body}, qr/#$merged\b/,
		'and the body names the merged one no more than the title does');

	# The other half of the pairing the changes-requested row makes, which
	# asserts that its own body supersedes nothing.  The words themselves are
	# in this body, carried in after the Supersedes prefix the superseding
	# path puts in front of them, so the assertion is anchored to the start of
	# a line, where only a rebuild answering a reviewer opens on them.
	#
	# A guard, and green on arrival: one renderer writes both paragraphs and
	# the prefix is what tells them apart, so this is what would catch a
	# superseding body that had lost its prefix and begun reading as a plain
	# answer to a review.
	unlike($opened->{body}, qr/^Changes were requested/m,
		'and never opens the way a body answering a reviewer opens');

	# A guard rather than a row that starts red: the reset that drops what the
	# branch carried landed with the arm itself, and T262 asks that a
	# superseding pull request carry nothing from the attempts before it, so
	# the clause is read here beside the rest of the row.
	refresh($h, 'a', $pr);
	my @files = $git->ls_tree("origin/$pr", 'prod');
	ok(!(grep {m{prod/stray\.yml}} @files),
		'the branch carries nothing from the attempts');
};

done_testing;
