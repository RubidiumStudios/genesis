#!/usr/bin/env perl
# Characterises what a deploy records as read when Genesis itself looks up
# where the environment's CredHub is.
#
# CredHub's connection details live in the exodus record of the director
# that deploys the environment.  The environment names that director with
# genesis.bosh_env, or leaves it to default to its own name.  The set a
# deploy records as read is compared against the set pipeline-apply
# compiled, and where they differ the pipeline is called stale.
#
# The two ways of naming the director reached the record by different
# reads, and only one of them counted as a dependency read.  An environment
# whose director defaulted recorded its director on every deploy, which the
# apply never compiles, so it was called stale after every deploy and no
# apply could clear it.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use Service::Vault;
use_ok 'Genesis::Env';

$ENV{NOCOLOR} = 1;

# CredhubEnv - what credhub_connection_env asks of an environment.  It is its
# own vault, and answers the director's record whichever way it is read.
{
	package CredhubEnv;
	our @ISA = ('Genesis::Env');
	sub new { my ($class, %opts) = @_; return bless {%opts}, $class }
	sub name            { 'qa' }
	sub type            { 'doomsday' }
	sub deployment_slug { 'qa/doomsday' }
	sub exodus_mount    { '/secret/exodus/' }
	sub secrets_mount   { '/secret/' }
	sub lookup {
		my ($self, $keys) = @_;
		for my $key (@$keys) {
			return ($self->{keys}{$key}, $key) if exists $self->{keys}{$key};
		}
		return (undef, undef);
	}
	my %DIRECTOR = (credhub_url => 'https://credhub', credhub_username => 'u', credhub_password => 'p');
	sub vault                 { $_[0] }
	sub get                   { push @{$_[0]{reads}}, $_[1]; return {%DIRECTOR} }
	sub read_flattened_secret { push @{$_[0]{reads}}, $_[1]; return {%DIRECTOR} }
}

sub connecting {
	my (%keys) = @_;
	my $env = CredhubEnv->new(keys => {'genesis.env' => 'qa', %keys});
	my %conn = $env->credhub_connection_env;
	return ($env, \%conn);
}

subtest 'either way of naming the director finds CredHub in its exodus record' => sub {
	plan tests => 4;
	my ($named, $conn) = connecting('genesis.bosh_env' => 'qa');
	is($conn->{CREDHUB_SERVER}, 'https://credhub', 'a director named by genesis.bosh_env is found');
	is_deeply($named->{reads}, ['/secret/exodus/qa/bosh'], 'in its exodus record');

	(my $defaulted, $conn) = connecting();
	is($conn->{CREDHUB_SERVER}, 'https://credhub', 'and so is one left to default to the environment\'s own name');
	is_deeply($defaulted->{reads}, ['/secret/exodus/qa/bosh'], 'in the same record');
};

subtest 'and both record the same set as read' => sub {
	plan tests => 3;
	my ($named)     = connecting('genesis.bosh_env' => 'qa');
	my ($defaulted) = connecting();
	is_deeply($defaulted->dependencies_read, $named->dependencies_read,
		'the deploy records the same reads whichever way its director is named')
		or diag(sprintf("named by genesis.bosh_env: [%s]; defaulted: [%s]",
			join(', ', @{$named->dependencies_read}), join(', ', @{$defaulted->dependencies_read})));

	# Ruled 2026-11-18: Genesis's own lookup of where CredHub is counts as
	# no dependency of the deployment's.  genesis.bosh_env and the director
	# lock already say which director an environment deploys through.
	is_deeply($defaulted->dependencies_read, [], 'which is none, for this lookup is Genesis\'s own');

	my ($elsewhere) = connecting('genesis.credhub_env' => 'ops/bosh');
	is_deeply($elsewhere->dependencies_read, [],
		'and none where genesis.credhub_env names another environment\'s CredHub');
};

subtest 'a record that cannot be read stops the lookup, as the reader raised it' => sub {
	plan tests => 3;
	no warnings 'redefine';
	local *CredhubEnv::read_flattened_secret = sub {
		Service::Vault::bail_read_failure(
			'https://v:8200', $_[1], 'permission denied', "get $_[1]");
	};
	local $SIG{__DIE__} = 'DEFAULT';
	for my $how (['named', 'genesis.bosh_env' => 'qa'], ['defaulted']) {
		my ($which, @keys) = @$how;
		eval { connecting(@keys) };
		my $raised = raised($@);
		is($raised && $raised->state, 'refused', "$which: the reader's refusal comes through, with its cause");
	}
	eval { connecting() };
	like("$@", qr/Could not get qa\/bosh exodus data from the Vault:.*Could not read \/secret\/exodus\/qa\/bosh from vault/s,
		'under words that say which record was being read');
};

done_testing;
