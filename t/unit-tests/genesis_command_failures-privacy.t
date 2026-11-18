#!/usr/bin/env perl
# A failed command's stdout and stderr can quote whatever credential it
# was handling, so the errors Genesis raises from a failed safe, credhub,
# or bosh call name the exit code and the kinds of failure the streams
# matched, never the streams themselves.  The fake commands below print a
# marker on both streams and fail, and the marker must not reach the
# error, the terminal, or the trace.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Service::Vault;
use Service::Vault::Admin;
use Service::Vault::Admin::AppRole;
use Service::Credhub;
use Genesis::Env::Secrets::Plan;
use Genesis::Secret::UUID;

my $dir = tempdir(CLEANUP => 1);
for my $cmd (qw/safe credhub/) {
	put_file("$dir/$cmd", 0755, <<'SH');
#!/bin/bash
echo "out: $FAKE_VALUE"
echo "err: $FAKE_VALUE: permission denied" >&2
exit 2
SH
}
$ENV{PATH} = "$dir:$ENV{PATH}";
my $marker = fake_secret('failing-command');
$ENV{FAKE_VALUE} = $marker;

sub vault { bless({url => 'https://10.0.0.5', name => 'fake'}, 'Service::Vault') }

sub refused(&) {
	my ($code) = @_;
	my $died;
	my ($log, $stderr, $stdout) = capture_trace { eval { $code->(); 1 } or $died = "$@" };
	# Carp::Always in the test helper adds a backtrace with arguments, which
	# production runs leave out; the message is the first line.
	my ($msg) = grep {/\S/} split /\n/, $died // '';
	return ($msg // '', "$log$stderr$stdout");
}

subtest 'listing vault auth methods' => sub {
	my ($msg, $seen) = refused { Service::Vault::Admin::AppRole->new(Service::Vault::Admin->new(vault))->enabled };
	like($msg, qr/Failed to list auth methods: safe exited 2 \(permission denied\)/, 'names the exit code and kind');
	unlike("$msg$seen", qr/\Q$marker\E/, 'and nothing the command printed');
};

subtest 'listing credhub paths' => sub {
	my $credhub = Service::Credhub->new('fake', '/fake/', 'https://10.0.0.6:8844', 'admin', 'not-under-test-here', 'ca');
	my ($msg, $seen) = refused { $credhub->paths };
	like($msg, qr/Could not list CredHub paths under .*credhub exited 2 \(permission denied\)/, 'names the exit code and kind');
	unlike("$msg$seen", qr/\Q$marker\E/, 'and nothing the command printed');
};

subtest 'a failed secret command' => sub {
	my $msg = Genesis::Env::Secrets::Plan::_command_failure("out: $marker", 2, "err: $marker: forbidden");
	is($msg, 'command exited 2 (permission denied)', 'names the exit code and kind');
	$msg = Genesis::Env::Secrets::Plan::_command_failure("password: $marker", 0, '');
	like($msg, qr/printed \d+ bytes of unexpected output/, 'unexpected output is described by its size');
	unlike($msg, qr/\Q$marker\E/, 'and never quoted');
};

subtest 'a rotated UUID is not reported' => sub {
	my $uuid = 'c0ffee00-0000-4000-8000-00000000beef';
	my $secret = bless({path => 'fake/path:id'}, 'Genesis::Secret::UUID');
	my ($out) = $secret->process_command_output('rotate', "id: $uuid", 0, '');
	unlike($out, qr/\Q$uuid\E/, 'the new value is filtered out');
};

done_testing;
