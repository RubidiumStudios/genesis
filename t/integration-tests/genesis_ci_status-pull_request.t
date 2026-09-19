#!/usr/bin/env perl
# Proves T288 and T291: the pull request column read with a token and read
# without one, the branch matched by the accessor that opens it, and the held
# qualifier standing beside the component on one row.
#
# The baseline kept only heads matching propagate/<env>/, which propagation
# has never opened, so the column never matched a real pull request at all.
# It now reads the walk's own pr field, filled against the branch
# Genesis::Top::pr_branch_for composes, so the name the column reads and the
# name propagation opens come from one accessor.
#
# Which assertions discriminate and which guard is said beside each.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub plain {
	# The tree with every SGR sequence taken out, which is what the words of
	# a row are asserted against.  NOCOLOR is set above and the renderer
	# honours it, so this ordinarily changes nothing.  It is here because a
	# colour escape ends in the letter m, so a word boundary can never hold
	# in front of a coloured name, and a row that met one would fail for a
	# reason that had nothing to do with the words.
	my ($tree) = @_;
	$tree =~ s/\e\[[0-9;]*m//g;
	return $tree;
}

sub env_line {
	# The one line of the tree that belongs to this environment, selected by
	# its leading indent as well as its name, so a header carrying the name
	# could not stand in for it.
	my ($tree, $name) = @_;
	my ($line) = grep { /^\s+\Q$name\E\s/ } split(/\n/, plain($tree));
	return $line // '';
}

subtest 'the column composes the branch the run opens' => sub {
	# Two assertions and one restoration.
	plan tests => 3;

	# with_open_pr builds the pull request tree, opens the pull request on
	# the double, and writes the proposed record naming it, so this row
	# builds none of that itself.  The kit is named because this command
	# loads every environment it reports on, and an environment whose kit
	# nothing installed reads as a load error and says nothing else.
	my ($h, $gh, $pr) = with_open_pr(kit => 'omega-v2.7.0');

	# A guard.  The head the run opens is pr/qa/bosh, which pr_branch_for
	# composes, and it is green today.  It goes red against a column that
	# carries a literal prefix of its own, which is the implementation the
	# baseline carried and the one this row exists to keep out.
	isnt($h->pr_branch('qa'), 'propagate/qa/bosh',
		'the run opens pr/qa/bosh and never propagate/qa/bosh');

	my ($out) = run_genesis($h, 'pipeline-status');
	like(env_line($out, 'qa'), qr/\[PR #$pr open: unreviewed\]/,
		'the column reads the pull request the walk matched');
};

subtest 'the record is read without a token and validated with one' => sub {
	# Six assertions and one restoration for each of the two commands.
	plan tests => 8;

	my ($h, $gh, $pr) = with_open_pr(kit => 'omega-v2.7.0');

	gh_no_token($h);
	my ($no_token, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'the command reports with no token');
	like(env_line($no_token, 'qa'), qr/PR #$pr/,
		'the pull request number comes from the record');
	like(env_line($no_token, 'qa'), qr/\Qcontrol@\E[0-9a-f]{7}/,
		'the control commit comes from the record');
	like(env_line($no_token, 'qa'), qr/review state unread, possibly outdated/,
		'the state is flagged as unread and possibly outdated');
	is_deeply([gh_calls($gh)], [], 'no GitHub call was made at all');

	my ($with_token) = run_genesis($h, 'pipeline-status');
	unlike(plain($with_token), qr/possibly outdated/,
		'with a token the record is validated and the flag is dropped');
};

subtest 'the held qualifier and the pull request stand on one row' => sub {
	# One assertion and one restoration.
	plan tests => 2;

	my ($h, $gh, $pr) = with_open_pr(kit => 'omega-v2.7.0',
		review => 'approved');

	my ($out) = run_genesis($h, 'pipeline-status');
	like(env_line($out, 'qa'),
		qr/\[PR #$pr open: approved\].*held, awaiting merge \(#$pr\)/,
		'the component says which one and the qualifier says what it waits for');
};

done_testing;
