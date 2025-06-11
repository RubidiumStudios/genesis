#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;

# Pre-declare mocks before loading modules
BEGIN {
	# Mock which command to control processor availability
	*CORE::GLOBAL::qx = sub {
		my $cmd = shift;
		if ($cmd =~ /which\s+(\w+)/) {
			my $proc = $1;
			return $main::processor_available{$proc} ? "/usr/bin/$proc\n" : "";
		}
		return "";
	};
}

use_ok('Genesis');
use_ok('Genesis::YAMLCLI');

# Mock the run function
{
	no warnings 'redefine';
	*Genesis::run = sub { 
		my $opts = ref($_[0]) eq 'HASH' ? shift : {};
		return ("mocked output", 0, "");
	};
}

# Test 1: Default processor (spruce available)
{
	local %main::processor_available = (spruce => 1, graft => 1);
	my $yaml = Genesis::YAMLCLI->new();
	ok($yaml, "Created YAMLCLI instance with default");
	is($yaml->cli(), 'spruce', "Default processor is spruce");
}

# Test 2: Graft preference (both available)
{
	local %main::processor_available = (spruce => 1, graft => 1);
	my $yaml = Genesis::YAMLCLI->new(processor => 'graft');
	ok($yaml, "Created YAMLCLI instance with graft preference");
	is($yaml->cli(), 'graft', "Processor is graft when requested");
}

# Test 3: Fallback from graft to spruce
{
	local %main::processor_available = (spruce => 1, graft => 0);
	
	# Capture warnings
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };
	
	my $yaml = Genesis::YAMLCLI->new(processor => 'graft');
	ok($yaml, "Created YAMLCLI instance with fallback");
	is($yaml->cli(), 'spruce', "Falls back to spruce when graft not available");
	
	# Call a method to trigger the warning
	$yaml->merge('/dev/null');
	ok(grep { /graft not found, falling back to spruce/ } @warnings, "Warning about fallback displayed");
}

# Test 4: Fallback from spruce to graft
{
	local %main::processor_available = (spruce => 0, graft => 1);
	
	# Capture warnings
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };
	
	my $yaml = Genesis::YAMLCLI->new(processor => 'spruce');
	ok($yaml, "Created YAMLCLI instance with spruce->graft fallback");
	is($yaml->cli(), 'graft', "Falls back to graft when spruce not available");
	
	# Call a method to trigger the warning
	$yaml->merge('/dev/null');
	ok(grep { /spruce not found, falling back to graft/ } @warnings, "Warning about fallback displayed");
}

# Test 5: Neither processor available
{
	local %main::processor_available = (spruce => 0, graft => 0);
	
	eval { Genesis::YAMLCLI->new() };
	like($@, qr/Neither spruce nor graft is available/, "Dies when no processor available");
}

# Test 6: cli() method
{
	local %main::processor_available = (spruce => 1, graft => 1);
	
	my $yaml = Genesis::YAMLCLI->new(processor => 'graft');
	is($yaml->cli(), 'graft', "cli() returns the actual processor being used");
}

done_testing;