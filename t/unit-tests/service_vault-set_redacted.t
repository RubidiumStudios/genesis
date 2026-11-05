#!/usr/bin/env perl
# Service::Vault::set always redacts: the values it writes reach safe and
# never the trace, whose run line recorded every key=value it was handed and
# whose output recorded safe's echo of each, and never a failure's message.
use strict;
use warnings;
use lib 't';
use lib 'lib';
use helper;
use File::Temp qw/tempfile tempdir/;
use Test::More;

use Genesis;
use Genesis::Log;
use_ok 'Service::Vault';

my $SECRET = 'harness-written-secret-value';

# A safe that echoes what it set, as the real one does, and fails on demand.
my $bin    = tempdir(CLEANUP => 1);
my $handed = "$bin/handed";
helper::put_file("$bin/safe", 0755, join("\n",
	'#!/bin/sh',
	"printf '%s\\n' \"\$@\" > '$handed'",
	'shift; shift',
	'for pair in "$@"; do echo "${pair%%=*}: ${pair#*=}"; done',
	'[ -n "$HARNESS_SAFE_FAILS" ] && { echo "!! could not write" >&2; exit 1; }',
	'exit 0', ''));
local $ENV{PATH} = "$bin:$ENV{PATH}";
local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = 0;

sub traced_set {
	my (%env) = @_;
	local @ENV{keys %env} = values %env;
	$Genesis::Log::Logger = undef;
	my $logger = Genesis::Log->new();
	my (undef, $file) = tempfile(UNLINK => 1, SUFFIX => '.log');
	$logger->configure_log($file, level => 'TRACE');
	$Genesis::Log::Logger = $logger;
	my $vault = Service::Vault->new('https://vault.example.test', 'harness', 0, '', undef, '/secret/');
	my $ok = eval {$vault->set('secret/ci/webhook', token => $SECRET); 1};
	return ($ok, $@, Genesis::slurp($file), Genesis::slurp($handed));
}

subtest 'a written value reaches safe and not the trace' => sub {
	my ($ok, $died, $trace, $sent) = traced_set();
	ok($ok, 'the write succeeds') or diag($died);
	like($sent, qr/token=\Q$SECRET\E/, 'safe is handed the value');
	ok(length $trace, 'the write is traced');
	unlike($trace, qr/\Q$SECRET\E/, 'and the trace carries none of it');
};

subtest 'a failed write names no value' => sub {
	my ($ok, $died, $trace) = traced_set(HARNESS_SAFE_FAILS => 1);
	ok(!$ok, 'the write fails');
	like($died, qr/Could not write/, 'saying so');
	# The message, without the stack frames a full stack dump appends, whose
	# arguments are a separate matter from what set itself says.
	my $message = join("\n", grep {!/^\s+\S+::\S+\(.*\) called at /} split /\n/, $died);
	unlike($message, qr/\Q$SECRET\E/, 'without the value in the message');
	unlike($trace, qr/\Q$SECRET\E/, 'or in the trace');
};

done_testing;
