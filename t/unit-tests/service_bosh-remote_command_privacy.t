#!/usr/bin/env perl
# A command run on an instance, whether with `genesis <env> broadcast --`
# or by run_on_instance and run_on_instances, is the operator's or a kit's,
# and it can carry a credential, such as a password on a client's command
# line.  Each such operand is wrapped whole before the bosh command is
# traced, so the trace gets its size, and bosh still gets it exactly.
use strict;
use warnings;

BEGIN { *CORE::GLOBAL::exit = sub { die sprintf("EXIT %d\n", $_[0] // 0) } }

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Commands;
use Genesis::Commands::Bosh;
use Service::BOSH;
use Service::BOSH::Director;

my $dir = tempdir(CLEANUP => 1);
$ENV{FAKE_BOSH_RECORD} = "$dir/argv";

# The fake bosh records the arguments it gets, each ended by a NUL, and
# answers vms and ssh --json as bosh would.
fake_bosh(<<'SCRIPT');
#!/bin/bash
for a in "$@"; do printf '%s\0' "$a"; done > "$FAKE_BOSH_RECORD"
case "$*" in
	vms*--json*) echo '{"Tables":[{"Rows":[{"instance":"api/0"}]}]}' ;;
	*--json*--results*) echo '{"Tables":[{"Rows":[{"exit_code":"0","stdout":"ok"}]}]}' ;;
esac
exit 0
SCRIPT

sub argv {
	open my $fh, '<', $ENV{FAKE_BOSH_RECORD} or return ();
	local $/;
	my $all = <$fh>;
	return split /\0/, $all;
}

sub director {
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	Service::BOSH::Director->new('remote-test', deployment => 'cf',
		url => 'https://127.0.0.1', ca_cert => 'ca', client => 'admin', secret => 'x', exodus_path => 'secret/exodus');
}

subtest 'run_on_instance keeps the command out of the trace' => sub {
	my $value = fake_secret('remote-command');
	my $command = "mysql -p'$value' -e 'select 1'";
	my $bosh = director();
	my $log = capture_trace { $bosh->run_on_instance($command, target => 'api/0') };
	unlike($log, qr/\Q$value\E/, 'the trace does not hold the command');
	is_deeply([(argv())[0..3]], [qw/ssh api\/0 --command/, $command], 'and bosh gets it exactly');

	$log = capture_trace { $bosh->run_on_instance($command, target => 'api/0', interactive => 1) };
	unlike($log, qr/\Q$value\E/, 'run interactively, the trace does not hold it either');
	is((argv())[3], $command, 'and bosh still gets it exactly');
};

subtest 'run_on_instances keeps the command out of the trace' => sub {
	my $value = fake_secret('remote-commands');
	my $command = "curl -u admin:$value http://localhost";
	my $bosh = director();
	my $log = capture_trace { $bosh->run_on_instances($command) };
	unlike($log, qr/\Q$value\E/, 'run on every instance, the trace does not hold the command');
	is((argv())[2], $command, 'and bosh gets it exactly');

	$log = capture_trace { $bosh->run_on_instances($command, targets => ['api/0']) };
	unlike($log, qr/\Q$value\E/, 'run on named targets, the trace does not hold it');
	is((argv())[3], $command, 'and bosh gets it exactly');
};

subtest 'broadcast keeps every operand after -- out of the trace' => sub {
	my $value = fake_secret('broadcast');
	my @operands = ('sudo', "PGPASSWORD=$value", 'psql', '-c', "alter user x password '$value'");
	no warnings qw/redefine once/;
	local *Genesis::Top::new = sub { bless({}, 'FakeTop') };
	local *FakeTop::load_env = sub { bless({}, 'FakeEnv') };
	local *FakeEnv::with_vault = sub { $_[0] };
	local *FakeEnv::with_bosh = sub { $_[0] };
	my $bosh = director();
	local *FakeEnv::bosh = sub { $bosh };
	local $Genesis::Commands::COMMAND_OPTIONS = {};
	my $log = capture_trace {
		eval { Genesis::Commands::Bosh::broadcast('fake-env', @operands); 1 } or die $@ unless $@ =~ /\AEXIT 0\b/;
	};
	unlike($log, qr/\Q$value\E/, 'the trace holds none of the operands');
	is_deeply([argv()], ['ssh', 'api/0', '--', @operands], 'and bosh gets every operand exactly');
};

done_testing;
