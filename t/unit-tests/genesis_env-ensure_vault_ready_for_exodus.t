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
			strongbox   => $opts{strongbox},
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

	sub strongbox { $_[0]->{strongbox} }

	# The cluster path.  node_states maps each address to what the cluster
	# pass reports for it; active is the leader it found, or undef when none
	# emerged.  The quorum is a majority, as Service::Vault computes it.
	sub unseal_cluster {
		my ($self, $timeout, @nodes) = @_;
		push @{$self->{cluster_unseals}}, [$timeout, @nodes];
		my @results = map {
			my $state = $self->{node_states}{$_} // 'unsealed';
			{address => $_, unsealed => ($state =~ /unsealed$/ ? 1 : 0), message => $state}
		} @nodes;
		my $open = grep {$_->{unsealed}} @results;
		my $quorum = int(@nodes / 2) + 1;
		return {
			nodes  => \@results,
			active => $open >= $quorum ? $self->{active} : undef,
			open   => $open,
			quorum => $quorum,
		};
	}
	sub cluster_unseals { $_[0]->{cluster_unseals} // [] }
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
	my @nodes = qw/10.0.0.5:443 10.0.0.6:443 10.0.0.7:443/;
	without_terminal {
		my $vault = Test::FakeVault->new(
			statuses => ['sealed', 'ok'], active => '10.0.0.6:443',
		);
		my $env = make_env_stub(vault => $vault, nodes => [@nodes]);
		my $rc;
		my ($out, $err) = output_from {
			$rc = $env->_ensure_vault_ready_for_exodus(1);
		};
		is $rc, 1, 'sealed cluster under --yes: ready for exodus';
		is $vault->unseals, 0, 'the single-target unseal is never used on a cluster';
		is scalar(@{$vault->cluster_unseals}), 1, 'the cluster is unsealed in one call';
		is_deeply [@{$vault->cluster_unseals->[0]}[1..3]], [@nodes],
			'covering every node of the cluster';
		is $vault->cluster_unseals->[0][0], 90, 'within the default 90-second bound';
		like $err, qr/10\.0\.0\.6:443 is the active node/i, 'the operator is told which node leads';
		is $out, '', 'nothing on stdout';
	};

	# --- the bound comes from GENESIS_VAULT_LEADER_WAIT ----------------------
	without_terminal {
		local $ENV{GENESIS_VAULT_LEADER_WAIT} = 17;
		my $vault = Test::FakeVault->new(statuses => ['sealed', 'ok'], active => '10.0.0.5:443');
		my $env = make_env_stub(vault => $vault, nodes => [@nodes]);
		output_from { $env->_ensure_vault_ready_for_exodus(1) };
		is $vault->cluster_unseals->[0][0], 17, 'GENESIS_VAULT_LEADER_WAIT sets the bound';
	};

	# --- quorum open but no leader in time -----------------------------------
	without_terminal {
		my $vault = Test::FakeVault->new(statuses => ['sealed', 'unauthenticated']);
		my $env = make_env_stub(vault => $vault, nodes => [@nodes]);
		my ($out, $err) = output_from {
			throws_ok { $env->_ensure_vault_ready_for_exodus(1) }
				qr/re-run this deploy/i,
				'no leader within the bound, under --yes: bails with re-run guidance';
		};
		like $err, qr/no active node emerged within 90s, although 3 of 3/i,
			'and says that no leader emerged';
	};

	# --- no quorum -----------------------------------------------------------
	without_terminal {
		my $vault = Test::FakeVault->new(
			statuses => ['sealed'],
			node_states => {
				'10.0.0.6:443' => 'unreachable',
				'10.0.0.7:443' => 'still sealed after every combination of unseal keys was tried',
			},
		);
		my $env = make_env_stub(vault => $vault, nodes => [@nodes]);
		my ($out, $err) = output_from {
			throws_ok { $env->_ensure_vault_ready_for_exodus(1) }
				qr/re-run this deploy/i,
				'one of three nodes open, under --yes: bails';
		};
		like $err, qr/10\.0\.0\.6:443: unreachable/, 'naming each node that is still closed';
		like $err, qr/1 of 3 .*short of the 2/, 'and how far short of a quorum the cluster is';
	};

	# --- Strongbox on: safe unseal walks the cluster, as it did before -------
	without_terminal {
		my $vault = Test::FakeVault->new(
			statuses => ['sealed', 'ok'], unseal_rc => 0, strongbox => 1,
		);
		my $env = make_env_stub(vault => $vault, nodes => [@nodes]);
		my $rc;
		output_from { $rc = $env->_ensure_vault_ready_for_exodus(1) };
		is $rc, 1, 'Strongbox cluster that safe unseals: ready for exodus';
		is $vault->unseals, 1, 'through the single safe unseal, which walks every node';
		is_deeply $vault->cluster_unseals, [], 'with no cluster pass needed';
	};

	# --- Strongbox on, but no leader yet after safe unseal -------------------
	without_terminal {
		my $vault = Test::FakeVault->new(
			statuses => ['sealed', 'unauthenticated', 'ok'], unseal_rc => 0,
			strongbox => 1, active => '10.0.0.7:443',
		);
		my $env = make_env_stub(vault => $vault, nodes => [@nodes]);
		my $rc;
		output_from { $rc = $env->_ensure_vault_ready_for_exodus(1) };
		is $rc, 1, 'Strongbox cluster still electing a leader: ready for exodus';
		is $vault->unseals, 1, 'safe unseal goes first';
		is scalar(@{$vault->cluster_unseals}), 1, 'and the cluster pass waits for the leader';
	};

	# --- a cluster that is unsealed but unauthenticated ----------------------
	#
	# The cluster is not sealed at all, and the token is the problem.  The
	# cluster pass finds nothing to do, and the interactive fallback is
	# unchanged.
	with_terminal {
		my $vault = Test::FakeVault->new(
			statuses => ['unauthenticated'], active => '10.0.0.5:443',
			node_states => {map {$_ => 'already unsealed'} @nodes},
		);
		my $env = make_env_stub(vault => $vault, nodes => [@nodes]);
		my $rc;
		output_from { $rc = $env->_ensure_vault_ready_for_exodus(0) };
		is $rc, 0, 'unauthenticated cluster with a terminal: proceeds to the auth prompt';
		is $vault->unseals, 0, 'no single-target unseal';
	};

	# --- single-node vault: exactly the old path ------------------------------
	without_terminal {
		my $vault = Test::FakeVault->new(statuses => ['sealed', 'ok'], unseal_rc => 0);
		my $env = make_env_stub(vault => $vault, nodes => ['10.0.0.5:443']);
		my $rc;
		output_from { $rc = $env->_ensure_vault_ready_for_exodus(1) };
		is $rc, 1, 'single-node self-hosted vault: ready for exodus';
		is $vault->unseals, 1, 'through the single-target unseal, as before';
		is_deeply $vault->cluster_unseals, [], 'with no cluster pass';
	};
};

# ===========================================================================
# Genesis::Env::_secrets_vault_cluster_nodes
#
# Read in _pre_deploy while the vault still answers.  The cluster is the
# static IPs on the network that carries one of the vault's addresses, one
# node per instance, each with the port the vault answers on there.
# Anything else in the manifest is left out, and a manifest that plainly
# holds a cluster Genesis cannot find is reported loudly.
# ===========================================================================
{
	package Test::FakeStatusVault;
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub url { $_[0]->{url} }
	sub query { return ($_[0]->{status_out} // '', $_[0]->{status_rc} // 0, '') }
}
{
	package Test::FakeKit;
	sub new { my ($c, @s) = @_; bless {services => {map {$_ => 1} @s}}, $c }
	sub provides_service { $_[0]->{services}{$_[1]} }
}

# Runs discovery against a fake vault, kit, and manifest.  Names resolve
# through the given table rather than DNS.  Returns the nodes found and
# whatever was written to stderr.
sub cluster_nodes_for {
	my (%opts) = @_;
	my $env = bless {
		__vault => Test::FakeStatusVault->new(%{$opts{vault}}),
		__kit   => Test::FakeKit->new(@{$opts{services} // ['vault']}),
		__igs   => $opts{instance_groups},
	}, 'Genesis::Env';
	my %dns = %{$opts{dns} // {}};
	no warnings 'redefine', 'once';
	local *Genesis::Env::vault = sub { $_[0]->{__vault} };
	local *Genesis::Env::kit   = sub { $_[0]->{__kit} };
	local *Genesis::Env::manifest_lookup = sub { $_[0]->{__igs} };
	my $real_resolve = \&Genesis::Env::_resolve_host_addresses;
	local *Genesis::Env::_resolve_host_addresses = sub {
		my ($self, $host) = @_;
		return @{$dns{$host}} if $dns{$host};
		return $real_resolve->($self, $host) if defined(Genesis::Env::_canonical_ip($host));
		return ();
	};
	my @nodes;
	my ($out, $err) = output_from { @nodes = $env->_secrets_vault_cluster_nodes };
	return (\@nodes, $err);
}

sub group {
	my ($name, $instances, @networks) = @_;
	return {name => $name, instances => $instances, networks => [
		map {{name => "net$_", static_ips => $networks[$_]}} 0..$#networks
	]};
}

my $openbao_igs = [
	group('openbao', 3, [qw/10.0.0.5 10.0.0.6 10.0.0.7/]),
	group('smoke', 1, ['10.0.0.9']),
];
my @NODES443 = qw/10.0.0.5:443 10.0.0.6:443 10.0.0.7:443/;

my ($nodes, $err) = cluster_nodes_for(
	vault => {url => 'https://10.0.0.5', status_out => "https://10.0.0.5 is unsealed\n"},
	instance_groups => $openbao_igs,
);
is_deeply $nodes, \@NODES443,
	'the instance group holding the vault address is the cluster, and nothing else is';
is $err, '', 'with nothing to warn about';

($nodes) = cluster_nodes_for(
	vault => {url => 'https://10.0.0.6:8200', status_out => '', status_rc => 1},
	instance_groups => $openbao_igs,
);
is_deeply $nodes, [qw/10.0.0.5:8200 10.0.0.6:8200 10.0.0.7:8200/],
	"the target alone identifies the cluster when safe status fails, and its port is every node's";

($nodes) = cluster_nodes_for(
	vault => {url => 'https://openbao.bosh', status_out => "https://openbao.bosh is unsealed\n"},
	dns => {'openbao.bosh' => ['10.0.0.6']},
	instance_groups => $openbao_igs,
);
is_deeply $nodes, \@NODES443, 'a hostname target is resolved and matched to the static IPs';

($nodes) = cluster_nodes_for(
	vault => {url => 'https://vault.example.com', status_out =>
		"\e[32mhttps://10.0.0.5:8200 is unsealed\e[0m\nhttps://10.0.0.6:8200 is unsealed\nhttps://10.0.0.7:8200 is sealed\n"},
	dns => {'vault.example.com' => ['10.1.0.1']},
	instance_groups => $openbao_igs,
);
is_deeply $nodes, [qw/10.0.0.5:8200 10.0.0.6:8200 10.0.0.7:8200/],
	"behind a load balancer, Strongbox's per-node ports are kept";

($nodes) = cluster_nodes_for(
	vault => {url => 'https://10.0.0.5', status_out => ''},
	instance_groups => [group('openbao', 3, ['10.0.0.5 - 10.0.0.7'])],
);
is_deeply $nodes, \@NODES443, 'static IPs written as a range are expanded';

($nodes) = cluster_nodes_for(
	vault => {url => 'https://10.0.0.5', status_out => ''},
	instance_groups => [group('openbao', 3, [qw/10.0.0.5 10.0.0.6 10.0.0.7/], [qw/10.9.0.5 10.9.0.6 10.9.0.7/])],
);
is_deeply $nodes, \@NODES443,
	'a second network on the same instances does not count them twice';

($nodes) = cluster_nodes_for(
	vault => {url => 'https://[fd00::5]:8200', status_out => ''},
	instance_groups => [group('openbao', 3, [qw/fd00:0::5 fd00::6 fd00::7/])],
);
is_deeply $nodes, [qw/[fd00::5]:8200 [fd00::6]:8200 [fd00::7]:8200/],
	'IPv6 addresses match in any spelling and come back bracketed';

($nodes) = cluster_nodes_for(
	vault => {url => 'https://10.0.0.5', status_out => ''},
	instance_groups => [group('openbao', 3, []), {name => 'bare', instances => 1}],
);
is_deeply $nodes, [], 'groups without static IPs contribute nothing';

($nodes, $err) = cluster_nodes_for(
	vault => {url => 'https://openbao.bosh', status_out => "https://openbao.bosh is unsealed\n"},
	instance_groups => $openbao_igs,
);
is_deeply $nodes, [], 'a name that does not resolve finds no nodes';
like $err, qr/none of that vault's addresses .* matches a static IP/s,
	'and says so loudly instead of falling back in silence';

($nodes, $err) = cluster_nodes_for(
	vault => {url => 'https://10.0.0.5', status_out => ''},
	instance_groups => [group('openbao', 3, [qw/10.0.0.5 10.0.0.6/])],
);
like $err, qr/runs 3 instances .* only 2 of them have static IPs/s,
	'a group with more instances than matched addresses is reported';

($nodes, $err) = cluster_nodes_for(
	vault => {url => 'https://10.1.0.5', status_out => "https://10.1.0.5 is unsealed\n"},
	instance_groups => [group('openbao', 1, ['10.0.0.5'])],
);
is_deeply $nodes, [], 'a single-node vault kit deploying some other vault: no cluster';
is $err, '', 'and no warning, because there is no cluster to miss';

($nodes, $err) = cluster_nodes_for(
	services => [],
	vault => {url => 'https://10.0.0.5', status_out => "https://10.0.0.5 is unsealed\n"},
	instance_groups => $openbao_igs,
);
is_deeply $nodes, [], 'a kit that does not provide vault: no cluster';
is $err, '', 'and no warning';

# ===========================================================================
# Genesis::Env::_pre_deploy records the nodes
#
# The recording is what connects discovery to the unseal after the deploy,
# so it is checked through _pre_deploy itself, with everything around the
# vault stubbed and discovery left real.
# ===========================================================================
{
	package Test::FakeManifest;
	sub new { bless {}, shift }
	sub write_to { 1 }
	sub redacted { $_[0] }
	sub type { 'unredacted' }
}
{
	package Test::FakeManifestProvider;
	sub new { bless {}, shift }
	sub deployment { Test::FakeManifest->new }
}
{
	package Test::FakeTop;
	sub new { bless {}, shift }
	sub ci_configured { 0 }
}
{
	package Test::FakeKeyVault;
	our @ISA = ('Test::FakeStatusVault');
	sub fetch_unseal_keys { $_[0]->{fetched}++; (1, 'fetched') }
}

sub pre_deploy_state {
	my (%opts) = @_;
	my $env = bless {
		__vault => Test::FakeKeyVault->new(url => 'https://10.0.0.5', status_out => "https://10.0.0.5 is unsealed\n"),
		__kit   => Test::FakeKit->new('vault'),
		__igs   => $openbao_igs,
	}, 'Genesis::Env';
	no warnings 'redefine', 'once';
	local *Genesis::Env::vault = sub { $_[0]->{__vault} };
	local *Genesis::Env::kit   = sub { $_[0]->{__kit} };
	local *Genesis::Env::top   = sub { Test::FakeTop->new };
	local *Genesis::Env::manifest_lookup = sub { $_[0]->{__igs} };
	local *Genesis::Env::manifest_provider = sub { Test::FakeManifestProvider->new };
	local *Genesis::Env::deployment_cache_path_lookup = sub { "/nonexistent/$_[1]" };
	local *Genesis::Env::vars_file = sub { undef };
	local *Genesis::Env::has_hook = sub { 0 };
	local *Genesis::Env::_reactions = sub { 0 };
	local *Genesis::Env::_deployment_may_affect_secrets_vault = sub { $opts{affects} };
	local *Genesis::Env::_stop_renewer_for_self_deploy = sub { 0 };
	local *Genesis::Env::notify = sub { };
	output_from { $env->_pre_deploy() };
	return ($env->{deployment_state}, $env->{__vault});
}

my ($state, $key_vault) = pre_deploy_state(affects => 1);
is_deeply $state->{secrets_vault_nodes}, \@NODES443,
	'_pre_deploy records the nodes of the vault this deployment runs';
ok $key_vault->{fetched}, 'after fetching the unseal keys';

($state) = pre_deploy_state(affects => 0);
ok !exists($state->{secrets_vault_nodes}),
	'and records nothing when the deployment does not touch its secrets vault';

done_testing;
