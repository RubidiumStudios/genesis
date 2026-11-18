#!/usr/bin/env perl
# The logger scrubs registered credentials out of everything it writes.
#
# Redacting each call site is the first line of defence, but any one that
# is missed puts a credential in the trace.  Genesis registers each
# credential it loads with the logger, and the logger replaces every
# registered value before a line reaches a log file, whatever level or
# path the line took.  On the terminal, OUTPUT and INFO are left alone,
# since they carry what the operator asked to see.
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

subtest 'a short value is scrubbed where it stands alone' => sub {
	# A short director password is still a password.  Matching it inside
	# longer words would mangle the log, so it is matched only where no
	# letter or digit touches it.
	my $short = 'k'.int(rand(9)).'Q';
	my $log = capture_trace {
		my ($logger) = @_;
		$logger->register_secret($_, 'short') for ('', undef, $short);
		trace("password=%s;", $short);
		trace("export BOSH_CLIENT_SECRET=\"%s\"", $short);
		trace("x%sy stays readable", $short);
	};
	unlike($log, qr/password=\Q$short\E;/, 'a short value standing alone is scrubbed');
	unlike($log, qr/"\Q$short\E"/, 'quoted as well');
	like($log, qr/x\Q$short\Ey stays readable/, 'inside a longer word it is left alone');
};

subtest 'credential variables set after the logger starts are registered' => sub {
	my ($role_id, $late) = map {fake_secret($_)} qw/role-id late-token/;
	local $ENV{VAULT_ROLE_ID} = $role_id;
	my $log = capture_trace {
		$ENV{VAULT_TOKEN} = $late;
		trace("role %s token %s", $role_id, $late);
		delete $ENV{VAULT_TOKEN};
	};
	unlike($log, qr/\Q$role_id\E/, 'VAULT_ROLE_ID is registered');
	unlike($log, qr/\Q$late\E/, 'a token set after startup is registered when the log is written');
};

subtest 'shell-quoted and ASCII-escaped forms are scrubbed' => sub {
	my $value = fake_secret('quoted') . q{'"$} . "\x{e9}";
	my $log = capture_trace {
		my ($logger) = @_;
		$logger->register_secret($value, 'quoted');
		trace("single %s", Genesis::shell_quote($value));
		trace("double \"%s\"", $value =~ s/"/"\\""/gr);
		trace("backslashed \"%s\"", $value =~ s/(["\\\$`])/\\$1/gr);
		trace("ascii json %s", JSON::PP->new->ascii->allow_nonref->encode($value));
	};
	my ($core) = $value =~ /^(fake-quoted-[0-9a-f]+)/;
	unlike($log, qr/\Q$core\E/, 'no form of the value is written');
};

subtest 'bosh --connect exports go to stdout and never to a log' => sub {
	require Genesis::Commands::Bosh;
	my $secret = fake_secret('connect');
	my $short = 'p'.int(rand(9)).'w';
	my ($log, $stderr, $stdout) = capture_trace {
		Genesis::Commands::Bosh::_print_connect_exports('fake-alias',
			BOSH_CLIENT_SECRET => $secret, BOSH_CLIENT => 'admin', BOSH_PASSWORD => $short);
	};
	like($stdout, qr/^export BOSH_CLIENT_SECRET="\Q$secret\E"$/m, 'the operator gets the export');
	like($stdout, qr/^export BOSH_PASSWORD="\Q$short\E"$/m, 'short values included');
	unlike($log, qr/\Q$secret\E|BOSH_PASSWORD="\Q$short\E"/, 'the log never sees a value');
	like($log, qr/BOSH_CLIENT_SECRET/, 'the log names what was exported');
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
