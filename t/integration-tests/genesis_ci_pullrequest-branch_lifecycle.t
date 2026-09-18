#!/usr/bin/env perl
# Proves T267, T333, and T187: nothing due deletes the pull request branch on
# R and locally with the proposed record, the deletion goes as its own push
# with the tip it leases against, and a local branch R no longer carries is
# deleted rather than pushed from, so the next cycle opens cleanly.
#
# The last two rows are the preview's half of the same lifecycle.  A run given
# --dry-run reads everything a run reads and writes none of it, so an
# environment with nothing due keeps its branch on both sides and keeps its
# proposed record, and an environment with a commit due has no branch cut for
# it at all.  Neither of them pushes anything.
#
# Every due commit is laid through due_commit, which writes the environment
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
use JSON::PP;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'nothing due deletes the branch and the record' => sub {
	plan tests => 11;

	my $h   = ready(envs => ['qa'], kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('qa');

	due_commit($h, 'qa', params => {instances => 2},
		message => 'Raise the cf instance count');
	run_genesis($h, 'propagate', '-y');

	# The run opened the pull request itself and wrote the proposed record
	# naming it, so the number this row merges is read back off that record
	# rather than declared beside it, which would leave two pull requests
	# open on one branch and neither of them the run's own.
	my $proposed = record_at($h, $h->env_path('qa').'/proposed');
	my $number   = $proposed ? $proposed->{number} : undef;

	# A closed pull request of somebody else's, whose branch is on R before
	# the run and is not one this environment ever opened, so the assertion
	# that it survives says the retirement reaches only what it owns.
	my $stale = gh_pull_request($gh, env => 'qa', head => "$pr-old",
		base => $h->slug('qa'), review => 'none');
	gh_close_pr($gh, $stale, merged => 0);
	run({dir => $h->a}, 'git', 'update-ref', "refs/heads/$pr-old",
		$git->sha($h->slug('qa')));
	push_from($h, 'a', "$pr-old");
	ok(remote_sha($h, "$pr-old"), 'a branch this environment never opened is on R first');

	# The pull request merges, so the marker lands on the deployment branch
	# and nothing is due any more.
	gh_merge_pr($gh, $number, method => 'rebase');
	squash_merge($h, 'qa', keep_marker => 1);

	my $git_faulted = fault_git($h);
	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');

	refresh($h, 'a');
	ok(!remote_sha($h, $pr), 'the branch is gone from R');
	ok(!$git->branch_exists($pr), 'and gone locally');
	ok(remote_sha($h, "$pr-old"),
		'while a branch it never opened is left exactly where it was');

	is(record_at($h, $h->env_path('qa').'/proposed'), undef,
		'the proposed record was deleted');
	like($err, qr/qa: idempotent/, 'and the environment is idempotent');

	my ($call) = grep {$_->[0] eq 'push'} step_log($git_faulted);
	my %args = @{$call}[1 .. $#$call];
	my ($removal) = grep {$_->{branch} eq $pr} @{$args{refs}};
	ok($removal->{delete}, 'the removal went as a deletion on its own push');
	ok(defined $removal->{expect},
		'leased against the tip the refresh read, so a moved branch refuses');
};

subtest 'a leftover local branch is deleted rather than pushed from' => sub {
	plan tests => 6;

	my $h   = ready(envs => ['qa'], kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('qa');

	due_commit($h, 'qa', params => {instances => 2},
		message => 'Raise the cf instance count');
	run_genesis($h, 'propagate', '-y');

	# R loses the branch and L keeps it, which is the shape the second cycle
	# used to die on.  The pull request goes with it, because a head branch
	# that is gone from the remote is one the API closes the pull request on,
	# and a row that left it open would be asking about a state R cannot be in.
	my $proposed = record_at($h, $h->env_path('qa').'/proposed');
	gh_close_pr($gh, ($proposed ? $proposed->{number} : undef), merged => 0);
	delete_on_r($h, $pr);
	ok($git->branch_exists($pr), 'the local branch is still there');

	due_commit($h, 'qa', params => {instances => 3},
		message => 'Raise it again');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the next cycle succeeds rather than dying on the stale ref');

	refresh($h, 'a', $pr);
	ok(remote_sha($h, $pr), 'the branch was opened again on R');

	my @created = grep {($_->{method} // '') eq 'POST'} gh_calls($gh);
	is(scalar @created, 2, 'and a fresh pull request was opened for it');
};

subtest 'a preview retires nothing' => sub {
	plan tests => 7;

	my $h   = ready(envs => ['qa'], kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('qa');

	due_commit($h, 'qa', params => {instances => 2},
		message => 'Raise the cf instance count');
	run_genesis($h, 'propagate', '-y');

	my $proposed = record_at($h, $h->env_path('qa').'/proposed');
	gh_merge_pr($gh, ($proposed ? $proposed->{number} : undef),
		method => 'rebase');
	squash_merge($h, 'qa', keep_marker => 1);

	# Armed after the first run, so the log below carries the preview's own
	# calls and nothing the run that set the scene made.
	my $git_faulted = fault_git($h);
	my ($out, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');
	is($exit, 0, 'the preview succeeded');

	refresh($h, 'a');
	ok(remote_sha($h, $pr), 'the branch is still on R');
	ok($git->branch_exists($pr), 'and still in the clone');
	ok(record_at($h, $h->env_path('qa').'/proposed'),
		'the proposed record still stands');

	my @pushes = grep {$_->[0] eq 'push'} step_log($git_faulted);
	is(scalar @pushes, 0, 'and the preview pushed nothing at all');
};

subtest 'a preview builds no branch at all' => sub {
	plan tests => 6;

	my $h   = ready(envs => ['qa'], kit => 'omega-v2.7.0');
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('qa');

	due_commit($h, 'qa', params => {instances => 2},
		message => 'Raise the cf instance count');

	my $git_faulted = fault_git($h);
	my ($out, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');
	is($exit, 0, 'the preview succeeded');

	refresh($h, 'a');
	ok(!$git->branch_exists($pr), 'the pull request branch was never cut');
	ok(!remote_sha($h, $pr), 'and nothing of it reached R');
	is(scalar(grep {$_->[0] eq 'push'} step_log($git_faulted)), 0,
		'the preview pushed nothing at all');
	like($err, qr/qa: would propagate/,
		'and it still says what the run would have done');
};

done_testing;
