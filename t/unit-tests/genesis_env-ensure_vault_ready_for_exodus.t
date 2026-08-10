#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use lib 'lib';
use helper;

use Test::More;
use Test::Exception;
use Test::Output;

use_ok 'Genesis::Env';
use Genesis;

# A fake vault that reports a scripted sequence of statuses and counts
# unseal attempts.  status() shifts the next entry off the sequence so a
# test can model "sealed, then ok after unseal" or "sealed even after
# unseal".
{
	package Test::FakeVault;
	sub new {
		my ($class, %opts) = @_;
		bless {
			statuses  => $opts{statuses} || ['ok'],
			unseal_rc => $opts{unseal_rc} // 0,
			unseals   => 0,
		}, $class;
	}
	sub status {
		my ($self) = @_;
		return @{$self->{statuses}} > 1
			? shift @{$self->{statuses}}
			: $self->{statuses}[0];
	}
	sub unseal {
		my ($self) = @_;
		$self->{unseals}++;
		return ('unseal output', $self->{unseal_rc}, 'unseal error');
	}
	sub unseals { $_[0]->{unseals} }
}

# ===========================================================================
# Genesis::Env::_ensure_vault_ready_for_exodus
#
# After a successful deploy, the exodus update needs a reachable,
# unsealed, authenticated vault.  When the vault is its own deployment's
# colocated provider (BOSH kit openbao feature), a create-env recreate
# brings it back sealed, and the downstream safe call would block forever
# on an interactive vault-auth prompt in non-interactive runs.
#
# Contract:
#   - status 'ok': returns 1, never attempts an unseal.
#   - status 'sealed': attempts exactly one unseal; if the vault comes
#     back 'ok', returns 1.
#   - still not 'ok' with no controlling terminal (or --yes): bails with
#     guidance to unseal and re-run the deploy, instead of proceeding
#     into an interactive prompt.
#   - still not 'ok' but interactive: returns 0 (warn and proceed, so the
#     operator can answer the auth prompt).
# ===========================================================================

sub make_env_stub {
	my (%opts) = @_;
	my $env = bless { __vault => $opts{vault} }, 'Genesis::Env';
	return $env;
}

sub with_env_stubs (&) {
	my ($block) = @_;
	no warnings 'redefine', 'once';
	local *Genesis::Env::vault  = sub { $_[0]->{__vault} };
	local *Genesis::Env::notify = sub { };
	$block->();
}

sub with_terminal (&) {
	my ($block) = @_;
	no warnings 'redefine', 'once';
	local *Genesis::Env::in_controlling_terminal = sub { 1 };
	$block->();
}

sub without_terminal (&) {
	my ($block) = @_;
	no warnings 'redefine', 'once';
	local *Genesis::Env::in_controlling_terminal = sub { 0 };
	$block->();
}

with_env_stubs {

	# --- healthy vault -------------------------------------------------------
	without_terminal {
		my $vault = Test::FakeVault->new(statuses => ['ok']);
		my $env = make_env_stub(vault => $vault);
		is $env->_ensure_vault_ready_for_exodus(0), 1,
			'ok vault: ready for exodus';
		is $vault->unseals, 0, 'ok vault: no unseal attempted';
	};

	# --- sealed, unseal recovers --------------------------------------------
	without_terminal {
		my $vault = Test::FakeVault->new(
			statuses => ['sealed', 'ok'], unseal_rc => 0,
		);
		my $env = make_env_stub(vault => $vault);
		my $rc;
		my ($out, $err) = output_from {
			$rc = $env->_ensure_vault_ready_for_exodus(1);
		};
		is $rc, 1,
			'sealed vault that unseals cleanly: ready for exodus';
		like $err, qr/unsealed\s+successfully/i,
			'says so on stderr rather than recovering silently';
		is $out, '', 'nothing on stdout';
		is $vault->unseals, 1, 'exactly one unseal attempt';
	};

	# --- sealed, unseal fails, non-interactive: must fail fast ---------------
	without_terminal {
		my $vault = Test::FakeVault->new(
			statuses => ['sealed'], unseal_rc => 1,
		);
		my $env = make_env_stub(vault => $vault);
		my ($out, $err) = output_from {
			throws_ok { $env->_ensure_vault_ready_for_exodus(0) }
				qr/re-run this deploy/i,
				'sealed vault, no terminal: bails with re-run guidance';
		};
		like $err, qr/failed\s+to\s+unseal/i,
			'reports the unseal failure on stderr before bailing';
		is $out, '', 'nothing on stdout';
		is $vault->unseals, 1, 'unseal was still attempted first';
	};

	# --- unreachable vault, --yes given: must fail fast ----------------------
	with_terminal {
		my $vault = Test::FakeVault->new(
			statuses => ['unreachable - connection refused'],
		);
		my $env = make_env_stub(vault => $vault);
		throws_ok { $env->_ensure_vault_ready_for_exodus(1) }
			qr/unreachable/,
			'unreachable vault with --yes: bails naming the status';
		is $vault->unseals, 0, 'no unseal attempted when not sealed';
	};

	# --- sealed, unseal fails, interactive: warn and proceed -----------------
	with_terminal {
		my $vault = Test::FakeVault->new(
			statuses => ['sealed'], unseal_rc => 1,
		);
		my $env = make_env_stub(vault => $vault);
		my $rc;
		my ($out, $err) = output_from {
			lives_ok { $rc = $env->_ensure_vault_ready_for_exodus(0) }
				'sealed vault with a terminal: proceeds to the auth prompt';
		};
		is $rc, 0, 'returns 0 so the caller knows the vault is not ready';
		like $err, qr/failed\s+to\s+unseal/i,
			'the operator is told on stderr that the unseal failed';
		like $err, qr/may\s+fail\s+due\s+to\s+sealed\s+vault/i,
			'and what that means for the exodus write';
		is $out, '', 'nothing on stdout';
	};
};

done_testing;
