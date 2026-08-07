#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use PodGate::Pod qw/parse_pod parse_pod_text/;

my $FIXTURES = 't/src/pod-gate';

subtest 'head1 sections' => sub {
	my $p = parse_pod("$FIXTURES/Sample.pod");

	cmp_deeply(
		$p->{head1_order},
		[qw/NAME SYNOPSIS DESCRIPTION METHODS/,
		 'INTERNAL METHODS', 'OPERATOR OVERLOADING',
		 'AUTHOR', 'COPYRIGHT AND LICENSE'],
		"head1 sections in document order"
	);
	like($p->{head1}{NAME}, qr/happy-path POD fixture/, "section body captured");
};

subtest 'method entries' => sub {
	my $p = parse_pod("$FIXTURES/Sample.pod");

	cmp_deeply(
		[sort keys %{$p->{methods}}],
		[sort qw/new listed_params raises mutates _private_helper
		         shifted_params indexed_params context_sensitive
		         to_string equals/],
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

subtest 'headings that carry a signature' => sub {
	# Most of the tree heads methods with their argument list --
	# "=head2 deploy($env_name, $reason)".  Requiring a bare identifier
	# rejects all of them and reports the whole module undocumented.
	my $p = parse_pod("$FIXTURES/Sample.pod");

	ok(exists $p->{methods}{listed_params},
		"the name is recovered from a heading with an argument list");
	ok(!exists $p->{methods}{'listed_params($first, $second)'},
		"and the signature is not part of the name");
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

subtest 'section kind decides what is a method' => sub {
	# Inverted on purpose: a =head2 is a method only where the section
	# documents subs.  The other way round -- everything is a method
	# unless excluded -- means every new prose section invents methods.
	my $p = parse_pod("$FIXTURES/Sample.pod");

	is($p->{section_kind}{METHODS},              'api',       "METHODS documents subs");
	is($p->{section_kind}{'INTERNAL METHODS'},   'interface', "INTERNAL METHODS may outlive its subs");
	is($p->{section_kind}{'OPERATOR OVERLOADING'}, 'prose',   "operator docs are not methods");
	is($p->{section_kind}{DESCRIPTION},          'prose',     "and neither is prose");

	ok(!exists $p->{methods}{Stringification},
		"an overload heading does not become a method");
	ok($p->{methods}{_private_helper}{is_interface},
		"an INTERNAL METHODS entry is flagged as interface");
	ok(!$p->{methods}{new}{is_interface},
		"an api entry is not");
};

subtest 'section names actually used in the tree' => sub {
	# Taken from the corpus rather than invented.  Qualifiers accumulate
	# on these headings -- CLASS HELPER FUNCTIONS, FUNCTIONS (RENDERING
	# HELPERS) -- so the rule keys on the noun, not the whole string.
	my %expect = (
		'METHODS'                      => 'api',
		'FUNCTIONS'                    => 'api',
		'CLASS METHODS'                => 'api',
		'INSTANCE METHODS'             => 'api',
		'CLASS FUNCTIONS'              => 'api',
		'CLASS HELPER FUNCTIONS'       => 'api',
		'FUNCTIONS (RENDERING HELPERS)'=> 'api',
		'FUNCTIONS - SPECIAL CATEGORY' => 'api',
		'METHODS - DEPRECATED'         => 'api',
		'CONSTRUCTORS'                 => 'api',
		'INTERNAL METHODS'             => 'interface',
		'INTERNAL FUNCTIONS'           => 'interface',
		'ABSTRACT METHODS'             => 'interface',
		'OVERRIDE POINTS'              => 'interface',
		'OPERATOR OVERLOADING'         => 'prose',
		'OPERATOR OVERLOADS'           => 'prose',
		'BASH HELPERS'                 => 'prose',
		'INTERNAL BASH HELPERS'        => 'prose',
		'KNOWN ISSUES'                 => 'prose',
		'SEE ALSO'                     => 'prose',
		'DESIGN CONSIDERATIONS'        => 'prose',
		# The noun has to be the heading, not a word inside it.  A
		# keyword search reads these as API sections and then demands
		# that whatever prose they contain be backed by subs.
		'NOTES ON METHODS'             => 'prose',
		'COMPARISON TO OTHER MODULES'  => 'prose',
		'GENESIS KIT HOOKS'            => 'prose',
		# Grouped forms, which is the point of the category suffix.
		'FUNCTIONS - VAULT PATHS'      => 'api',
		'METHODS - BOSH CONFIGS'       => 'api',
		'INTERNAL METHODS - CACHING'   => 'interface',
	);
	for my $name (sort keys %expect) {
		my $p = parse_pod_text("=head1 $name\n\n=head2 thing\n\nBody.\n");
		is($p->{section_kind}{$name}, $expect{$name}, "$name is $expect{$name}");
	}

	# INTERNAL must win over the bare noun, or every internal section
	# would demand its subs exist in this file.
	my $p = parse_pod_text("=head1 INTERNAL METHODS\n\n=head2 thing\n\nBody.\n");
	ok($p->{methods}{thing}{is_interface}, "INTERNAL wins over the METHODS suffix");
};

subtest 'missing file is an error' => sub {
	eval {parse_pod("$FIXTURES/does-not-exist.pod")};
	like($@, qr/does-not-exist\.pod/, "names the file it could not read");
};

done_testing;
