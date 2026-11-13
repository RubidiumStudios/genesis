#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

# mock, given the name of a class that really exists, clears that class's own
# symbols so the mock answers in their place.  It must leave the packages
# nested under the class alone.
#
# A nested package is another module's symbol table.  Removing it from its
# parent frees it while that module's compiled subs live on, each statement in
# them still pointing at the freed table, and the first class-name method call
# such a sub makes that Perl has not cached reads freed memory.  That showed
# as an intermittent segfault in a test that mocked Genesis::Env and then ran
# Genesis::Env::NetworkClaims for real, and nothing asserted it until now,
# because the damage is silent until the memory is reused.

require Genesis::Env;
require Genesis::Env::NetworkClaims;

# Looked up by name as the test runs.  A sub named in the source is bound when
# the file compiles, and would still answer after its table was gone.
sub in_table {
	my ($package, $name) = @_;
	no strict 'refs';
	return exists ${"${package}::"}{$name} ? 1 : 0;
}

my @nested_before = sort grep {/::$/} keys %Genesis::Env::;
ok(scalar(@nested_before), 'Genesis::Env has packages nested under it to lose');
ok(in_table('Genesis::Env::NetworkClaims', 'claims_changes'),
	'and one of them holds a sub this test can look for');
ok(in_table('Genesis::Env', 'load'), 'as the class itself holds one of its own');

my $mock = mock("Genesis::Env" => {name => 'stand-in'});

is($mock->name, 'stand-in', 'the mock answers as it was defined');
ok(!in_table('Genesis::Env', 'load'), "and the class's own subs are cleared for it");

is_deeply([sort grep {/::$/} keys %Genesis::Env::], \@nested_before,
	'every package nested under the class is still in its symbol table');
ok(in_table('Genesis::Env::NetworkClaims', 'claims_changes'),
	'and a nested package still holds its subs');

done_testing;
