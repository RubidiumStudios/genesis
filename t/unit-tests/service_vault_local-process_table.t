#!/usr/bin/env perl
# The local vault finds its safe and vault processes without ps.  Container
# images strip procps, ubuntu:jammy's genesiscommunity/concourse among them,
# and there `ps -eo` found nothing, so an entombing deploy in a pipeline task
# bailed "Could not start local memory-backed vault" over a vault that was
# starting normally.  Linux is read through /proc, and ps is left to systems
# with no /proc, macOS, where it is part of the base system.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use File::Temp ();

use Service::Vault::Local;

# A /proc of two processes, the second a child of the first, one with a
# command name carrying the ") " that a naive split of stat would cut at.
sub fake_proc {
	my $root = File::Temp->newdir;
	my %procs = (
		101 => {stat => "101 (safe) S 1 101 101",
		        cmdline => "/usr/bin/safe\0local\0-m\0--as\0local_vault_x_7\0--port\08201\0"},
		102 => {stat => "102 (va) ult) S 101 101 101",
		        cmdline => "/usr/bin/vault\0server\0-dev\0"},
		103 => {stat => "103 (kworker) S 2 0 0", cmdline => ""},
	);
	for my $pid (keys %procs) {
		mkdir "$root/$pid";
		helper::put_file("$root/$pid/stat", $procs{$pid}{stat}."\n");
		helper::put_file("$root/$pid/cmdline", $procs{$pid}{cmdline});
	}
	mkdir "$root/self";
	helper::put_file("$root/self/stat", "1 (x) S 0\n");
	mkdir "$root/not-a-pid";
	return $root;
}

subtest 'a /proc tree reads as the process table' => sub {
	my $root = fake_proc();
	my %table = map {($_->{pid} => $_)} Service::Vault::Local::_process_table(proc => "$root");

	is_deeply([sort keys %table], [101, 102], 'the processes with a command, and nothing else');
	is($table{101}{cmd}, '/usr/bin/safe local -m --as local_vault_x_7 --port 8201',
		'the command line, its arguments joined');
	is($table{102}{ppid}, 101, 'the parent read past a ) in the command name');
};

subtest 'the matchers read the table' => sub {
	my $root = fake_proc();
	local $Service::Vault::Local::PROC_ROOT = "$root";
	my $safe = Service::Vault::Local::_get_safe_process('local_vault_x_7', 0.05);
	is($safe && $safe->{pid}, 101, 'safe is found by its alias');
	my $vault = Service::Vault::Local::_get_vault_process(101, 0.05);
	is($vault && $vault->{pid}, 102, 'and its engine by its parent');
	is(Service::Vault::Local::_get_safe_process('local_vault_y_7', 0.05), undef,
		'another alias is not');
};

subtest 'liveness needs no ps' => sub {
	local $ENV{PATH} = '/nonexistent';
	ok(Service::Vault::Local::_process_running($$), 'this process runs');
	my $gone = fork // die "fork: $!";
	exit 0 unless $gone;
	waitpid($gone, 0);
	ok(!Service::Vault::Local::_process_running($gone), 'a reaped one does not');
};

subtest 'this host reads itself' => sub {
	my ($me) = grep {$_->{pid} == $$} Service::Vault::Local::_process_table();
	ok($me, 'this process is in the table');
	is($me && $me->{ppid}, getppid(), 'with its parent');
};

done_testing;
