#!/usr/bin/env perl
# Proves T462: a clone that has never tracked the pull request branch, which
# is every pipeline task's, rebuilds the branch R carries, leased against the
# value the run's snapshot read from R, and not against the tracking ref the
# clone lacks.  After a merge the branch is recreated and a new pull request
# opens; while one is open, the branch is rebuilt and that pull request is
# updated in place.
#
# What the rows catch: the lmelt PoC's second delivery to lab, whose push
# was refused as "stale info" because the lease said the branch R still
# carried after the merge must not exist.  Every earlier row ran its second
# propagate in the clone whose own first push had set the tracking ref.
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

# A clone as Concourse's git resource makes one for a task's input: control
# alone, at its tip, with HEAD detached, so no other branch is tracked.
# clone_copy's full clone tracks every branch R has, which is what hid this.
sub task_clone {
	my ($h) = @_;
	my $dir = "$h->{tmp}/task-" . int(rand(1_000_000));
	run({dir => $h->{base}, onfailure => 'Failed to clone control as the git resource does'},
		'git', 'clone', '-q', '--single-branch', '-b', $h->control, "file://$h->{r}", $dir);
	run({dir => $dir}, 'git', 'config', 'user.email', 'task@genesis.example.com');
	run({dir => $dir}, 'git', 'config', 'user.name', 'A pipeline task');
	run({dir => $dir}, 'git', 'checkout', '-q', '--detach', 'HEAD');
	$h->{task} = $dir;
	return 'task';
}

subtest 'a merged branch is recreated from a fresh clone, and a new pull request opens' => sub {
	my $h   = ready(envs => ['qa'], kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $pr  = $h->pr_branch('qa');

	due_commit($h, 'qa', params => {instances => 2}, message => 'Raise the instance count');
	run_genesis($h, 'propagate', '-y');
	my $first = (record_at($h, $h->env_path('qa').'/proposed') || {})->{number};
	gh_merge_pr($gh, $first, method => 'rebase');
	squash_merge($h, 'qa', keep_marker => 1);
	my $merged = remote_sha($h, $pr);
	ok($merged, 'the merged branch stands on R');

	due_commit($h, 'qa', params => {instances => 3}, message => 'Raise it again');
	my $copy = task_clone($h);
	my ($out, $err, $exit) = run_genesis_in($h, $copy, {pipeline_task => 'propagate', restore => 0}, 'propagate');
	is($exit, 0, 'the run from a clone that never tracked the branch succeeds')
		or diag(unfolded($out, $err));
	unlike(unfolded($out, $err), qr/publish rejected/, 'with no push refused');
	isnt(remote_sha($h, $pr), $merged, 'the branch was recreated on R');
	my $second = (record_at($h, $h->env_path('qa').'/proposed') || {})->{number};
	ok($second && $first && $second != $first, 'and a new pull request opened on it');
};

subtest 'an open pull request is updated from a fresh clone' => sub {
	my $h   = ready(envs => ['qa'], kit => 'omega-v2.7.0');
	my $pr  = $h->pr_branch('qa');

	due_commit($h, 'qa', params => {instances => 2}, message => 'Raise the instance count');
	run_genesis($h, 'propagate', '-y');
	my $first = (record_at($h, $h->env_path('qa').'/proposed') || {})->{number};
	my $open  = remote_sha($h, $pr);

	due_commit($h, 'qa', params => {instances => 3}, message => 'Raise it again');
	my $copy = task_clone($h);
	my ($out, $err, $exit) = run_genesis_in($h, $copy, {pipeline_task => 'propagate', restore => 0}, 'propagate');
	is($exit, 0, 'the run from a clone that never tracked the branch succeeds')
		or diag(unfolded($out, $err));
	unlike(unfolded($out, $err), qr/publish rejected/, 'with no push refused');
	isnt(remote_sha($h, $pr), $open, 'the branch was rebuilt on R');
	is((record_at($h, $h->env_path('qa').'/proposed') || {})->{number}, $first,
		'and the open pull request was updated, not replaced');
};

done_testing;
