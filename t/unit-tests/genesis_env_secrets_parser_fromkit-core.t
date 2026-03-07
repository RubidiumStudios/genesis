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

subtest 'FWT-684: path-level random/uuid produce specific error messages' => sub {
	my @secrets = parse_metadata({
		credentials => {
			base => {
				'test/random-path' => 'random 32',
				'test/uuid-path'   => 'uuid v4',
			},
		},
	});

	is(scalar @secrets, 2, "two invalid secrets returned");

	# Find the random one
	my ($random_inv) = grep { $_->path =~ /random-path/ } @secrets;
	isa_ok($random_inv, 'Genesis::Secret::Invalid');
	my $rdesc = $random_inv->describe;
	like($rdesc, qr/per key in a hashmap/i,
		"random path-level error gives specific guidance");
	unlike($rdesc, qr/Unrecognized request/,
		"random path-level error does NOT give generic message");

	# Find the uuid one
	my ($uuid_inv) = grep { $_->path =~ /uuid-path/ } @secrets;
	isa_ok($uuid_inv, 'Genesis::Secret::Invalid');
	my $udesc = $uuid_inv->describe;
	like($udesc, qr/per key in a hashmap/i,
		"uuid path-level error gives specific guidance");
	unlike($udesc, qr/Unrecognized request/,
		"uuid path-level error does NOT give generic message");
};

subtest 'FWT-683: bare ssh/rsa without size defaults to 2048' => sub {
	my @secrets = parse_metadata({
		credentials => {
			base => {
				'test/ssh-bare' => 'ssh',
				'test/rsa-bare' => 'rsa',
				'test/ssh-sized' => 'ssh 4096',
				'test/rsa-fixed' => 'rsa 1024 fixed',
			},
		},
	});

	is(scalar @secrets, 4, "four secrets returned");

	# Bare ssh → SSH with default size 2048
	my ($ssh_bare) = grep { $_->path eq 'test/ssh-bare' } @secrets;
	ok($ssh_bare->valid, "bare 'ssh' produces a valid secret");
	isa_ok($ssh_bare, 'Genesis::Secret::SSH');
	is($ssh_bare->get('size'), 2048, "bare 'ssh' defaults to size 2048");

	# Bare rsa → RSA with default size 2048
	my ($rsa_bare) = grep { $_->path eq 'test/rsa-bare' } @secrets;
	ok($rsa_bare->valid, "bare 'rsa' produces a valid secret");
	isa_ok($rsa_bare, 'Genesis::Secret::RSA');
	is($rsa_bare->get('size'), 2048, "bare 'rsa' defaults to size 2048");

	# ssh with explicit size still works
	my ($ssh_sized) = grep { $_->path eq 'test/ssh-sized' } @secrets;
	ok($ssh_sized->valid, "'ssh 4096' produces a valid secret");
	is($ssh_sized->get('size'), 4096, "'ssh 4096' has size 4096");

	# rsa with fixed flag still works
	my ($rsa_fixed) = grep { $_->path eq 'test/rsa-fixed' } @secrets;
	ok($rsa_fixed->valid, "'rsa 1024 fixed' produces a valid secret");
	is($rsa_fixed->get('size'), 1024, "'rsa 1024 fixed' has size 1024");
	is($rsa_fixed->get('fixed'), 1, "'rsa 1024 fixed' has fixed=1");
};

done_testing;
