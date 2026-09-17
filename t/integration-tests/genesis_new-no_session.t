#!/usr/bin/env perl
# Proves T202 and T207: genesis new opens no session, so it takes no switch
# lock and a second process holding one does not block it, and it records
# no tracking field, so nothing restores a branch when the process exits.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

my $h = make_harness(envs => ['qa'], type => 'bosh', kit => 'omega-v2.7.0');
init_branch($h, 'qa');
refresh($h, 'a');
my $git = $h->git('a');

# Every run here commits, so each passes restore => 0 and the runner's own
# restoration assertion is left off.  What the rows read instead is where
# the working tree stands after the process has exited, which is the thing
# they are about.
subtest 'a held switch lock does not block genesis new' => sub {
	# Catches a genesis new that opens a session: it would wait on a lock
	# it has no reason to take, and any deploy in progress would block it.
	my $pid = hold_session_lock($h, command => 'genesis qa deploy');

	$git->create_branch('add-prod', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'add-prod');

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'new', 'prod');

	is($exit, 0, 'the run proceeded while the lock was held');
	unlike($err, qr/lock|held by/i,
		'and said nothing about a lock it never took');
	is($git->current_branch, 'add-prod',
		'the operator is on the branch they chose');

	release_session_lock($h, $pid);
};

subtest 'nothing restores a branch when the process exits' => sub {
	# Catches a restore put back on the git handle: it would take the
	# operator off the branch they chose and off the commit just made.
	$git->create_branch('add-prod2', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'add-prod2');

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'new', 'prod2');
	is($exit, 0, 'the run succeeded');

	# The process has exited by the time run_genesis returns, so what the
	# working tree stands on now is what it was left on.
	is($git->current_branch, 'add-prod2',
		'the operator was left where they stood');
	my ($subject) = $git->log_subjects('add-prod2', limit => 1);
	like($subject, qr/prod2/,
		'and the commit is on that branch');
};

subtest 'the lock file is never created by genesis new' => sub {
	# Catches a genesis new that takes the switch lock without opening a
	# session, which would leave a file behind for the next command to
	# wait on.  The holder above wrote the file itself, so it goes first.
	my $lock = $h->a . '/.git/genesis-session.lock';
	unlink $lock if -e $lock;

	$git->create_branch('add-prod3', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'add-prod3');
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'new', 'prod3');

	is($exit, 0, 'the run succeeded');
	ok(!-e $lock, 'genesis new created no switch lock');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
