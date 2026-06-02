#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;

use_ok 'Genesis::Log';

# ===========================================================================
# parse_lifespan($value) -> structured retention policy
#
# Pure parser; no IO, no globals.
# Subsequent subtasks (B, C, D) consume the returned policy hash.
# ===========================================================================

sub parse { Genesis::Log::parse_lifespan(@_) }

# ---------- special values ----------

subtest 'forever => skip cleanup entirely' => sub {
	plan tests => 1;
	cmp_deeply parse('forever'),
		{ mode => 'none', count => undef, age_seconds => undef, warnings => [] },
		"'forever' returns mode=none with no warnings";
};

subtest 'current is deprecated alias for 1 (embeds deprecation warning)' => sub {
	plan tests => 3;
	my $result = parse('current');
	is $result->{mode},        'union', "'current' resolves to lifespan: 1 (mode=union)";
	is $result->{count},       1,       "'current' resolves to count=1";
	cmp_deeply $result->{warnings},
		[ re(qr/lifespan:\s*current\s+is\s+deprecated/i) ],
		"deprecation warning embedded in result (caller emits subject to suppress_warnings.deprecations)";
};

# ---------- bare count ----------

sub union { my %h = @_; +{ mode => 'union', count => $h{count}, age_seconds => $h{age_seconds}, warnings => [] } }
sub xsect { my %h = @_; +{ mode => 'intersection', count => $h{count}, age_seconds => $h{age_seconds}, warnings => [] } }

subtest 'bare integer = count-based retention' => sub {
	plan tests => 3;
	cmp_deeply parse('1'),   union(count => 1,   age_seconds => undef), "'1' is count=1";
	cmp_deeply parse('5'),   union(count => 5,   age_seconds => undef), "'5' is count=5";
	cmp_deeply parse('100'), union(count => 100, age_seconds => undef), "'100' is count=100";
};

# ---------- qualified duration ----------

subtest 'short-form duration suffixes' => sub {
	plan tests => 4;
	cmp_deeply parse('1d'), union(count => undef, age_seconds => 86400), "1d";
	cmp_deeply parse('2w'), union(count => undef, age_seconds => 2*604800), "2w";
	cmp_deeply parse('3m'), union(count => undef, age_seconds => 3*2592000), "3m";
	cmp_deeply parse('1y'), union(count => undef, age_seconds => 31536000), "1y";
};

subtest 'long-form duration suffixes (singular and plural)' => sub {
	plan tests => 6;
	cmp_deeply parse('1 day'),     union(count => undef, age_seconds => 86400), "1 day";
	cmp_deeply parse('7 days'),    union(count => undef, age_seconds => 7*86400), "7 days";
	cmp_deeply parse('2 weeks'),   union(count => undef, age_seconds => 2*604800), "2 weeks";
	cmp_deeply parse('1 week'),    union(count => undef, age_seconds => 604800), "1 week";
	cmp_deeply parse('3 months'),  union(count => undef, age_seconds => 3*2592000), "3 months";
	cmp_deeply parse('1 year'),    union(count => undef, age_seconds => 31536000), "1 year";
};

subtest 'case-insensitive unit suffixes' => sub {
	plan tests => 2;
	cmp_deeply parse('7D'),       union(count => undef, age_seconds => 7*86400),   "7D matches 7d";
	cmp_deeply parse('2 WEEKS'),  union(count => undef, age_seconds => 2*604800),  "2 WEEKS matches 2 weeks";
};

# ---------- compound: explicit min / max + bare-or back-compat ----------

subtest 'min of ... or ... => union semantics (liberal, keep if either)' => sub {
	plan tests => 2;
	cmp_deeply parse('min of 5 or 2 weeks'),
		union(count => 5, age_seconds => 2*604800),
		"min of 5 or 2 weeks: keep if count OR age would keep";
	cmp_deeply parse('min of 10 or 30 days'),
		union(count => 10, age_seconds => 30*86400),
		"min of 10 or 30 days";
};

subtest 'max of ... or ... => intersection semantics (aggressive, keep only if both)' => sub {
	plan tests => 2;
	cmp_deeply parse('max of 5 or 2 weeks'),
		xsect(count => 5, age_seconds => 2*604800),
		"max of 5 or 2 weeks: keep only if BOTH count AND age would keep";
	cmp_deeply parse('max of 100 or 6 months'),
		xsect(count => 100, age_seconds => 6*2592000),
		"max of 100 or 6 months";
};

subtest 'bare X or Y is back-compat alias for min of X or Y' => sub {
	plan tests => 2;
	cmp_deeply parse('5 or 2 weeks'),
		union(count => 5, age_seconds => 2*604800),
		"bare 'or' resolves to min-of (union)";
	cmp_deeply parse('10 or 1 month'),
		union(count => 10, age_seconds => 2592000),
		"bare 'or' with different units";
};

subtest 'compound expressions: whitespace tolerant' => sub {
	plan tests => 2;
	cmp_deeply parse('  min of  5   or  2 weeks  '),
		union(count => 5, age_seconds => 2*604800),
		"extra surrounding/internal whitespace OK";
	cmp_deeply parse('5 logs or 2 weeks'),
		union(count => 5, age_seconds => 2*604800),
		"'5 logs' (with the optional 'logs' word) parses same as '5'";
};

# ---------- invalid input ----------

subtest 'invalid input bails with a descriptive error' => sub {
	plan tests => 4;
	throws_ok { parse('nonsense') } qr/lifespan/i,
		"unknown bare word bails";
	throws_ok { parse('') } qr/lifespan/i,
		"empty string bails";
	throws_ok { parse('5 weeks per year') } qr/lifespan/i,
		"unrecognized compound bails";
	throws_ok { parse('min of foo or bar') } qr/lifespan/i,
		"compound with unparseable components bails";
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
