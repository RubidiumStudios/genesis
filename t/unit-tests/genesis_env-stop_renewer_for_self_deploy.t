#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use lib 'lib';
use helper;

use Test::More;
use Test::Exception;

use_ok 'Genesis::Env';
use Genesis;

# A fake vault class that responds to stop_token_renewer.  The Env
# helper uses can('stop_token_renewer'), not an isa-check, so any
# class with the method satisfies the contract.  We keep this local
# to the test file to avoid redefining the real
# Service::Vault::Remote::stop_token_renewer (which Carp::Always
# would otherwise dump a stack trace for).
{
	package Test::FakeRenewableVault;
	sub new { bless { stops => 0 }, shift }
	sub stop_token_renewer { $_[0]->{stops}++ }
	sub stops { $_[0]->{stops} }
}

# A fake non-renewable vault, modelling Service::Vault::Local (no
# stop_token_renewer method).  The helper's can() check must
# short-circuit on this.
{
	package Test::FakeLocalVault;
	sub new { bless {}, shift }
}

# ===========================================================================
# Genesis::Env::_stop_renewer_for_self_deploy
#
# When _pre_deploy detects we are about to deploy a vault kit that
# overlaps with our secrets vault, stop the background token renewer.
# The renewer would otherwise issue spurious `vault token renew` calls
# against a half-deployed vault.
#
# After the deploy returns (success or failure), the next vault method
# that calls authenticate() will re-arm the renewer naturally via
# Service::Vault::Remote::_on_auth_success.  No explicit re-arm is the
# responsibility of this helper.
#
# Contract:
#   - Calls _deployment_may_affect_secrets_vault() to decide.
#   - When truthy AND the vault supports stop_token_renewer, calls it.
#   - When non-self-deploy, leaves the vault alone.
#   - When self-deploy but the vault does not respond to
#     stop_token_renewer (e.g. Service::Vault::Local, plain Mock),
#     no-op without dying — defensive can() check.
#   - Returns 1 when it stopped a renewer, 0 / undef otherwise.
# ===========================================================================

# Build a minimal env object that exposes vault() and
# _deployment_may_affect_secrets_vault(), bypassing all the YAML / kit
# / manifest plumbing that the real Env::new() requires.
sub make_env_stub {
	my (%opts) = @_;
	my $env = bless { __vault => $opts{vault} }, 'Genesis::Env';
	$env->{__is_self_deploy} = $opts{is_self_deploy} // 0;
	return $env;
}

# Per-test local overrides for the two methods we need to control.
sub with_env_stubs (&) {
	my ($block) = @_;
	no warnings 'redefine', 'once';
	local *Genesis::Env::vault =
		sub { $_[0]->{__vault} };
	local *Genesis::Env::_deployment_may_affect_secrets_vault =
		sub { $_[0]->{__is_self_deploy} };
	$block->();
}

# ---------- self-deploy detected, vault supports the method ----------

subtest 'stops the renewer when self-deploy is detected on a renewable vault' => sub {
	plan tests => 2;
	my $vault = Test::FakeRenewableVault->new;
	with_env_stubs {
		my $env = make_env_stub(vault => $vault, is_self_deploy => 1);
		my $ret = $env->_stop_renewer_for_self_deploy;
		is($vault->stops, 1, 'stop_token_renewer was invoked');
		ok($ret, 'returns truthy when a stop happened');
	};
};

# ---------- not a self-deploy ----------

subtest 'does not touch the renewer when not a self-deploy' => sub {
	plan tests => 2;
	my $vault = Test::FakeRenewableVault->new;
	with_env_stubs {
		my $env = make_env_stub(vault => $vault, is_self_deploy => 0);
		my $ret = $env->_stop_renewer_for_self_deploy;
		is($vault->stops, 0, 'stop_token_renewer was NOT invoked');
		ok(!$ret, 'returns falsy when no stop happened');
	};
};

# ---------- defensive: vault does not respond to stop_token_renewer ----------

subtest 'no-ops when vault does not respond to stop_token_renewer' => sub {
	plan tests => 1;
	# A vault without stop_token_renewer (Service::Vault::Local, bare
	# Mock, etc.) must not crash _stop_renewer_for_self_deploy.
	my $vault = Test::FakeLocalVault->new;
	with_env_stubs {
		my $env = make_env_stub(vault => $vault, is_self_deploy => 1);
		lives_ok { $env->_stop_renewer_for_self_deploy }
			'no crash when vault lacks stop_token_renewer';
	};
};

# ---------- defensive: undef vault ----------

subtest 'no-ops when the env has no vault at all' => sub {
	plan tests => 1;
	with_env_stubs {
		my $env = make_env_stub(vault => undef, is_self_deploy => 1);
		lives_ok { $env->_stop_renewer_for_self_deploy }
			'no crash with undef vault';
	};
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
