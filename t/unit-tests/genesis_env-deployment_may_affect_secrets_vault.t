#!/usr/bin/env perl
# The gate that decides whether a deploy touches its own secrets vault.
#
# _pre_deploy fetches the unseal keys and records the vault's nodes only when
# this returns true, so a gate that misses a self-hosted vault switches off
# every unseal step after the deploy, and one that dies aborts the deploy
# before BOSH runs.  It used to pass every address through IPv4->address,
# which died on a hostname or IPv6 target and compared a range as its first
# address only.  These cases go through the gate itself.
use strict;
use warnings;
no warnings 'once';

use lib 't';
use lib 'lib';
use helper;

use Test::More;
use Test::Exception;

use_ok 'Genesis::Env';
use Genesis;

{
	package Test::GateVault;
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub url { $_[0]->{url} }
	sub initialized { 1 }
	sub query { return ($_[0]->{status_out} // '', 0, '') }
}
{
	package Test::GateKit;
	sub new { my ($c, @s) = @_; bless {services => {map {$_ => 1} @s}}, $c }
	sub provides_service { $_[0]->{services}{$_[1]} }
}

sub gate_for {
	my (%opts) = @_;
	my $env = bless {
		__vault => Test::GateVault->new(%{$opts{vault}}),
		__kit   => Test::GateKit->new(@{$opts{services} // ['vault']}),
		__igs   => $opts{instance_groups},
	}, 'Genesis::Env';
	my %dns = %{$opts{dns} // {}};
	no warnings 'redefine';
	local *Genesis::Env::vault  = sub { $_[0]->{__vault} };
	local *Genesis::Env::kit    = sub { $_[0]->{__kit} };
	local *Genesis::Env::lookup = sub { $opts{explicit} };
	local *Genesis::Env::manifest_lookup = sub { $_[0]->{__igs} };
	my $real_resolve = \&Genesis::Env::_resolve_host_addresses;
	local *Genesis::Env::_resolve_host_addresses = sub {
		my ($self, $host) = @_;
		return @{$dns{$host}} if $dns{$host};
		return $real_resolve->($self, $host) if defined(Genesis::Env::_canonical_ip($host));
		return ();
	};
	return $env->_deployment_may_affect_secrets_vault;
}

sub openbao { return [{name => 'openbao', instances => 3, networks => [{name => 'default', static_ips => [@_]}]}] }

is gate_for(
	vault => {url => 'https://10.0.0.5', status_out => "https://10.0.0.5 is unsealed\n"},
	instance_groups => openbao(qw/10.0.0.5 10.0.0.6 10.0.0.7/),
), 1, 'an IP target on one of the static IPs: the deploy touches its own vault';

my $rc;
lives_ok {
	$rc = gate_for(
		vault => {url => 'https://openbao.bosh', status_out => "https://openbao.bosh is unsealed\n"},
		dns => {'openbao.bosh' => ['10.0.0.6']},
		instance_groups => openbao(qw/10.0.0.5 10.0.0.6 10.0.0.7/),
	);
} 'a hostname target does not abort the deploy';
is $rc, 1, 'and is matched through the addresses it resolves to';

lives_ok {
	$rc = gate_for(
		vault => {url => 'https://[fd00::5]:8200', status_out => "https://[fd00::5]:8200 is unsealed\n"},
		instance_groups => openbao(qw/fd00:0::5 fd00::6 fd00::7/),
	);
} 'an IPv6 target does not abort the deploy';
is $rc, 1, 'and matches a static IP spelled differently';

is gate_for(
	vault => {url => 'https://10.0.0.6', status_out => "https://10.0.0.6 is unsealed\n"},
	instance_groups => openbao('10.0.0.5 - 10.0.0.7'),
), 1, 'a target in the middle of a static IP range is matched';

is gate_for(
	vault => {url => 'https://10.1.0.5', status_out => "https://10.1.0.5 is unsealed\n"},
	instance_groups => openbao(qw/10.0.0.5 10.0.0.6 10.0.0.7/),
), 0, 'a vault kit deploying some other vault: not self-hosted';

lives_ok {
	$rc = gate_for(
		vault => {url => 'https://nowhere.invalid', status_out => ''},
		instance_groups => openbao(qw/10.0.0.5 10.0.0.6 10.0.0.7/),
	);
} 'a hostname that does not resolve does not abort the deploy';
is $rc, 0, 'and is not taken for the deployment';

is gate_for(
	explicit => 0,
	vault => {url => 'https://10.0.0.5', status_out => "https://10.0.0.5 is unsealed\n"},
	instance_groups => openbao(qw/10.0.0.5 10.0.0.6 10.0.0.7/),
), 0, 'genesis.unseal_vault_after_deploy still overrides the check';

done_testing;
