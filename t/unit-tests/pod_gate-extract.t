#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use PodGate::Extract qw/extract_module/;

my $FIXTURES = 't/src/pod-gate';

subtest 'happy path: every parameter form' => sub {
	my $m = extract_module("$FIXTURES/Sample.pm");
	my %by_name = map {$_->{name} => $_} @{$m->{methods}};

	cmp_deeply(
		[sort keys %by_name],
		[sort qw/new listed_params shifted_params indexed_params raises
		         context_sensitive mutates to_string equals _private_helper
		         AUTOLOAD DESTROY/],
		"finds every sub and nothing else"
	);

	cmp_deeply($by_name{listed_params}{params}, ['$self','$first','$second'],
		"my (...) = \@_ form");
	cmp_deeply($by_name{shifted_params}{params}, ['$self','$only'],
		"shift chain form");
	cmp_deeply($by_name{new}{params}, ['$class','%opts'],
		"hash-slurp in the parameter list");

	# $_[N] indexing has no names to recover, so the extractor reports arity.
	# indexed_params reads $_[1] and $_[2], so three positions are in play.
	is(scalar @{$by_name{indexed_params}{params}}, 3,
		"\$_[N] indexing yields positional arity");
};

subtest 'happy path: method properties' => sub {
	my $m = extract_module("$FIXTURES/Sample.pm");
	my %by_name = map {$_->{name} => $_} @{$m->{methods}};

	ok($by_name{_private_helper}{is_private}, "leading underscore reads as private");
	ok(!$by_name{new}{is_private},            "new does not");

	ok($by_name{context_sensitive}{has_wantarray}, "wantarray detected");
	ok(!$by_name{mutates}{has_wantarray},          "and not claimed where absent");

	ok($by_name{mutates}{has_mutations},        "assignment to \$self->{...} detected");
	ok(!$by_name{listed_params}{has_mutations}, "and not claimed where absent");

	cmp_deeply(
		[sort @{$by_name{raises}{die_messages}}],
		[sort ('no such path: $path', 'cannot read %s')],
		"die and bail messages both collected"
	);
	is(scalar @{$by_name{listed_params}{die_messages}}, 0,
		"no error messages invented for a sub that raises none");

	is($by_name{new}{line}, 16, "line number points at the sub");
};

subtest 'special subs are marked, not dropped' => sub {
	# Perl's named blocks are exempt from *requiring* POD, but they must
	# still be extracted: dropping them makes a documented DESTROY look
	# like POD for a method that does not exist.  Exemption is the check's
	# job, not the extractor's.
	my $m = extract_module("$FIXTURES/Sample.pm");
	my %by_name = map {$_->{name} => $_} @{$m->{methods}};

	ok($by_name{AUTOLOAD}{is_special}, "AUTOLOAD marked special");
	ok($by_name{DESTROY}{is_special},  "DESTROY marked special");
	ok(!$by_name{new}{is_special},     "an ordinary sub is not");

	ok(!$by_name{DESTROY}{is_private},
		"special does not imply private -- they are separate questions");
};

subtest 'module context' => sub {
	my $m = extract_module("$FIXTURES/Sample.pm");
	my $c = $m->{context};

	ok(!$c->{is_mixin},                          "a package is not a mixin");
	is(scalar @{$c->{overloads}}, 1,             "overload pragma captured");
	like($c->{inheritance}[0], qr/Sample::Base/, "base class captured");
	ok(scalar(grep {/VERSION/} @{$c->{package_globals}}), "our-variables captured");
};

subtest 'declarations that are not declarations' => sub {
	# The reason this gate parses instead of grepping.  Each of these would
	# be a phantom undocumented method, and a phantom failure in a hard gate
	# is unfixable -- there is nothing for the author to document.
	my $m = extract_module("$FIXTURES/Decoys.pm");

	cmp_deeply([map {$_->{name}} @{$m->{methods}}], ['real_method'],
		"heredoc, quoted strings, POD block and comment all ignored");
};

subtest 'mixins' => sub {
	my $m = extract_module("$FIXTURES/_sample_mixin.pm");

	ok($m->{context}{is_mixin},
		"underscore filename with no package declaration reads as a mixin");
	cmp_deeply(
		[sort map {$_->{name}} @{$m->{methods}}],
		[sort qw/mixed_in_method _mixed_in_helper/],
		"its subs are still extracted"
	);
};

subtest 'unparseable input is an error, not an empty result' => sub {
	# Returning "no methods" for a file that could not be read would let a
	# broken module pass the gate clean.
	eval {extract_module("$FIXTURES/does-not-exist.pm")};
	like($@, qr/does-not-exist\.pm/, "missing file names itself in the error");
};

done_testing;
