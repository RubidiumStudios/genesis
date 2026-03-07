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

done_testing;
