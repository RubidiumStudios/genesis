#!/usr/bin/env perl
# Service::BOSH::execute keeps bosh output that can carry secrets out of
# the trace.  `bosh manifest`, `bosh int`, configs, variables, and deploy
# transcripts all print credentials, and even a listing holds text the
# director controls, so no stdout or stderr is traced verbatim.  Each
# leaves a byte count, and a read-only listing adds what its parsed
# output measures, but any shell command that chains more onto a listing
# is not a listing.  bosh's own debug logging writes whole
# director responses, so it is turned off for every command Genesis runs.
# An interactive command's transcript is read from script(1)'s stdout, in
# memory, and never written to disk or traced.  Off a terminal, as in a CI
# log, Genesis shows only the tasks bosh starts, how each ends, and when
# bosh asks whether to continue.
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

# A fake macOS script(1) that copies the command's output to its stdout,
# as script(1) does, and records the typescript it was given.
mkdir "$dir/bin";
put_file("$dir/bin/script", 0755, <<'SH');
#!/bin/bash
while [[ "$1" == -* ]]; do shift; done
echo "$1" > "$FAKE_SCRIPT_RECORD"
shift
"$@" 2>&1
SH
$ENV{FAKE_SCRIPT_RECORD} = "$dir/script-record";

# A fake bosh deploy that starts a task, quotes made-up values on both of
# its streams, and asks whether to continue.
put_file("$dir/bosh-deploy", 0755, <<'SH');
#!/bin/bash
echo "+     password: $FAKE_STDOUT_VALUE"
echo "Error: $FAKE_STDERR_VALUE" >&2
printf 'Continue? [yN]: '
read -r answer
echo
echo "Task 1234"
echo "Task 1234 | 12:00:00 | Updating instance web/0"
echo "Task 1235"
echo "Task 1234 done"
exit "${FAKE_BOSH_RC:-0}"
SH

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
	subtest "the listing `bosh $name` is traced by what it measures" => sub {
		my $out;
		my $log = capture_trace { ($out) = director->execute(@$cmd) };
		like($out, qr/\Q$out_secret\E/, 'the caller gets the listing');
		unlike($log, qr/\Q$out_secret\E/, 'the trace does not');
		like($log, qr/\[\d+b of redacted data omitted from debug\]/, 'it gets a byte count');
		like($log, qr/bosh \S+ listed 1 line/, 'and how many lines were listed');
		unlike($log, qr/\Q$err_secret\E/, 'its stderr is not traced either');
		like($log, qr/\[\d+b of redacted stderr omitted from debug\]/, 'which leaves its byte count');
	};
}

subtest 'a JSON listing is traced as its tables and row counts' => sub {
	# A failed task's result is text the director controls, and can quote
	# what the task was handed.
	put_file("$dir/bosh-tasks", 0755, <<'SH');
#!/bin/bash
cat <<JSON
{"Tables":[{"Content":"tasks","Header":{"id":"ID","result":"Result"},"Rows":[
 {"id":"12","state":"error","result":"failed: password $FAKE_STDOUT_VALUE rejected"},
 {"id":"13","state":"done","result":"ok"}]},
 {"Content":"$FAKE_STDOUT_VALUE","Rows":[]}],"Blocks":null,"Lines":["Succeeded"]}
JSON
SH
	my $d = director;
	Service::BOSH->set_command("$dir/bosh-tasks");
	my $out;
	my $log = capture_trace { ($out) = $d->execute('tasks', '--recent', '--json') };
	like($out, qr/\Q$out_secret\E/, 'the caller gets the listing');
	unlike($log, qr/\Q$out_secret\E/, 'the trace gets no value from it');
	like($log, qr/bosh tasks listed tasks with 2 rows, a table with 0 rows/,
		'only the tables bosh names, and their row counts');
};

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
	like($log, qr/bosh env listed/, 'a listing is traced by what it measures');
	unlike($stderr, qr/BOSH_LOG_LEVEL/, 'and nothing is said about logging');
};

sub script_record {
	my @lines = split /\n/, (-f $ENV{FAKE_SCRIPT_RECORD} ? slurp($ENV{FAKE_SCRIPT_RECORD}) : '');
	unlink $ENV{FAKE_SCRIPT_RECORD};
	return @lines;
}

subtest 'an interactive transcript stays in memory and out of the trace' => sub {
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $^O = 'darwin';
	my ($log, $stderr, $stdout, @results);
	($log, $stderr, $stdout) = capture_trace { @results = director->execute({interactive => 1}, 'deploy', 'manifest.yml') };
	like($results[0], qr/\Q$out_secret\E/, 'the caller still gets the transcript');
	like($results[0], qr/\Q$err_secret\E/, 'with what bosh wrote to stderr');
	unlike($log, qr/\Q$out_secret\E|\Q$err_secret\E/, 'neither is in the trace');
	unlike($stdout.$stderr, qr/\Q$out_secret\E|\Q$err_secret\E/, 'nor shown off a terminal');
	my ($file) = script_record();
	is($file, '/dev/null', 'and script(1) writes no typescript');
};

subtest 'an interactive listing is private too' => sub {
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $^O = 'darwin';
	my ($log, @results);
	$log = capture_trace { @results = director->execute({interactive => 1}, 'vms') };
	like($results[0], qr/\Q$out_secret\E/, 'the caller gets the listing');
	unlike($log, qr/\Q$out_secret\E/, 'but the trace does not');
};

subtest 'off a terminal, bosh progress is shown as tasks and a prompt' => sub {
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $^O = 'darwin';
	my $d = director;
	Service::BOSH->set_command("$dir/bosh-deploy");
	my ($log, $stderr, $stdout, @results);
	($log, $stderr, $stdout) = capture_trace {
		Genesis::set_stdin(\"y\n");
		@results = $d->execute({interactive => 1}, 'deploy', 'manifest.yml');
		Genesis::reset_stdin();
	};
	my $shown = $stdout.$stderr;
	like($shown, qr/bosh is asking whether to continue/, 'the prompt is announced');
	like($shown, qr/bosh started task 1234/, 'each task is announced as it starts');
	like($shown, qr/bosh started task 1235/, 'every one of them');
	like($shown, qr/bosh task 1234 ended: done/, 'and as it ends');
	unlike($shown, qr/\Q$out_secret\E|\Q$err_secret\E|Updating instance/, 'and nothing else bosh printed is shown');
	like($log, qr/bosh tasks: 1234 done, 1235 with no final state; exit code 0/, 'the trace keeps the task states');
	is_deeply($d->last_interactive_status, {
		rc => 0, signal => undef, interrupted => 0,
		tasks => [{id => 1234, state => 'done'}, {id => 1235}],
	}, 'and so does the status the caller reads');
	script_record();
};

subtest 'an exit code that means a signal marks the run interrupted' => sub {
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	my $d = director;
	Service::BOSH->set_command("$dir/bosh-deploy");
	for my $case ([linux => 130, 1], [darwin => 2, 1], [darwin => 1, 0], [linux => 1, 0]) {
		my ($os, $rc, $interrupted) = @$case;
		local $^O = $os;
		local $ENV{FAKE_BOSH_RC} = $rc;
		# The fake script runs the command directly whatever the platform.
		no warnings 'redefine';
		local *Genesis::pty_command = sub { ('script', '-q', '/dev/null', @_) };
		use warnings 'redefine';
		capture_trace {
			Genesis::set_stdin(\"n\n");
			$d->execute({interactive => 1}, 'deploy', 'manifest.yml');
			Genesis::reset_stdin();
		};
		is($d->last_interactive_status->{interrupted}, $interrupted,
			"exit code $rc on $os is ".($interrupted ? '' : 'not ').'an interrupt');
		script_record();
	}
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
	is($file, '/dev/null', 'and no typescript is written');
};

done_testing;
