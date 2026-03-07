#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Deep;

# Test Genesis::Env::Secrets::Parser::FromKit
# Validates parsing of kit metadata into Genesis::Secret objects

use_ok 'Genesis::Env::Secrets::Parser::FromKit';
use_ok 'Genesis::Secret::Invalid';

# Minimal mock environment — provides features() and dereferenced_kit_metadata()
{
	package MockEnv;
	sub new {
		my ($class, %opts) = @_;
		bless {
			features => $opts{features} || [],
			metadata => $opts{metadata} || {},
		}, $class;
	}
	sub features { @{$_[0]{features}} }
	sub dereferenced_kit_metadata { $_[0]{metadata} }
}

# Helper: parse metadata with features, return list of secrets
sub parse_metadata {
	my ($metadata, @features) = @_;
	my $parser = Genesis::Env::Secrets::Parser::FromKit->new(undef);
	return $parser->parse(
		kit_metadata => $metadata,
		features     => \@features,
	);
}

# Helper: parse and return only Invalid secrets
sub parse_invalid {
	my ($metadata, @features) = @_;
	return grep { $_->isa('Genesis::Secret::Invalid') } parse_metadata($metadata, @features);
}

subtest 'FWT-687: features defaulting does not have dead code' => sub {
	# This is a code-review regression test — verify parse() works
	# with a mock environment that returns an empty features list
	my $env = MockEnv->new(
		features => [],
		metadata => {
			credentials => {
				base => {
					'test/path' => 'ssh 2048',
				},
			},
		},
	);
	my $parser = Genesis::Env::Secrets::Parser::FromKit->new($env);
	my @secrets = $parser->parse();
	is(scalar @secrets, 1, "parse() works with empty features list from env");
	ok($secrets[0]->valid, "produced secret is valid");
};

done_testing;
