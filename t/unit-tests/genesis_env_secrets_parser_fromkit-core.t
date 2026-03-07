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

subtest 'FWT-685: unrecognized credential key uses correct subject label' => sub {
	my @secrets = parse_metadata({
		credentials => {
			base => {
				'test/path' => {
					mykey => 'bogus_value',
				},
			},
		},
	});

	is(scalar @secrets, 1, "one secret returned");
	isa_ok($secrets[0], 'Genesis::Secret::Invalid');
	is($secrets[0]->get('subject'), 'Credential',
		"subject is 'Credential', not 'Random'");

	my $desc = $secrets[0]->describe;
	like($desc, qr/Unrecognized credential format/i,
		"error message says 'Unrecognized credential format'");
	unlike($desc, qr/Bad generate-password/,
		"error message does NOT say 'Bad generate-password'");
};

subtest 'FWT-682: parse_provided does not mutate caller metadata' => sub {
	my $metadata = {
		provided => {
			base => {
				'test/path' => {
					keys => {
						username => { prompt => 'Enter username' },
					},
				},
			},
		},
	};

	# Capture state before parse
	ok(!exists $metadata->{provided}{base}{'test/path'}{type},
		"type key does not exist before parse");

	my @secrets = parse_metadata($metadata);

	# After parse, the original metadata should be unmodified
	ok(!exists $metadata->{provided}{base}{'test/path'}{type},
		"type key still does not exist after parse — no mutation");

	# The parse should still work correctly
	is(scalar @secrets, 1, "one secret produced");
	ok($secrets[0]->valid, "secret is valid");
	isa_ok($secrets[0], 'Genesis::Secret::UserProvided');
};

done_testing;
