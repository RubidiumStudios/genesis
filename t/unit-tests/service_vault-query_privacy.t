#!/usr/bin/env perl
# Service::Vault::query runs safe, and what safe prints can be any secret
# in vault.  A query is private by default: its output and stderr stay out
# of the trace, and a caller that needs them traced asks for that.  A
# write's values stay out of the trace however the command is written, and
# a failed write reports its exit status and a safe diagnostic, never what
# safe printed.
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
put_file("$dir/bin/safe", 0755, <<"EOS");
#!/bin/bash
for a in "\$@"; do printf '%s\\n' "\$a"; done >> "$dir/argv"
[[ -n \$FAKE_OUT ]] && printf '%s\\n' "\$FAKE_OUT"
[[ -n \$FAKE_ERR ]] && printf '%s\\n' "\$FAKE_ERR" >&2
exit \${FAKE_RC:-0}
EOS
$ENV{PATH} = "$dir/bin:$ENV{PATH}";

sub received { my $got = -f "$dir/argv" ? Genesis::slurp("$dir/argv") : ''; unlink "$dir/argv"; $got }
my $vault = bless({url => 'https://10.0.0.5', name => 'fake'}, 'Service::Vault');

subtest 'a query keeps its output and stderr out of the trace by default' => sub {
	my ($out_secret, $err_secret) = map {fake_secret($_)} qw/query-out query-err/;
	local $ENV{FAKE_OUT} = $out_secret;
	local $ENV{FAKE_ERR} = $err_secret;
	for my $cmd (['get', 'secret/fake:password'], ['vault', 'token', 'renew'], ['safe auth status --json']) {
		my ($out, $rc, $err);
		my $log = capture_trace { ($out, $rc, $err) = $vault->query(@$cmd) };
		is($out, $out_secret, "@$cmd: the caller gets the output");
		is($err, "$err_secret\n", "@$cmd: and the stderr");
		unlike($log, qr/\Q$out_secret\E/, "@$cmd: the output is absent from the trace");
		unlike($log, qr/\Q$err_secret\E/, "@$cmd: the stderr is absent from the trace");
	}
	received();
};

subtest 'a caller can ask for output to be traced' => sub {
	local $ENV{FAKE_OUT} = 'secret/fake/listing';
	my $log = capture_trace { $vault->query({redact_output => 0}, 'paths') };
	like($log, qr{secret/fake/listing}, 'the opted-in output is traced');
	received();
};

subtest 'pairs written inside a command string stay out of the trace' => sub {
	my ($plain, $quoted) = map {fake_secret($_)} qw/inline-plain inline-quoted/;
	my $log = capture_trace { $vault->query("set secret/fake/path token=$plain") };
	like(received(), qr/^set secret\/fake\/path token=\Q$plain\E$/m, 'safe receives the string as it was given');
	unlike($log, qr/\Q$plain\E/, 'the value is absent from the trace');
	like($log, qr/set secret\/fake\/path <redacted:\d+ bytes>/, 'the words before it stay in view');

	$log = capture_trace { $vault->query("safe set secret/fake/path token=$plain") };
	like(received(), qr/^token=\Q$plain\E$/m, 'a safe command line gives safe the pair as an argument');
	unlike($log, qr/\Q$plain\E/, 'the value is absent from the trace');
	like($log, qr/token=<redacted:\d+ bytes>/, 'its key stays in view');

	my $expanding = fake_secret("inline-expanding");
	$log = capture_trace { $vault->query("safe set secret/fake/path token=$expanding\$HOME") };
	like(received(), qr/^token=\Q$expanding\E/m, 'a line the shell expands is run as it is');
	unlike($log, qr/\Q$expanding\E/, 'and kept out of the trace whole');

	$log = capture_trace { $vault->query("safe set secret/fake/path 'note=$quoted with spaces'") };
	like(received(), qr/^note=\Q$quoted\E with spaces$/m, 'a quoted pair reaches safe whole');
	unlike($log, qr/\Q$quoted\E/, 'and is absent from the trace');
};

subtest 'a failed write reports its status, not what safe printed' => sub {
	my $value = fake_secret('failed-write');
	local $ENV{FAKE_OUT} = "error writing password=$value";
	local $ENV{FAKE_ERR} = "permission denied for password=$value";
	local $ENV{FAKE_RC} = 1;
	my $died;
	my ($log, $stderr) = capture_trace {
		eval { $vault->_write_batch('secret/fake/path', ["password=$value"], {}); 1 } or $died = "$@";
	};
	ok(defined($died), 'the write fails');
	unlike($died // '', qr/\Q$value\E/, 'the error leaves the value out');
	unlike($stderr, qr/\Q$value\E/, 'so does the terminal');
	unlike($log, qr/\Q$value\E/, 'and the trace');
	like(($died // '').$stderr, qr/exited 1/, 'the exit status is reported');
	like(($died // '').$stderr, qr/permission denied/, 'with a diagnostic that is safe to show');
	received();
};

done_testing;
