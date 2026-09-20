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
# Two more things this command does with the API are proved here.  An API it
# cannot read degrades the column and warns rather than ending the report,
# because the command's one refusal on this path is the disowned pipeline,
# and the client the report hands the walk lets a
# squash-merged marker come back, which both says where the marker came from
# and says aloud where a merged pull request names another environment.
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
use JSON::PP qw/decode_json/;

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
	# the double, writes the proposed record naming it, and installs the kit
	# this command needs to load the environment at all, so this row builds
	# none of that itself.
	my ($h, $gh, $pr) = with_open_pr();

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

	my ($h, $gh, $pr) = with_open_pr();

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
	# Two assertions and one restoration.
	plan tests => 3;

	my ($h, $gh, $pr) = with_open_pr(review => 'approved');

	my ($out) = run_genesis($h, 'pipeline-status');
	my $line = env_line($out, 'qa');
	like($line,
		qr/\[PR #$pr open: approved\].*held, awaiting merge \(#$pr\)/,
		'the component says which one and the qualifier says what it waits for');

	# The pattern above is unanchored at its tail, so the doubled phrase
	# 'held, awaiting merge (#1); awaiting merge (#1)' satisfies it exactly
	# as the single one does.  This is the row that says the wait is printed
	# once, and it goes red against a compose_phrase that prints the frozen
	# commit's reason after a qualifier that has just said the same words.
	my $said = () = $line =~ /awaiting merge/g;
	is($said, 1, 'and the wait is said once on the row rather than twice');
};

subtest 'an API that will not answer degrades rather than refusing' => sub {
	# Four assertions and one restoration.
	plan tests => 5;

	my ($h, $gh) = with_open_pr(review => 'approved');

	# The double answers every call with a resolver failure from here on,
	# which is what the reader raises its own refusal out of, so the run
	# meets an unreachable API rather than an empty one.
	gh_unreachable($gh);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'the report is produced rather than refused');
	like($err, qr/GitHub did not answer/,
		'and standard error says why the API was not consulted');
	like(env_line($out, 'qa'), qr/review state unread, possibly outdated/,
		'every environment the client would have served reads unread');
	# The refusal this command used to end on is a writing run's sentence,
	# and this command writes nothing and has no branch to decide about.
	unlike($err, qr/refuses rather than guess/,
		'and no refusal about a pull request branch is printed');
};

subtest 'a squash-merged branch reads the same in both commands' => sub {
	# Four assertions and one restoration for each of the three commands.
	plan tests => 7;

	# The site could not be given the rebase-only merge method, so the
	# aggregate went in as a squash, which means the subject on the deployment
	# branch is the merger's own and the marker the aggregate carried is
	# nowhere on the branch.  The pull request Genesis opened still says which
	# control commit went in, and that is what both commands read it back out
	# of, so a report that was handed no client would read the whole of
	# control as still due while the run read the branch as caught up.
	my $h  = ready(kit => 'omega-v2.7.0', admin => 0, delivered => []);
	my $gh = $h->{gh};

	my $due = due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the prod instance count');
	my $number = gh_pull_request($gh, env => 'prod',
		head   => $h->pr_branch('prod'),
		base   => $h->slug('prod'),
		review => 'none',
		title  => sprintf('[pipeline] control@%s -> prod', substr($due, 0, 12)));
	gh_merge_pr($gh, $number, method => 'squash');
	squash_merge($h, 'prod', keep_marker => 0,
		subject => sprintf('Raise the prod instance count (#%d)', $number));

	my ($status, undef, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'the report reads the repository');
	unlike(env_line($status, 'prod'), qr/\d+ pending/,
		'and nothing is due, the marker having come back from the merge');

	# The recovery writes its own line onto the record through note_detail,
	# so what --json carries is the account of where that marker came from.
	# The row goes red against a report that hands the walk no client, which
	# recovers nothing and leaves the field null.
	my ($json) = run_genesis($h, 'pipeline-status', '--json');
	my ($row) = grep {$_->{env} eq 'prod'}
		@{decode_json($json)->{environments}};
	is($row->{outcome_detail},
		"recovered the marker for prod from #$number",
		'and --json says which pull request the marker came back from');

	my ($out, $err) = run_genesis($h, 'propagate', '-y');
	like(unfolded($out, $err), qr/prod.*idempotent/,
		'and the run reads that same branch the same way');
};

subtest 'a merged marker naming another environment is said aloud' => sub {
	# Two assertions and one restoration.
	plan tests => 3;

	# The same squash, with the pull request Genesis wrote naming qa where
	# this branch is prod's.  A marker for another environment is not this
	# one's, and saying so is the difference between a branch that lost its
	# marker in a squash and a branch somebody merged the wrong pull request
	# into.  The report reads it through the client it now hands the walk,
	# so the warning reaches an operator who asked only for a report.
	my $h  = ready(kit => 'omega-v2.7.0', admin => 0, delivered => []);
	my $gh = $h->{gh};

	my $due = due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the prod instance count');
	my $number = gh_pull_request($gh, env => 'prod',
		head   => $h->pr_branch('prod'),
		base   => $h->slug('prod'),
		review => 'none',
		title  => sprintf('[pipeline] control@%s -> qa', substr($due, 0, 12)));
	gh_merge_pr($gh, $number, method => 'squash');
	squash_merge($h, 'prod', keep_marker => 0,
		subject => sprintf('Raise the prod instance count (#%d)', $number));

	my (undef, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'the report is still produced');
	like($err, qr/names.*qa.*rather than.*prod/s,
		'and says the merged marker names another environment');
};

done_testing;
