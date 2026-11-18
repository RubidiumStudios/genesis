#!/usr/bin/env perl
# A child's stdout and stderr can carry any credential the command read,
# so run() keeps both out of the trace and out of an onfailure message
# unless the caller marks that call's output as public.  The caller still
# receives both streams unchanged.  `redact` hides everything about a
# command, so it wins over a public mark.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;

use Genesis;

my ($out_secret, $err_secret) = map {fake_secret($_)} qw/run-stdout run-stderr/;
# The values reach the command through its environment, which the trace
# never shows, so a marker in the trace can only have come from a stream.
my $speak = 'printf "%s\n" "$FAKE_OUT"; printf "%s\n" "$FAKE_ERR" >&2';
my %speaking = (FAKE_OUT => $out_secret, FAKE_ERR => $err_secret);
sub speaking { my %extra = @_; return (env => {%speaking, %extra}) }

sub first_line { (grep {/\S/} split /\n/, $_[0] // "")[0] // "" }

subtest 'a captured command keeps both streams out of the trace' => sub {
	my ($out, $rc, $err);
	my ($log, $stderr) = capture_trace { ($out, $rc, $err) = run({stderr => 0, speaking}, $speak) };
	is($out, $out_secret, 'the caller gets the output');
	is($err, "$err_secret\n", 'and the stderr');
	unlike("$log$stderr", qr/\Q$out_secret\E/, 'the output is absent from the trace');
	unlike("$log$stderr", qr/\Q$err_secret\E/, 'the stderr is absent from the trace');
	like($log, qr/\[\d+b of redacted data omitted from debug\]/, 'the output is traced as its length');
	like($log, qr/\[\d+b of redacted stderr omitted from debug\]/, 'and so is the stderr');
};

subtest 'merged streams stay out of the trace' => sub {
	my ($log, $stderr) = capture_trace { run({speaking}, $speak) };
	unlike("$log$stderr", qr/\Q$out_secret\E|\Q$err_secret\E/, 'neither stream is traced');
};

subtest 'an old opt-out no longer makes a stream public' => sub {
	my ($log, $stderr) = capture_trace {
		run({stderr => 0, redact_output => 0, redact_stderr => 0, speaking}, $speak)
	};
	unlike("$log$stderr", qr/\Q$out_secret\E|\Q$err_secret\E/, 'neither stream is traced');
};

subtest 'a caller can mark output public' => sub {
	my ($log) = capture_trace { run({stderr => 0, public_output => 1, speaking}, $speak) };
	like($log, qr/\Q$out_secret\E/, 'the public output is traced');
	unlike($log, qr/\Q$err_secret\E/, 'the stderr stays private');

	($log) = capture_trace { run({stderr => 0, public_stderr => 1, speaking}, $speak) };
	like($log, qr/\Q$err_secret\E/, 'public stderr is traced');
	unlike($log, qr/\Q$out_secret\E/, 'the output stays private');

	($log) = capture_trace { run({stderr => 0, public => 1, speaking}, $speak) };
	like($log, qr/\Q$out_secret\E/, 'public marks the output');
	like($log, qr/\Q$err_secret\E/, 'and the stderr');
};

subtest 'redact wins over a public mark' => sub {
	my ($log, $stderr) = capture_trace { run({stderr => 0, redact => 1, public => 1, speaking}, $speak) };
	unlike("$log$stderr", qr/\Q$out_secret\E|\Q$err_secret\E/, 'nothing is traced');
};

subtest 'an onfailure message is built from metadata' => sub {
	my $fail = "$speak; exit 3";
	my ($died, $log, $stderr);
	($log, $stderr) = capture_trace {
		eval { run({stderr => 0, onfailure => 'Could not do the fake thing', speaking(FAKE_ERR => "$err_secret: permission denied")}, $fail); 1 }
			or $died = "$@";
	};
	ok(defined($died), 'the failure bails');
	$died = join("\n", grep {!/^\s+\S+::\S+\(|^\s+eval \{/} split /\n/, $died // '');
	like(first_line($died), qr/Could not do the fake thing/, 'with the caller\'s message');
	like($died, qr/exited 3/, 'it gives the exit code');
	like($died, qr/permission denied/, 'and the kind of failure');
	unlike($died, qr/\Q$out_secret\E|\Q$err_secret\E/, 'but no stream text');
	unlike("$log$stderr", qr/\Q$out_secret\E|\Q$err_secret\E/, 'nor does the trace');

	undef $died;
	capture_trace {
		eval { run({onfailure => 'Could not do the fake thing'}, 'exec /bin/kill -TERM $$'); 1 } or $died = "$@";
	};
	like($died // '', qr/killed by signal 15/, 'a killed command names its signal');
};

subtest 'a public onfailure message keeps the public stream' => sub {
	my $died;
	capture_trace {
		eval { run({stderr => 0, public_stderr => 1, onfailure => 'Could not list', speaking}, "$speak; exit 1"); 1 }
			or $died = "$@";
	};
	like($died // '', qr/\Q$err_secret\E/, 'the public stderr is shown');
	unlike((split /STDOUT/, $died // '')[0] // '', qr/\Q$out_secret\E/, 'the private output is not');
};

subtest 'read_json_from describes a failed command\'s stderr' => sub {
	my $died;
	capture_trace {
		eval { read_json_from(run({stderr => 0, speaking(FAKE_ERR => "$err_secret: connection refused")}, "$speak; exit 2")); 1 }
			or $died = "$@";
	};
	like(first_line($died), qr/exited 2 \(connection failed\)/, 'it names the exit code and kind of failure');
	unlike(first_line($died), qr/\Q$err_secret\E/, 'but not the stderr');
};

done_testing;
