#!/usr/bin/env perl
# Proves T487 for pipeline-apply's two writes to the secrets store: nothing is
# written after a read that failed (D157).
#
# The apply keeps the pipeline's webhook token, making one where there is
# none (D145), and copies each tracked director's credentials from its exodus
# record (D149).  Both read before they write: write if absent, and compare,
# then write.  A read the vault refused once passed for "no token" and "not
# copied", so a new token was written over the one in place and the
# credentials were copied again.
#
# Each row gives the apply a store that answers, holds nothing, or refuses,
# and reads off what was sent to it.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;

use Genesis;
use_ok 'Genesis::Commands::Pipelines';
require Genesis::CI::Compiler::PipelineDescriptor;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# A vault that holds secrets in memory, logs each call it is given, and
# raises as the strict readers do for a path it is told to refuse.
package StandInVault {
	sub new {
		my ($class, %opts) = @_;
		return bless {store => $opts{store} // {}, refuses => $opts{refuses} // {}, log => []}, $class;
	}
	sub status { 'ok' }
	sub _read {
		my ($self, $path) = @_;
		die "Could not read $path from vault at https://v:8200: Code: 403. permission denied\n"
			if $self->{refuses}{$path};
		return $self->{store}{$path};
	}
	sub has {
		my ($self, $path, $key) = @_;
		push @{$self->{log}}, ['has', $path];
		my $secret = $self->_read($path);
		return 0 unless $secret;
		return defined($key) ? (exists $secret->{$key} ? 1 : 0) : 1;
	}
	sub get {
		my ($self, $path, $key) = @_;
		push @{$self->{log}}, ['get', $path];
		my $secret = $self->_read($path);
		return defined($key) ? ($secret ? $secret->{$key} : undef) : ($secret // {});
	}
	sub set {
		my ($self, $path, %pairs) = @_;
		push @{$self->{log}}, ['set', $path];
		$self->{store}{$path} = {%{$self->{store}{$path} // {}}, %pairs};
		return \%pairs;
	}
	sub sets { scalar grep {$_->[0] eq 'set'} @{$_[0]{log}} }
}

# What the two stages ask of the repository.
package StandInTop {
	sub new { my ($class, %opts) = @_; return bless {%opts}, $class }
	sub pipeline_webhooks { 1 }
	sub pipeline_secrets_store { {path_prefix => '/concourse', team => 'main', pipeline => 'bosh'} }
	sub pipeline_secrets_vault { $_[0]{store_vault} }
	sub control_env { $_[0] }
	sub director_exodus { ('secret/exodus/lab-mgmt/bosh', $_[0]{exodus_vault}) }
}
package main;

my $TOKEN_PATH = '/concourse/main/bosh/webhook';

sub token_stage {
	my ($vault, %opts) = @_;
	my @answer;
	my $ok = eval { quietly { @answer = Genesis::Commands::Pipelines::_apply_webhook_token(
		StandInTop->new(store_vault => $vault), %opts) }; 1 };
	return ($ok ? undef : "$@", @answer);
}

subtest 'the webhook token is made where there is none, and kept where there is one' => sub {
	plan tests => 6;

	my $empty = StandInVault->new;
	my ($err, $made) = token_stage($empty);
	is($err, undef, 'with no token stored, the stage succeeds');
	like($made // '', qr/^[0-9a-f]{64}$/, 'and answers the token it made');
	is($empty->sets, 1, 'having written it once');

	my $kept = StandInVault->new(store => {$TOKEN_PATH => {token => 'in-place'}});
	($err, my $have) = token_stage($kept);
	is($err, undef, 'with a token stored, the stage succeeds');
	is($have, 'in-place', 'and answers the one in place');
	is($kept->sets, 0, 'writing nothing');
};

subtest 'a token that cannot be read is never taken for no token' => sub {
	plan tests => 4;
	for my $case (['a plain apply', ()], ['a rotation', rotate => 1]) {
		my ($what, %opts) = @$case;
		my $vault = StandInVault->new(
			store   => {$TOKEN_PATH => {token => 'in-place'}},
			refuses => {$TOKEN_PATH => 1},
		);
		my ($err) = token_stage($vault, %opts);
		like($err // '', qr{Could not read \Q$TOKEN_PATH\E.*Code: 403}s, "$what stops, with what the vault said");
		is($vault->sets, 0, "$what writes no token over the one it could not read");
	}
};

my $CRED_PATH   = '/concourse/main/bosh/bosh/lab-mgmt';
my $EXODUS_PATH = 'secret/exodus/lab-mgmt/bosh';
my %EXODUS = (url => 'https://10.0.0.6:25555', ca_cert => 'CA', admin_username => 'admin', admin_password => 'hunter2');
my %COPIED = (url => 'https://10.0.0.6:25555', ca_cert => 'CA', client => 'admin', client_secret => 'hunter2');

sub credentials_stage {
	my ($store_vault, $exodus_vault) = @_;
	no warnings 'redefine';
	local *Genesis::CI::Compiler::PipelineDescriptor::new = sub { bless {}, shift };
	local *Genesis::CI::Compiler::PipelineDescriptor::tracked_directors = sub { {'lab-mgmt' => ['qa']} };
	my $ok = eval { quietly { Genesis::Commands::Pipelines::_apply_director_credentials(
		StandInTop->new(store_vault => $store_vault, exodus_vault => $exodus_vault), undef) }; 1 };
	return $ok ? undef : "$@";
}

subtest "a director's credentials are copied where they are missing or differ, and left where they match" => sub {
	plan tests => 6;
	my $exodus = sub { StandInVault->new(store => {$EXODUS_PATH => {%EXODUS}}) };

	my $missing = StandInVault->new;
	is(credentials_stage($missing, $exodus->()), undef, 'with nothing in the store, the stage succeeds');
	is_deeply($missing->{store}{$CRED_PATH}, \%COPIED, 'and copies the four keys the check reads');

	my $differs = StandInVault->new(store => {$CRED_PATH => {%COPIED, client_secret => 'old'}});
	is(credentials_stage($differs, $exodus->()), undef, 'with an older copy in the store, the stage succeeds');
	is($differs->{store}{$CRED_PATH}{client_secret}, 'hunter2', 'and updates it');

	my $matches = StandInVault->new(store => {$CRED_PATH => {%COPIED}});
	is(credentials_stage($matches, $exodus->()), undef, 'with a matching copy in the store, the stage succeeds');
	is($matches->sets, 0, 'and writes nothing');
};

subtest 'a copy that cannot be read is never taken for no copy' => sub {
	plan tests => 4;

	my $store = StandInVault->new(store => {$CRED_PATH => {%COPIED}}, refuses => {$CRED_PATH => 1});
	like(credentials_stage($store, StandInVault->new(store => {$EXODUS_PATH => {%EXODUS}})) // '',
		qr{Could not read \Q$CRED_PATH\E.*Code: 403}s,
		'a copy the store will not give stops the stage, with what the vault said');
	is($store->sets, 0, 'and nothing is copied over it');

	$store = StandInVault->new;
	like(credentials_stage($store, StandInVault->new(
			store => {$EXODUS_PATH => {%EXODUS}}, refuses => {$EXODUS_PATH => 1})) // '',
		qr{Could not read \Q$EXODUS_PATH\E.*Code: 403}s,
		"a director's exodus record that will not read stops the stage too");
	is($store->sets, 0, 'and nothing is copied from a record nobody read');
};

done_testing;
