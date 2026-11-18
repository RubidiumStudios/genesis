#!/usr/bin/env perl
# The logger scrubs registered credentials out of everything it writes.
#
# Redacting each call site is the first line of defence, but any one that
# is missed puts a credential in the trace.  Genesis registers each
# credential it loads with the logger, and the logger replaces every
# registered value before a line reaches a log file, whatever level or
# path the line took.  On the terminal, OUTPUT and INFO are left alone,
# since commands such as `genesis bosh --connect` print credentials there
# on purpose.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use JSON::PP qw/encode_json/;

use Genesis;
use Genesis::Log;

my $secret = fake_secret('director');

subtest 'a registered value is scrubbed at every level' => sub {
	my $log = capture_trace {
		my ($logger) = @_;
		$logger->register_secret($secret, 'bosh-client-secret');
		trace("trace line with %s in it", $secret);
		qtrace("qtrace line with %s in it", $secret);
		debug("debug line with %s in it", $secret);
		info("info line with %s in it", $secret);
		warning("warning line with %s in it", $secret);
		error("error line with %s in it", $secret);
		dump_var(director => {secret => $secret});
	};
	unlike($log, qr/\Q$secret\E/, 'the value is absent from the log file');
	my $count = () = $log =~ /<redacted:bosh-client-secret>/g;
	is($count, 7, 'each line names what was redacted');
};

subtest 'a long line wrapped by the logger is still scrubbed' => sub {
	my $log = capture_trace {
		my ($logger) = @_;
		$logger->register_secret($secret, 'bosh-client-secret');
		trace("%s%s", ('x' x 100), $secret);
	};
	unlike($log, qr/\Q$secret\E/, 'the value is absent from the log file');
	my $first_half = substr($secret, 0, 20);
	unlike($log, qr/\Q$first_half\E/, 'no wrapped fragment of the value survives');
};

subtest 'escaped forms of the value are scrubbed' => sub {
	my $quoted = "q'uo\\te\"d-".fake_secret('quoted');
	my $log = capture_trace {
		my ($logger) = @_;
		$logger->register_secret($quoted, 'quoted-secret');
		dump_var(raw => $quoted);
		trace("json: %s", encode_json({v => $quoted}));
	};
	(my $tail = $quoted) =~ s/.*-//;
	unlike($log, qr/\Q$tail\E/, 'neither the Dumper nor the JSON form survives');
};

subtest 'the command line written at the top of a log is scrubbed' => sub {
	local $ENV{GENESIS_FULL_CALL} = "genesis do-thing --password $secret";
	my $log = capture_trace {
		my ($logger) = @_;
		$logger->register_secret($secret, 'cli-secret');
		trace("first line");
	};
	like($log, qr/^Command: /, 'the command line is written');
	unlike($log, qr/\Q$secret\E/, 'the value is absent from the command line');
};

subtest 'the package-level form registers a value too' => sub {
	my $log = capture_trace {
		Genesis::Log::register_secret($secret, 'early');
		trace("late line with %s", $secret);
	};
	unlike($log, qr/\Q$secret\E/, 'the package-level form registers too');
};

subtest 'credential environment variables are registered at startup' => sub {
	local $ENV{BOSH_CLIENT_SECRET} = $secret;
	my $log = capture_trace {
		trace("env line with %s", $secret);
	};
	unlike($log, qr/\Q$secret\E/, 'BOSH_CLIENT_SECRET from the caller is scrubbed');
};

subtest 'short and empty values are not registered' => sub {
	my $log = capture_trace {
		my ($logger) = @_;
		$logger->register_secret($_, 'short') for ('', undef, 'abc');
		trace("abc stays readable");
	};
	like($log, qr/abc stays readable/, 'a trivially short value is not scrubbed');
};

subtest 'terminal trace output is scrubbed, deliberate output is not' => sub {
	my ($log, $stderr, $stdout) = capture_trace {
		my ($logger) = @_;
		$logger->register_secret($secret, 'bosh-client-secret');
		trace("terminal trace with %s", $secret);
		output("export BOSH_CLIENT_SECRET=\"%s\"", $secret);
	} terminal_trace => 1, terminal_level => 'TRACE';
	unlike($stderr, qr/\Q$secret\E/, 'trace on the terminal is scrubbed');
	like($stdout, qr/\Q$secret\E/, 'OUTPUT on the terminal keeps the value');
	unlike($log, qr/\Q$secret\E/, 'the log file is scrubbed either way');
};

subtest 'registering before any logger exists leaves terminal setup alone' => sub {
	# Genesis::logger configures the terminal only when it creates the
	# logger, so registration must never be what creates it.
	my $stderr = '';
	{
		no warnings 'once';
		local $Genesis::Log::Logger = undef;
		local *STDERR;
		open STDERR, '>', \$stderr or die "cannot capture stderr: $!";
		Genesis::Log::register_secret(fake_secret('early'), 'early');
		ok(!defined($Genesis::Log::Logger), 'registering did not create a logger');
		warning("a warning after registration");
	}
	like($stderr, qr/a warning after registration/, 'the warning still reaches the terminal');
};

done_testing;
