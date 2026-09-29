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
			node_states => $opts{node_states} || {},
			active      => $opts{active},
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

	# The per-node path.  node_states maps each address to what
	# unseal_nodes reports for it; active is what wait_for_active_node
	# returns once the cluster has a leader, or undef when it never does.
	sub unseal_nodes {
		my ($self, @addresses) = @_;
		push @{$self->{node_unseals}}, [@addresses];
		return map {
			my $state = $self->{node_states}{$_} // 'unsealed';
			{address => $_, unsealed => ($state =~ /unsealed$/ ? 1 : 0), message => $state}
		} @addresses;
	}
	sub wait_for_active_node {
		my ($self, $timeout, @addresses) = @_;
		push @{$self->{waits}}, [$timeout, @addresses];
		return $self->{active};
	}
	sub node_unseals { $_[0]->{node_unseals} // [] }
	sub waits { $_[0]->{waits} // [] }
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
	$env->{deployment_state}{secrets_vault_nodes} = $opts{nodes} if $opts{nodes};
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

	# --- self-hosted cluster: every node, then a leader ----------------------
	#
	# The deploying vault is this deployment, a three-node Raft cluster, and
	# the rolling update left every node sealed.  A lone unsealed node cannot
	# elect a leader, so the single-target unseal is not used at all.
	without_terminal {
		my @nodes = qw/10.0.0.5 10.0.0.6 10.0.0.7/;
		my $vault = Test::FakeVault->new(
			statuses => ['sealed', 'ok'], active => '10.0.0.6',
		);
		my $env = make_env_stub(vault => $vault, nodes => [@nodes]);
		my $rc;
		my ($out, $err) = output_from {
			$rc = $env->_ensure_vault_ready_for_exodus(1);
		};
		is $rc, 1, 'sealed cluster under --yes: ready for exodus';
		is $vault->unseals, 0, 'the single-target unseal is never used on a cluster';
		is_deeply $vault->node_unseals, [[@nodes]],
			'every node of the cluster is unsealed, in one pass';
		is scalar(@{$vault->waits}), 1, 'then it waits for a leader';
		is_deeply [@{$vault->waits->[0]}[1..3]], [@nodes],
			'asking every node which one is active';
		like $vault->waits->[0][0], qr/^[0-9]+$/, 'and the wait is bounded';
		like $err, qr/10\.0\.0\.6.*active/i, 'the operator is told which node leads';
		is $out, '', 'nothing on stdout';
	};

	# --- the wait bound comes from GENESIS_VAULT_LEADER_WAIT -----------------
	without_terminal {
		local $ENV{GENESIS_VAULT_LEADER_WAIT} = 17;
		my $vault = Test::FakeVault->new(statuses => ['sealed', 'ok'], active => '10.0.0.5');
		my $env = make_env_stub(vault => $vault, nodes => [qw/10.0.0.5 10.0.0.6 10.0.0.7/]);
		output_from { $env->_ensure_vault_ready_for_exodus(1) };
		is $vault->waits->[0][0], 17, 'GENESIS_VAULT_LEADER_WAIT sets the bound';
	};

	# --- quorum open but no leader in time: fail, but only after waiting -----
	without_terminal {
		my $vault = Test::FakeVault->new(statuses => ['sealed', 'unauthenticated']);
		my $env = make_env_stub(vault => $vault, nodes => [qw/10.0.0.5 10.0.0.6 10.0.0.7/]);
		my ($out, $err) = output_from {
			throws_ok { $env->_ensure_vault_ready_for_exodus(1) }
				qr/re-run this deploy/i,
				'no leader within the bound, under --yes: bails with re-run guidance';
		};
		is scalar(@{$vault->waits}), 1, 'but only after waiting for a leader';
		like $err, qr/no active node/i, 'and says that no leader emerged';
	};

	# --- no quorum: waiting cannot help, so it does not wait -----------------
	without_terminal {
		my $vault = Test::FakeVault->new(
			statuses => ['sealed'],
			node_states => {
				'10.0.0.6' => 'unreachable',
				'10.0.0.7' => 'still sealed after every unseal key was tried',
			},
		);
		my $env = make_env_stub(vault => $vault, nodes => [qw/10.0.0.5 10.0.0.6 10.0.0.7/]);
		my ($out, $err) = output_from {
			throws_ok { $env->_ensure_vault_ready_for_exodus(1) }
				qr/re-run this deploy/i,
				'one of three nodes open, under --yes: bails';
		};
		is scalar(@{$vault->waits}), 0, 'without a futile wait for a leader that cannot be elected';
		like $err, qr/10\.0\.0\.6.*unreachable/, 'naming each node that is still closed';
		like $err, qr/1 of 3/, 'and how far short of a quorum the cluster is';
	};

	# --- a cluster that is unsealed but unauthenticated ----------------------
	#
	# The cluster is not sealed at all, and the token is the problem.  The per-node check costs
	# one status call per node, finds nothing to do, and the interactive
	# fallback is unchanged.
	with_terminal {
		my $vault = Test::FakeVault->new(
			statuses => ['unauthenticated'], active => '10.0.0.5',
			node_states => {map {$_ => 'already unsealed'} qw/10.0.0.5 10.0.0.6 10.0.0.7/},
		);
		my $env = make_env_stub(vault => $vault, nodes => [qw/10.0.0.5 10.0.0.6 10.0.0.7/]);
		my $rc;
		output_from { $rc = $env->_ensure_vault_ready_for_exodus(0) };
		is $rc, 0, 'unauthenticated cluster with a terminal: proceeds to the auth prompt';
		is $vault->unseals, 0, 'no single-target unseal';
	};

	# --- single-node vault: exactly the old path ------------------------------
	without_terminal {
		my $vault = Test::FakeVault->new(statuses => ['sealed', 'ok'], unseal_rc => 0);
		my $env = make_env_stub(vault => $vault, nodes => ['10.0.0.5']);
		my $rc;
		output_from { $rc = $env->_ensure_vault_ready_for_exodus(1) };
		is $rc, 1, 'single-node self-hosted vault: ready for exodus';
		is $vault->unseals, 1, 'through the single-target unseal, as before';
		is_deeply $vault->node_unseals, [], 'with no per-node pass';
		is_deeply $vault->waits, [], 'and no leader wait';
	};
};

# ===========================================================================
# Genesis::Env::_secrets_vault_cluster_ips
#
# Read in _pre_deploy while the vault still answers.  The cluster is every
# static IP of each instance group that shares an address with the vault
# being used for secrets; anything else in the manifest is left out.
# ===========================================================================
{
	package Test::FakeStatusVault;
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub url { $_[0]->{url} }
	sub query { return ($_[0]->{status_out} // '', 0, '') }
}
{
	package Test::FakeKit;
	sub new { my ($c, @s) = @_; bless {services => {map {$_ => 1} @s}}, $c }
	sub provides_service { $_[0]->{services}{$_[1]} }
}

sub cluster_ips_for {
	my (%opts) = @_;
	my $env = bless {
		__vault => Test::FakeStatusVault->new(%{$opts{vault}}),
		__kit   => Test::FakeKit->new(@{$opts{services} // ['vault']}),
		__igs   => $opts{instance_groups},
	}, 'Genesis::Env';
	no warnings 'redefine', 'once';
	local *Genesis::Env::vault = sub { $_[0]->{__vault} };
	local *Genesis::Env::kit   = sub { $_[0]->{__kit} };
	local *Genesis::Env::manifest_lookup = sub { $_[0]->{__igs} };
	return [$env->_secrets_vault_cluster_ips];
}

my $openbao_igs = [
	{name => 'openbao', networks => [{name => 'default', static_ips => [qw/10.0.0.5 10.0.0.6 10.0.0.7/]}]},
	{name => 'smoke',   networks => [{name => 'default', static_ips => ['10.0.0.9']}]},
];

is_deeply cluster_ips_for(
	vault => {url => 'https://10.0.0.5', status_out => "https://10.0.0.5 is unsealed\n"},
	instance_groups => $openbao_igs,
), [qw/10.0.0.5 10.0.0.6 10.0.0.7/],
	'the instance group holding the vault address is the cluster, and nothing else is';

is_deeply cluster_ips_for(
	vault => {url => 'https://10.0.0.6:8200', status_out => ''},
	instance_groups => $openbao_igs,
), [qw/10.0.0.5 10.0.0.6 10.0.0.7/],
	'the target address alone identifies the cluster when safe status is silent';

is_deeply cluster_ips_for(
	vault => {url => 'https://10.1.0.5', status_out => "https://10.1.0.5 is unsealed\n"},
	instance_groups => $openbao_igs,
), [], 'a vault kit deploying some other vault: no cluster';

is_deeply cluster_ips_for(
	services => [],
	vault => {url => 'https://10.0.0.5', status_out => "https://10.0.0.5 is unsealed\n"},
	instance_groups => $openbao_igs,
), [], 'a kit that does not provide vault: no cluster';

done_testing;
