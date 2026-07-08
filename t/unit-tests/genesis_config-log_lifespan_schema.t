#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::Deep;

use_ok 'Genesis::Config';
use_ok 'Genesis';

my $tmp = workdir();

# Global-config schema exposure of the log-entry lifespan field.
#
# Genesis::Log::parse_lifespan accepts a much richer grammar than the
# legacy enum {forever, current}: bare counts (1, "5 logs"), durations
# ("30d", "1w"), and compound bounds ("min of 5 or 30d").  The global
# config schema must permit those values through validation so that
# users following the deprecation warning
#   "lifespan: current is deprecated; use lifespan: 1 instead"
# do not immediately trip
#   "unknown value: 1; expected one of forever, current"
# on their very next validate() call.

my $schema = Genesis::global_config_schema();

# Helper: build a minimal config with a single logs entry, run validate,
# and capture whatever bail() message escapes.  validate() bails on the
# first error batch rather than returning; catch it via eval so we can
# assert on the message.
sub validate_lifespan {
	my ($lifespan) = @_;
	my $cfg = Genesis::Config->new(
		"$tmp/gc.yml",
		0,
		{
			logs => [{
				file => '/tmp/genesis.log',
				lifespan => $lifespan,
			}],
		},
	);
	eval { $cfg->validate($schema); 1 } or return $@;
	return '';
}

subtest 'lifespan: integer 1 -- the value the deprecation warning tells users to switch to' => sub {
	my $err = validate_lifespan(1);
	is($err, '', 'lifespan: 1 passes global config validation')
		or diag "bail message was: $err";
};

subtest 'lifespan: string "5" -- bare count' => sub {
	my $err = validate_lifespan('5');
	is($err, '', 'lifespan: "5" passes global config validation')
		or diag "bail message was: $err";
};

subtest 'lifespan: "forever" -- legacy enum value still accepted' => sub {
	my $err = validate_lifespan('forever');
	is($err, '', 'lifespan: forever passes global config validation')
		or diag "bail message was: $err";
};

subtest 'lifespan: "current" -- deprecated but still accepted' => sub {
	my $err = validate_lifespan('current');
	is($err, '', 'lifespan: current passes global config validation (deprecated, but valid)')
		or diag "bail message was: $err";
};

subtest 'lifespan: "5 or 30d" -- compound bound grammar' => sub {
	my $err = validate_lifespan('5 or 30d');
	is($err, '', 'lifespan: "5 or 30d" passes global config validation')
		or diag "bail message was: $err";
};

subtest 'lifespan: "30d" -- pure duration' => sub {
	my $err = validate_lifespan('30d');
	is($err, '', 'lifespan: "30d" passes global config validation')
		or diag "bail message was: $err";
};

done_testing;
