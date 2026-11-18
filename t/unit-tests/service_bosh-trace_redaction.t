#!/usr/bin/env perl
# Service::BOSH::execute keeps bosh output that can carry secrets out of
# the trace.  `bosh manifest`, `bosh int`, configs, variables, and deploy
# transcripts all print credentials, so stdout and stderr are traced
# verbatim only for an allowlist of read-only listing commands, and every
# other command, including any shell command that chains more onto a
# listing, leaves a byte count.  With BOSH_LOG_LEVEL above its default,
# bosh writes whole director responses, so both streams are redacted, and
# an interactive command shows them on the terminal without capturing a
# transcript.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Service::BOSH;
use Service::BOSH::Director;

my $dir = tempdir(CLEANUP => 1);
my $out_secret = fake_secret('stdout');
my $err_secret = fake_secret('stderr');

# The fake bosh prints the made-up values it is handed through its
# environment, which run() does not trace for keys it was not given.
put_file("$dir/bosh", 0755, <<'SH');
#!/bin/bash
echo "admin_password: $FAKE_STDOUT_VALUE"
echo "debug response: $FAKE_STDERR_VALUE" >&2
exit 0
SH

# A fake script(1) that keeps the typescript out of the TAP stream.
mkdir "$dir/bin";
put_file("$dir/bin/script", 0755, <<'SH');
#!/bin/bash
while [[ "$1" == -* ]]; do shift; done
file="$1"; shift
"$@" > "$file" 2>&1
SH

$ENV{FAKE_STDOUT_VALUE} = $out_secret;
$ENV{FAKE_STDERR_VALUE} = $err_secret;
delete $ENV{BOSH_LOG_LEVEL};

sub director {
	Service::BOSH->set_command("$dir/bosh");
	return Service::BOSH::Director->new('trace-test',
		url => 'https://127.0.0.1:25555', ca_cert => 'ca', client => 'admin',
		secret => 'not-under-test-here',
		exodus_vault => 'none', deployment => 'some-deployment');
}

for my $cmd (
	['manifest'], ['int', 'manifest.yml'], ['config', '--type=cloud', '--name=default'],
	['configs'], ['cloud-config'], ['runtime-config'], ['variables'],
	['bosh manifest'], ['manifest "$@" | cat'], ['-n', 'manifest'],
	['env --json; bosh manifest'], ['env --json | cat'], ['env --json && bosh manifest'],
	['env $(bosh manifest)'],
	# An option's value is not the subcommand: each of these runs
	# `manifest` against a target or deployment named like a listing.
	['--environment', 'deployments', 'manifest'], ['-e', 'vms', 'manifest'],
	['-d', 'env', 'manifest'], ['--deployment', 'tasks', 'manifest'],
	['--client', 'env', 'manifest'], ['--client-secret', 'env', 'manifest'],
	['--ca-cert', 'env', 'manifest'], ['--config', 'env', 'manifest'],
	['--column', 'env', 'manifest'], ['--parallel', '5', 'manifest'],
	# Anything the parser does not know is treated as private.
	['--made-up-flag', 'env'], ['--', 'env'], ['events'],
) {
	my $name = join(' ', @$cmd);
	subtest "stdout of `bosh $name` is redacted" => sub {
		my $log = capture_trace { director->execute(@$cmd) };
		unlike($log, qr/\Q$out_secret\E/, 'the output is absent');
		like($log, qr/\[\d+b of redacted data omitted from debug\]/, 'a byte count is kept');
		unlike($log, qr/\Q$err_secret\E/, 'stderr is absent too');
		like($log, qr/\[\d+b of redacted stderr omitted from debug\]/, 'with its byte count');
	};
}

for my $cmd (
	['env', '--json'], ['-n', 'vms'], ['--json', 'deployments'], ['-e', 'lab', 'env'],
	['--environment=lab', '-d', 'cf', 'instances'], ['-dcf', 'vms'], ['--tty', '--no-color', 'tasks'],
) {
	my $name = join(' ', @$cmd);
	subtest "stdout of the listing `bosh $name` is traced, and its stderr is not" => sub {
		my $log = capture_trace { director->execute(@$cmd) };
		like($log, qr/\Q$out_secret\E/, 'the listing is traced');
		unlike($log, qr/\Q$err_secret\E/, 'its stderr is not');
		like($log, qr/\[\d+b of redacted stderr omitted from debug\]/, 'which leaves its byte count');
	};
}

for my $level (qw/debug info warn error/) {
	subtest "BOSH_LOG_LEVEL=$level redacts stdout and stderr" => sub {
		local $ENV{BOSH_LOG_LEVEL} = $level;
		my $log = capture_trace { director->execute('env', '--json') };
		unlike($log, qr/\Q$out_secret\E/, 'stdout is absent even for an allowlisted command');
		unlike($log, qr/\Q$err_secret\E/, 'stderr is absent');
		like($log, qr/\[\d+b of redacted stderr omitted from debug\]/, 'a byte count is kept');
	};
}

subtest 'BOSH_LOG_LEVEL=none is the default' => sub {
	local $ENV{BOSH_LOG_LEVEL} = 'none';
	my $log = capture_trace { director->execute('env', '--json') };
	like($log, qr/\Q$out_secret\E/, 'a listing is traced');
};

subtest 'an interactive transcript is redacted' => sub {
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $^O = 'darwin';
	my ($log, @results);
	$log = capture_trace { @results = director->execute({interactive => 1}, 'deploy', 'manifest.yml') };
	like($results[0], qr/\Q$out_secret\E/, 'the caller still gets the transcript');
	unlike($log, qr/\Q$out_secret\E/, 'the transcript is absent from the trace');
	like($log, qr/\d+b of redacted bosh output omitted from debug/, 'a byte count is kept');
};

subtest 'verbose bosh logging is shown live and never captured' => sub {
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{BOSH_LOG_LEVEL} = 'debug';
	local $^O = 'darwin';
	# bosh writes to the real terminal, which capture_trace captures at
	# file descriptors 1 and 2.
	my ($log, $stderr, $stdout, @results);
	($log, $stderr, $stdout) = capture_trace { @results = director->execute({interactive => 1}, 'deploy', 'manifest.yml') };
	like($stdout.$stderr, qr/\Q$out_secret\E/, 'the operator still sees what bosh prints');
	like($stderr, qr/BOSH_LOG_LEVEL/, 'with a warning that verbose logging is on');
	unlike($results[0] // '', qr/\Q$out_secret\E|\Q$err_secret\E/, 'no transcript holding it is returned');
	unlike($log, qr/\Q$out_secret\E|\Q$err_secret\E/, 'and the trace holds neither stream');
};

done_testing;
