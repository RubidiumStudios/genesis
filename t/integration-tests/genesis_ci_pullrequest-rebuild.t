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

	# A guard, for the reason the exit row above gives.
	ok((grep {$_ eq 'prod.yml'} @files), 'and the set itself is still there');

	# A guard, for the reason the exit row above gives.
	is(harness_marker($h, "origin/$pr"), $git->sha($h->control),
		'with the branch rebuilt at the newest due commit');
};

done_testing;
