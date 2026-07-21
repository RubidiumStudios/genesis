#!perl
use strict;
use warnings;

# Regression test for a Perl operator-precedence compile warning in
# Genesis::Commands::Repo.  `exit defined($err) ? 1 : 0;` parses as
# `exit(defined($err))` -- the ternary is silently swallowed -- which
# perl flags with "Possible precedence issue with control flow
# operator (exit)". No unit test in this suite currently asserts a
# module compiles warning-free, so this shells out to `perl -c`
# directly (mirroring how `make compile-check` verifies the module)
# rather than trying to capture a compile-time warning via
# $SIG{__WARN__}, which only sees warnings raised at runtime.

use Test::More;

my $module = 'lib/Genesis/Commands/Repo.pm';

my $stderr = `perl -Ilib -c "$module" 2>&1 1>/dev/null`;

unlike(
	$stderr,
	qr/Possible precedence issue/,
	'Commands/Repo.pm compiles without an operator-precedence warning'
) or diag $stderr;

done_testing;
