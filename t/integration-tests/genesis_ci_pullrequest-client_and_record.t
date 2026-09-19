#!/usr/bin/env perl
# Proves T274: a run whose environments need no API builds no client and makes
# no call, a run with one such environment builds exactly one for the whole
# run, and the proposed record is written on open, replaced on supersede, and
# deleted on merge.
#
# The first row holds a token throughout, because what it proves is that a
# repository delivering to nobody by pull request never reaches the API at
# all.  A row that withheld the token would have proved only that a run with
# no token makes no call, which is a different rule and one D44 already owns.
#
# Every due commit is laid through due_commit, or through the two helpers
# due_commit is made of where the file also has to keep a pipeline key,
# because the environment's own file at the deployment root is the only thing
# a commit can touch that routes to that environment at all.
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

subtest 'no environment needs the API, so no client is built' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['lab', 'qa'], github => 1,
		kit => 'omega-v2.7.0');
	$h->ready_envs;

	due_commit($h, $_, params => {instances => 2},
		message => 'Raise the cf instance count') for qw/lab qa/;

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');
	# The report is written to standard error, which is where every other row
	# in the suite reads a run's own words from.  The environment and its
	# outcome are pinned to one line: unfolded collapses the whole stream to
	# a single string, so a pattern spanning the two would match qa's name on
	# one report line and another environment's word several lines below it.
	like($err, qr/^\s*qa: propagated\b/m,
		'and delivered in direct mode');
	is(scalar(gh_calls($h->{gh})), 0,
		'while making no call to the API at all, not even to authenticate');
};

subtest 'one environment needs it, so one client serves the run' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['lab', 'qa', 'prod'], github => 1,
		kit => 'omega-v2.7.0');
	write_env_file($h, 'prod', pipeline => {require_pr => 'true'});
	push_from($h, 'a', $h->control);
	$h->ready_envs;
	gh_protection($h->{gh}, admin => 1);

	due_commit($h, $_, params => {instances => 2},
		message => 'Raise the cf instance count') for qw/lab qa/;

	# prod's due commit goes through the two helpers due_commit is made of.
	# due_commit writes the environment file from the harness's own mode, and
	# this harness stands in direct mode so that lab and qa need nothing of
	# the API, so the require_pr key this row turns on for prod alone would
	# be written straight back out of the file it is due to change.
	my $prod = write_env_file($h, 'prod', commit => 0,
		pipeline => {require_pr => 'true'}, params => {instances => 2});
	commit_on_control($h,
		files   => {$prod => slurp($h->a."/$prod")},
		message => 'Raise the cf instance count', push => 1);

	run_genesis($h, 'propagate', '-y');

	my @urls = map {$_->{url} // ''} gh_calls($h->{gh});
	cmp_ok(scalar @urls, '>', 0, 'the run reached the API for prod');
	is(scalar(grep {m{/user$}} @urls), 1,
		'and authenticated exactly once, so one client served the whole run');
};

subtest 'the record is written, replaced, and deleted' => sub {
	plan tests => 8;

	my $h   = ready(kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('prod');

	my $first = due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	run_genesis($h, 'propagate', '-y');

	my $opened = proposed_for($h, 'prod');
	is($opened->{control_commit}, $first,
		'the record is written when the pull request opens');

	# The reviewer closed it without merging, so the next run supersedes it
	# with one of its own rather than updating a pull request nobody can
	# merge any more.
	gh_close_pr($gh, $opened->{number}, merged => 0);

	my $second = due_commit($h, 'prod', params => {instances => 1},
		message => 'Hold it at one');
	run_genesis($h, 'propagate', '-y');

	my $replaced = proposed_for($h, 'prod');
	is($replaced->{control_commit}, $second,
		'and replaced when a new one supersedes');
	isnt($replaced->{number}, $opened->{number},
		'naming the new pull request');

	gh_merge_pr($gh, $replaced->{number}, method => 'rebase');
	squash_merge($h, 'prod', keep_marker => 1);
	run_genesis($h, 'propagate', '-y');

	is(proposed_for($h, 'prod'), undef,
		'and deleted when the walk finds it merged');
	ok(!$git->branch_exists($pr), 'with the branch gone beside it');
};

done_testing;
