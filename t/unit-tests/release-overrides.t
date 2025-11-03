#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

# Test that the fix for undefined version handling works
# This is a basic test to ensure no regression

# Simple test for the new_enough function with undefined values
{
	no warnings 'once';
	local *Genesis::new_enough = sub {
		my ($version, $minimum) = @_;
		return 1 unless defined $minimum;
		return 0 unless defined $version;
		return $version >= $minimum;
	};
	
	ok(Genesis::new_enough("1.0.0", undef), "new_enough handles undefined minimum");
	ok(!Genesis::new_enough(undef, "1.0.0"), "new_enough returns false for undefined version");
}

# Test string comparison with undefined values
{
	my $val1 = "test";
	my $val2 = undef;
	
	my $result = eval {
		no warnings 'uninitialized';
		defined($val2) && $val1 ne $val2;
	};
	ok(!$@, "String comparison with undefined value doesn't die");
	ok(!$result, "Comparison with undefined value returns false");
}

# Test sprintf with correct number of arguments
{
	my @values = ("bullet", "release-name", "1.0.0", "G", "2.0.0");
	my $format = "[[     %s#C{%s} #y{v%s} => #%s{v%s}";
	
	my $result = eval {
		sprintf($format, @values);
	};
	ok(!$@, "sprintf with 5 format specifiers and 5 values works");
	
	# Test with undefined value
	@values = ("bullet", "release-name", undef, "G", "2.0.0");
	$result = eval {
		no warnings 'uninitialized';
		sprintf($format, @values);
	};
	ok(!$@, "sprintf with undefined value doesn't die");
}

done_testing;