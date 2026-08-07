#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use PodGate::Pod qw/parse_pod/;

my $FIXTURES = 't/src/pod-gate';

subtest 'head1 sections' => sub {
	my $p = parse_pod("$FIXTURES/Sample.pod");

	cmp_deeply(
		$p->{head1_order},
		[qw/NAME SYNOPSIS DESCRIPTION METHODS/,
		 'INTERNAL METHODS', 'AUTHOR', 'COPYRIGHT AND LICENSE'],
		"head1 sections in document order"
	);
	like($p->{head1}{NAME}, qr/happy-path POD fixture/, "section body captured");
};

subtest 'method entries' => sub {
	my $p = parse_pod("$FIXTURES/Sample.pod");

	cmp_deeply(
		[sort keys %{$p->{methods}}],
		[sort qw/new listed_params raises mutates _private_helper/],
		"only head2 headings that name a method are methods"
	);

	is($p->{methods}{new}{section}, 'METHODS',
		"attributed to its enclosing head1");
	is($p->{methods}{_private_helper}{section}, 'INTERNAL METHODS',
		"internal methods attributed separately");
};

subtest 'a head3 does not end the section' => sub {
	# The nested heading sits between "Notes on argument handling" and
	# mutates.  Treating any heading as a boundary drops mutates out of
	# METHODS and reports it undocumented while it is plainly documented.
	my $p = parse_pod("$FIXTURES/Sample.pod");

	ok(exists $p->{methods}{mutates}, "a method after a head3 is still found");
	is($p->{methods}{mutates}{section}, 'METHODS',
		"and still attributed to the enclosing head1");
};

subtest 'prose headings are not methods' => sub {
	my $p = parse_pod("$FIXTURES/Sample.pod");

	ok(!exists $p->{methods}{Notes},
		"'Notes on argument handling' does not become a method named Notes");
	ok(scalar(grep {/Notes on argument handling/} @{$p->{prose_headings}}),
		"but it is still recorded, so it is not silently discarded");
};

subtest 'documented contract blocks' => sub {
	my $p = parse_pod("$FIXTURES/Sample.pod");

	ok($p->{methods}{new}{has_params},   "Parameters block detected");
	ok($p->{methods}{new}{has_returns},  "Returns block detected");
	ok($p->{methods}{new}{has_examples}, "Examples block detected");
	ok(!$p->{methods}{new}{has_errors},  "and Errors not claimed where absent");

	ok($p->{methods}{raises}{has_errors},    "Errors block detected");
	ok(!$p->{methods}{raises}{has_examples}, "Examples not claimed where absent");

	cmp_deeply($p->{methods}{listed_params}{params}, ['$first','$second'],
		"documented parameter names read out of the =item list");
};

subtest 'missing file is an error' => sub {
	eval {parse_pod("$FIXTURES/does-not-exist.pod")};
	like($@, qr/does-not-exist\.pod/, "names the file it could not read");
};

done_testing;
