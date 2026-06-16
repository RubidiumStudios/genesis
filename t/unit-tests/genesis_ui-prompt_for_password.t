#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use helper;
use Test::More;
use Test::Output;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

use_ok 'Genesis::UI';

# ===========================================================================
# Genesis::UI::prompt_for_password
#
# Reads a line of input from STDIN with terminal echo disabled (when
# STDIN is an actual TTY).  In non-TTY environments (the test harness,
# CI, piped input) the function reads normally so unit tests can drive
# it through the existing set_stdin/reset_stdin pipe helper.
#
# Contract:
#   - Returns the line entered, with trailing newline stripped.
#   - Returns empty string on EOF.
#   - Returns empty string when STDIN was set to an empty pipe.
# ===========================================================================

subtest 'returns the entered line, newline stripped' => sub {
	plan tests => 1;
	set_stdin("hunter2\n");
	my $result;
	stderr_from { $result = prompt_for_password("Password") };
	reset_stdin();
	is($result, 'hunter2', 'returns entered password with newline stripped');
};

subtest 'returns empty string on EOF' => sub {
	plan tests => 1;
	set_stdin("");   # immediate EOF
	my $result;
	stderr_from { $result = prompt_for_password("Password") };
	reset_stdin();
	is($result, '', 'returns empty string on EOF');
};

subtest 'returns the line even without trailing newline' => sub {
	plan tests => 1;
	set_stdin("nonewline");   # no \n
	my $result;
	stderr_from { $result = prompt_for_password("Password") };
	reset_stdin();
	is($result, 'nonewline', 'returns full line without trailing newline');
};

subtest 'prompt is written to STDERR (not STDOUT)' => sub {
	plan tests => 2;
	set_stdin("x\n");
	my $stderr = stderr_from {
		my $stdout = stdout_from { prompt_for_password("My Prompt") };
		is($stdout, '', 'nothing written to STDOUT');
	};
	reset_stdin();
	like($stderr, qr/My Prompt/, 'prompt text written to STDERR');
};

subtest 'allows special characters in the entered password' => sub {
	plan tests => 1;
	set_stdin("p\$\@ss w0rd!#\n");
	my $result;
	stderr_from { $result = prompt_for_password("Password") };
	reset_stdin();
	is($result, 'p$@ss w0rd!#',
		'special characters round-trip without escaping');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
