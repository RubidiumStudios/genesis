#!/usr/bin/env perl
# What safe prints when a read, a write, or a request fails can quote any
# value in vault, and so can a YAML parser that could not read what safe
# printed.  Each of these failures is described by how safe ended, the
# kind of failure it reported, and the HTTP status, never by the text.
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

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
put_file("$dir/bin/safe", 0755, <<'EOS');
#!/bin/bash
[[ -n $FAKE_OUT ]] && printf '%s\n' "$FAKE_OUT"
[[ -n $FAKE_ERR ]] && printf '%s\n' "$FAKE_ERR" >&2
exit ${FAKE_RC:-0}
EOS
$ENV{PATH} = "$dir/bin:$ENV{PATH}";

my $vault = bless({url => 'https://10.0.0.5', name => 'fake'}, 'Service::Vault');

sub first_line { (grep {/\S/} split /\n/, $_[0] // '')[0] // '' }

for my $case (
	['a refused read', "Error making API request.\nCode: 403. Errors:\n* permission denied: %s", 2,
		qr/safe exited 2 \(permission denied; HTTP status 403\)/],
	['an unreachable vault', "!! dial tcp 10.0.0.5:8200: connect: connection refused %s", 1,
		qr/safe exited 1 \(connection failed\)/],
) {
	my ($name, $stderr, $rc, $want) = @$case;
	subtest "$name is described without what safe said" => sub {
		my $secret = fake_secret('read-failure');
		local $ENV{FAKE_ERR} = sprintf($stderr, $secret);
		local $ENV{FAKE_RC} = $rc;
		my $error;
		my ($log, $err) = capture_trace { eval { $vault->read_flattened_secret('secret/fake') }; $error = $@ };
		like(first_line($error), $want, 'the error gives the exit code and the kind of failure');
		unlike($error.$log.$err, qr/\Q$secret\E/, 'and nothing safe printed');
	};
}

subtest 'output that is not YAML is described without quoting it' => sub {
	my $secret = fake_secret('bad-yaml');
	local $ENV{FAKE_OUT} = "password: [\"$secret\"\n  bad: {";
	my $error;
	my ($log, $err) = capture_trace { eval { $vault->read_flattened_secret('secret/fake') }; $error = $@ };
	like(first_line($error), qr/its output could not be parsed as YAML/, 'the error says the output was not YAML');
	unlike($error.$log.$err, qr/\Q$secret\E/, 'and quotes none of it');
};

subtest 'a lenient read logs no part of what safe said' => sub {
	my $secret = fake_secret('lenient-read');
	local $ENV{FAKE_ERR} = "!! permission denied $secret";
	local $ENV{FAKE_RC} = 2;
	my $got = 'unset';
	my ($log, $err) = capture_trace { $got = $vault->read_flattened_secret('secret/fake', lenient => 1) };
	is($got, undef, 'the read is taken as nothing stored');
	like($log, qr/safe exited 2 \(permission denied\)/, 'and the log says why');
	unlike($log.$err, qr/\Q$secret\E/, 'without anything safe printed');
};

subtest 'a failed clear is described without what safe said' => sub {
	my $secret = fake_secret('clear');
	local $ENV{FAKE_OUT} = "removing $secret";
	local $ENV{FAKE_ERR} = "!! permission denied $secret";
	local $ENV{FAKE_RC} = 2;
	my $error;
	my ($log, $err) = capture_trace { eval { $vault->clear('secret/fake', 1) }; $error = $@ };
	like(first_line($error), qr/Could not clear secret\/fake in vault at https:\/\/10\.0\.0\.5: safe exited 2 \(permission denied\)/,
		'the error gives the exit code and the kind of failure');
	unlike($error.$log.$err, qr/\Q$secret\E/, 'and nothing safe printed');
};

subtest 'a failed default target is described without what safe said' => sub {
	my $secret = fake_secret('target');
	local $ENV{FAKE_ERR} = "!! could not find target $secret";
	local $ENV{FAKE_RC} = 1;
	my $error;
	my ($log, $err) = capture_trace { eval { Service::Vault->set_default($vault) }; $error = $@ };
	like(first_line($error), qr/Could not set default vault to fake: safe exited 1/, 'the error gives the exit code');
	unlike($error.$log.$err, qr/\Q$secret\E/, 'and nothing safe printed');
};

subtest 'a failed KV request gives its HTTP status, not the errors vault sent' => sub {
	my $secret = fake_secret('kv-error');
	local $ENV{FAKE_OUT} = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n".
		qq({"errors":["failed to parse JSON input: invalid value near \\"$secret\\""]});
	my @got = $vault->_kv_curl('POST', 'secret/data/fake', {data => {password => $secret}});
	is($got[0], 400, 'the status is returned');
	like($got[2], qr/^POST \/secret\/data\/fake: HTTP status 400 \(could not parse its input\)$/,
		'the reason names the request, the status, and the kind of failure');
	unlike($got[2], qr/\Q$secret\E/, 'and none of what vault sent');
};

subtest 'a KV request with no answer is described without what safe said' => sub {
	my $secret = fake_secret('kv-unreached');
	local $ENV{FAKE_ERR} = "!! dial tcp: connection refused $secret";
	local $ENV{FAKE_RC} = 1;
	my @got = $vault->_kv_curl('GET', 'secret/data/fake');
	is($got[0], 0, 'no status is returned');
	like($got[2], qr/^safe exited 1 and printed no response \(connection failed\)$/, 'the reason gives the exit code and the kind of failure');
	unlike($got[2], qr/\Q$secret\E/, 'and nothing safe printed');
};

done_testing;
