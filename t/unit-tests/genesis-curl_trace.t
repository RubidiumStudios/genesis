#!perl
# Genesis::curl hands curl the credential and the request body, and keeps both
# out of the trace.  The trace was written for debugging before tokens and
# webhook URLs went through it, and nothing looked at what it recorded, so a
# GitHub token reached a world-readable trace log on every call that sent one.
use strict;
use warnings;
use lib 't';
use helper;
use File::Temp qw/tempfile tempdir/;
use Test::More;

use Genesis;
use Genesis::Log;

my $SECRET_TOKEN = 'ghp_harnesstokenvalue0123456789';
my $SECRET_PASS  = 'harness-password-value';
my $SECRET_BODY  = 'webhook_token=harness-body-secret';

# A curl that records what it was handed and answers as GitHub would.
my $bin = tempdir(CLEANUP => 1);
my $handed = "$bin/handed";
helper::put_file("$bin/curl", 0755, join("\n",
	'#!/bin/sh',
	"printf '%s\\n' \"\$@\" > '$handed'",
	"printf 'HTTP/1.1 200 OK\\r\\n\\r\\n' >&2",
	'echo "{}"', ''));
local $ENV{PATH} = "$bin:$ENV{PATH}";

sub traced {
	my (@args) = @_;
	$Genesis::Log::Logger = undef;
	my $logger = Genesis::Log->new();
	my (undef, $file) = tempfile(UNLINK => 1, SUFFIX => '.log');
	$logger->configure_log($file, level => 'TRACE');
	$Genesis::Log::Logger = $logger;
	my ($code) = Genesis::curl(@args);
	return ($code, Genesis::slurp($file), Genesis::slurp($handed));
}

subtest 'a bearer token and a body are handed to curl and kept out of the trace' => sub {
	my ($code, $trace, $sent) = traced('POST', 'https://api.example.test/repos/o/r/hooks', {},
		qq({"config":{"url":"https://ci.example.test/check?$SECRET_BODY"}}), 0, "Bearer $SECRET_TOKEN");
	is($code, 200, 'the call is answered');
	like($sent, qr/\Q$SECRET_TOKEN\E/, 'curl is handed the token');
	like($sent, qr/\Q$SECRET_BODY\E/, 'and the body');
	ok(length $trace, 'the call is traced');
	unlike($trace, qr/\Q$SECRET_TOKEN\E/, 'but the trace carries no token');
	unlike($trace, qr/\Q$SECRET_BODY\E/, 'and no body');
};

subtest 'GENESIS_TRACE_SECRETS traces them on purpose, and says so' => sub {
	local $ENV{GENESIS_TRACE_SECRETS} = 1;
	my ($code, $trace) = traced('POST', 'https://api.example.test/repos/o/r/hooks', {},
		qq({"config":{"url":"https://ci.example.test/check?$SECRET_BODY"}}), 0, "Bearer $SECRET_TOKEN");
	like($trace, qr/\Q$SECRET_TOKEN\E/, 'the token is traced');
	like($trace, qr/\Q$SECRET_BODY\E/, 'and the body');
	like($trace, qr/GENESIS_TRACE_SECRETS.*secrets/is, 'with a warning that secrets are being traced');
};

subtest 'user and password credentials are kept out of the trace' => sub {
	my ($code, $trace, $sent) = traced('GET', 'https://api.example.test/user', {},
		undef, 0, "someone:$SECRET_PASS");
	like($sent, qr/\Q$SECRET_PASS\E/, 'curl is handed the password');
	unlike($trace, qr/\Q$SECRET_PASS\E/, 'and the trace carries none of it');
};

done_testing;
