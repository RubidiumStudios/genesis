#!/usr/bin/env perl
use strict;
use warnings;

# The network claims lock around the deploy path's cloud config check: a dry
# run reads the claims without taking the lock, a real deploy takes it, a
# stale lock is cleared only with --yes or a confirmed answer at a terminal,
# and the release helper clears only a lock this process holds.

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Output;

use Genesis;
use_ok 'Genesis::Commands::Env';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

my @calls;   # what the helpers asked the director to do
my $status;  # what check_network_lock reports
my $held;    # whether this process holds the lock

sub make_env {
	@calls = ();
	$held = 0;
	my $director = mock "Mock::NetworkLock::Director" => {
		alias => 'parent',
		check_network_lock => sub {
			push @calls, 'check';
			return {status => $status, description => 'about 11 minutes ago by ubuntu@bastion (env: ocf, pid: 229665)'};
		},
		acquire_network_lock => sub { push @calls, 'acquire'; $held = 1; 1 },
		clear_network_lock   => sub { push @calls, 'clear';   $held = 0; 1 },
		network_locked_by_me => sub { push @calls, 'mine';    $held },
	};
	return mock "Mock::NetworkLock::Env" => {
		name   => 'test-env',
		bosh   => $director,
		notify => sub { 1 },
	};
}

sub lock_for {
	my ($env, %opts) = @_;
	my ($result, $out, $err);
	($out, $err) = output_from { $result = Genesis::Commands::Env::_deploy_network_claims_lock($env, %opts) };
	return ($result, $out.$err);
}

subtest 'dry run with the lock available takes no lock' => sub {
	plan tests => 3;
	$status = 'unlocked';
	my ($result, $text) = lock_for(make_env(), dryrun => 1, yes => 0);
	is($result, 0, 'reports that no lock is held');
	is_deeply(\@calls, ['check'], 'the director is only asked about the lock');
	like($text, qr/without taking the lock/, 'says the dry run reads without the lock');
};

subtest 'dry run with a stale lock leaves it in place' => sub {
	plan tests => 4;
	$status = 'stale';
	my ($result, $text) = lock_for(make_env(), dryrun => 1, yes => 0);
	is($result, 0, 'reports that no lock is held');
	is_deeply(\@calls, ['check'], 'the stale lock is neither cleared nor replaced');
	like($text, qr/locked \(stale\)/, 'the stale lock is reported');
	unlike($text, qr/\[y\|n\]/, 'nothing is asked');
};

subtest 'dry run with a live lock stops, like a real deploy' => sub {
	plan tests => 2;
	$status = 'locked';
	throws_ok { lock_for(make_env(), dryrun => 1, yes => 1) } qr/currently locked/, 'a live lock stops the dry run';
	is_deeply(\@calls, ['check'], 'nothing else is done to the lock');
};

subtest 'real deploy with the lock available takes it' => sub {
	plan tests => 2;
	$status = 'unlocked';
	my ($result) = lock_for(make_env(), dryrun => 0, yes => 0);
	is($result, 1, 'reports that the lock is held');
	is_deeply(\@calls, ['check', 'acquire'], 'the lock is acquired');
};

subtest 'real deploy with --yes clears a stale lock without asking' => sub {
	plan tests => 3;
	$status = 'stale';
	my ($result, $text) = lock_for(make_env(), dryrun => 0, yes => 1);
	is($result, 1, 'reports that the lock is held');
	is_deeply(\@calls, ['check', 'clear', 'acquire'], 'the stale lock is cleared, then the lock is acquired');
	unlike($text, qr/\[y\|n\]/, 'nothing is asked');
};

subtest 'real deploy without --yes and without a terminal fails fast' => sub {
	plan tests => 2;
	no warnings 'redefine';
	local *Genesis::Commands::Env::in_controlling_terminal = sub { 0 };
	$status = 'stale';
	throws_ok { lock_for(make_env(), dryrun => 0, yes => 0) } qr/Rerun with --yes/, 'explains how to clear the stale lock';
	is_deeply(\@calls, ['check'], 'the stale lock is left alone');
};

subtest 'real deploy at a terminal asks before clearing a stale lock' => sub {
	plan tests => 4;
	no warnings 'redefine';
	local *Genesis::Commands::Env::in_controlling_terminal = sub { 1 };
	$status = 'stale';

	set_stdin("y\n");
	my ($result, $text) = lock_for(make_env(), dryrun => 0, yes => 0);
	reset_stdin();
	is($result, 1, 'reports that the lock is held after a yes');
	is_deeply(\@calls, ['check', 'clear', 'acquire'], 'a yes clears the stale lock and acquires');

	set_stdin("n\n");
	throws_ok { lock_for(make_env(), dryrun => 0, yes => 0) } qr/Aborted by user/, 'a no aborts';
	reset_stdin();
	is_deeply(\@calls, ['check'], 'a no leaves the stale lock alone');
};

subtest 'release clears only a lock this process holds' => sub {
	plan tests => 4;
	$status = 'unlocked';
	my $env = make_env();
	$held = 1;
	my $result;
	output_from { $result = Genesis::Commands::Env::_deploy_release_network_claims_lock($env) };
	is($result, 1, 'a held lock is released');
	is_deeply(\@calls, ['mine', 'clear'], 'the lock is cleared after confirming it is ours');

	$env = make_env();
	output_from { $result = Genesis::Commands::Env::_deploy_release_network_claims_lock($env) };
	is($result, 0, 'nothing is released when the lock is not ours');
	is_deeply(\@calls, ['mine'], 'the director is only asked whose lock it is');
};

done_testing;
