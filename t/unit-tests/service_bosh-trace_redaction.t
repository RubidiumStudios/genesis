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

subtest 'stdout of an allowlisted listing command is still traced' => sub {
	my $log = capture_trace { director->execute('env', '--json') };
	like($log, qr/\Q$out_secret\E/, 'the output of bosh env is traced');
	like($log, qr/\Q$err_secret\E/, 'and so is its stderr');
};

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
	like($log, qr/\Q$err_secret\E/, 'stderr is traced');
};

subtest 'a caller can still ask for output to be traced' => sub {
	my $log = capture_trace { director->execute({redact_output => 0}, 'manifest') };
	like($log, qr/\Q$out_secret\E/, 'an explicit redact_output => 0 is honoured');
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
	# bosh writes to the real terminal, so fd 1 and 2 go to a file here.
	open(my $saved_out, '>&', \*STDOUT) or die "cannot save stdout: $!";
	open(my $saved_err, '>&', \*STDERR) or die "cannot save stderr: $!";
	open(STDOUT, '>', "$dir/terminal") or die "cannot redirect stdout: $!";
	open(STDERR, '>>', "$dir/terminal") or die "cannot redirect stderr: $!";
	my ($log, $warned, @results);
	($log, $warned) = capture_trace { @results = director->execute({interactive => 1}, 'deploy', 'manifest.yml') };
	open(STDOUT, '>&', $saved_out);
	open(STDERR, '>&', $saved_err);
	my $terminal = Genesis::slurp("$dir/terminal");
	like($terminal, qr/\Q$out_secret\E/, 'the operator still sees what bosh prints');
	like($warned, qr/BOSH_LOG_LEVEL/, 'with a warning that verbose logging is on');
	unlike($results[0] // '', qr/\Q$out_secret\E|\Q$err_secret\E/, 'no transcript holding it is returned');
	unlike($log, qr/\Q$out_secret\E|\Q$err_secret\E/, 'and the trace holds neither stream');
};

done_testing;
