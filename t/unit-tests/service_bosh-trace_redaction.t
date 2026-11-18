#!/usr/bin/env perl
# Service::BOSH::execute keeps bosh output that can carry secrets out of
# the trace.  `bosh manifest`, `bosh int`, configs, variables, and deploy
# transcripts all print credentials, so stdout and stderr are traced
# verbatim only for an allowlist of read-only listing commands, and every
# other command, including any shell command that chains more onto a
# listing, leaves a byte count.  bosh's own debug logging writes whole
# director responses, so it is turned off for every command Genesis runs,
# and an interactive command's typescript lives in a private directory
# only until Genesis has read it.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;
use File::Basename qw/dirname/;

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

# A fake script(1) that keeps the typescript out of the TAP stream, and
# records where the typescript went and who could read it.
mkdir "$dir/bin";
put_file("$dir/bin/script", 0755, <<'SH');
#!/bin/bash
while [[ "$1" == -* ]]; do shift; done
file="$1"; shift
echo "$file" > "$FAKE_SCRIPT_RECORD"
stat -f '%Lp' "$file" "$(dirname "$file")" >> "$FAKE_SCRIPT_RECORD" 2>/dev/null ||
	stat -c '%a' "$file" "$(dirname "$file")" >> "$FAKE_SCRIPT_RECORD"
"$@" > "$file" 2>&1
SH
$ENV{FAKE_SCRIPT_RECORD} = "$dir/script-record";

# A fake bosh that reports the logging settings it was run with.
put_file("$dir/bosh-logging", 0755, <<'SH');
#!/bin/bash
echo "level=${BOSH_LOG_LEVEL-unset} path=${BOSH_LOG_PATH-unset}"
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
	subtest "BOSH_LOG_LEVEL=$level is turned off for the bosh Genesis runs" => sub {
		local $ENV{BOSH_LOG_LEVEL} = $level;
		local $ENV{BOSH_LOG_PATH} = "$dir/bosh-debug.log";
		local $Service::BOSH::WARNED_LOGGING = 0;
		my $d = director;
		Service::BOSH->set_command("$dir/bosh-logging");
		my ($out, $stderr);
		(undef, $stderr) = capture_trace { ($out) = $d->execute('env') };
		like($out, qr/^level=none path=unset$/m, 'bosh runs with its logging off and no log path');
		like($stderr, qr/BOSH_LOG_LEVEL.*BOSH_LOG_PATH|BOSH_LOG_PATH.*BOSH_LOG_LEVEL/s, 'and the operator is told why');
		(undef, $stderr) = capture_trace { $d->execute('env') };
		unlike($stderr, qr/BOSH_LOG_LEVEL/, 'once');
		ok(!-e "$dir/bosh-debug.log", 'no bosh debug log is written');
	};
}

subtest 'BOSH_LOG_LEVEL=none needs no warning' => sub {
	local $ENV{BOSH_LOG_LEVEL} = 'none';
	local $Service::BOSH::WARNED_LOGGING = 0;
	my ($log, $stderr) = capture_trace { director->execute('env', '--json') };
	like($log, qr/\Q$out_secret\E/, 'a listing is traced');
	unlike($stderr, qr/BOSH_LOG_LEVEL/, 'and nothing is said about logging');
};

sub script_record {
	my @lines = split /\n/, (-f $ENV{FAKE_SCRIPT_RECORD} ? slurp($ENV{FAKE_SCRIPT_RECORD}) : '');
	unlink $ENV{FAKE_SCRIPT_RECORD};
	return @lines;
}

subtest 'an interactive transcript is private and short-lived' => sub {
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $^O = 'darwin';
	my ($log, @results);
	$log = capture_trace { @results = director->execute({interactive => 1}, 'deploy', 'manifest.yml') };
	like($results[0], qr/\Q$out_secret\E/, 'the caller still gets the transcript');
	unlike($log, qr/\Q$out_secret\E/, 'the transcript is absent from the trace');
	like($log, qr/\d+b of redacted bosh output omitted from debug/, 'a byte count is kept');
	my ($file, $file_mode, $dir_mode) = script_record();
	is($file_mode, '600', 'the typescript is readable by its owner alone');
	is($dir_mode, '700', 'in a directory only its owner can enter');
	ok(defined($file) && !-e $file, 'and it is gone once read');
	ok(defined($file) && !-e dirname($file), 'along with its directory');
};

subtest 'verbose bosh logging is off for an interactive run, whatever stdout is' => sub {
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{BOSH_LOG_LEVEL} = 'debug';
	local $Service::BOSH::WARNED_LOGGING = 0;
	local $^O = 'darwin';
	# capture_trace points file descriptors 1 and 2 at files, as a CI log
	# would.
	my $d = director;
	Service::BOSH->set_command("$dir/bosh-logging");
	my ($log, $stderr, $stdout, @results);
	($log, $stderr, $stdout) = capture_trace { @results = $d->execute({interactive => 1}, 'deploy', 'manifest.yml') };
	like($results[0], qr/level=none path=unset/, 'bosh ran with its logging off, under script');
	like($stderr, qr/BOSH_LOG_LEVEL/, 'with a warning that it was turned off');
	unlike($log, qr/level=/, 'and the transcript is not traced');
	my ($file) = script_record();
	ok(defined($file) && !-e $file, 'the typescript is gone');
};

done_testing;
