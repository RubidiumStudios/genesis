#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Differences;
use Test::Output;
use Carp qw/croak/;
use Genesis qw(logger struct_lookup bail);
use Cwd qw(abs_path);
use JSON::PP;
use Storable qw(dclone);

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# ---------------------------------------------------------------------------
# Shared mock OCFP config data
# ---------------------------------------------------------------------------
my $ocfp_config = {
	vpc => {
		azs => {
			'az1' => { cloud_properties => '{"zone": "us-east-1a"}' },
			'az2' => { cloud_properties => '{"zone": "us-east-1b"}' },
			'az3' => { cloud_properties => '{"zone": "us-east-1c"}' }
		},
		cidr_block => '192.168.0.0/20',
		dns => '1.1.1.1',
		id => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01',
		region => 'us-east-1',
		sgs => {
			default => {
				'description' => 'Default security group',
				'id' => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxx02',
				'name' => 'default'
			}
		},
		subnets => {
			'ocfp-0' => {
				az => 'az1', cidr_block => '10.0.0.0/24',
				gateway => '10.0.0.1', dns => '10.0.0.2',
				'reserved-ips' => {
					'available_a' => '10.0.0.37',
					'available_b' => '10.0.0.250',
					'bosh_ip'     => '10.0.0.5',
				}
			},
			'ocfp-1' => {
				az => 'az2', cidr_block => '10.0.1.0/24',
				gateway => '10.0.1.1', dns => '10.0.1.2',
				'reserved-ips' => {
					'available_a' => '10.0.1.16',
					'available_b' => '10.0.1.250',
					'reserved_a'  => '10.0.1.0',
					'reserved_b'  => '10.0.1.36',
				}
			},
			'ocfp-2' => {
				az => 'az3', cidr_block => '10.0.2.0/24',
				gateway => '10.0.2.1', dns => '10.0.2.2',
				'reserved-ips' => {
					'reserved_a' => '10.0.2.0',
					'reserved_b' => '10.0.2.36',
					'reserved_c' => '10.0.2.255',
					'reserved_d' => '10.0.2.255',
					'bosh_ip'    => '10.0.2.6',
				}
			}
		}
	}
};

my $kit = mock "Genesis::Kit" => {
	name                => 'test-kit',
	version             => '1.0.0',
	genesis_version_min => '3.1.0-rc.10',
	id                  => sub { return $_[0]->name . '/' . $_[0]->version },
	kit_bug => sub {
		my ($self, $msg, @args) = @_;
		bail("Throwing a kit bug: ".$msg, @args);
	},
};

my $bosh = mock "Genesis::BOSH" => { alias => 'mock-bosh' };

# ---------------------------------------------------------------------------
# Genesis version and env vars (set once before all subtests)
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN}  = 'genesis';
$ENV{GENESIS_KIT_HOOK}  = 'cloud-config';

# ---------------------------------------------------------------------------
# Load hook implementations
# ---------------------------------------------------------------------------
subtest 'require hook implementations' => sub {
	plan tests => 2;
	require_ok 'hooks/cloud-config-bosh-director.pm';
	require_ok 'hooks/cloud-config-bosh.pm';
};

# ---------------------------------------------------------------------------
# Build director network exodus once for all deployment hook subtests.
# The director hook allocates 4 IPs on ocfp-1 for the compilation network.
# ---------------------------------------------------------------------------
my $director_network_exodus;

subtest 'director hook - build network exodus for deployment tests' => sub {
	plan tests => 5;

	my $mgmt_env = mock "Genesis::Env" => {
		name           => 'test-env-mgmt',
		type           => 'bosh',
		kit            => $kit,
		bosh           => $bosh,
		use_create_env => 1,
		features       => Mock::ReferencedValue->new(['ocfp']),
		iaas           => 'openstack',
		scale          => 'dev',

		env_config_overrides      => {},
		director_config_overrides => {},

		ocfp_subnet_prefix => 'ocfp',
		ocfp_config        => $ocfp_config,

		is_ocfp => sub {
			return $_[0]->features && grep { $_ eq 'ocfp' } ($_[0]->features);
		},
		lookup => sub {
			my ($self, $key, $default) = @_;
			return struct_lookup($self->config, $key, $default);
		},
		director_exodus_lookup => sub {
			die 'Create-env environments do not have directors';
		},
		# Director hook calls exodus_lookup('/network:.') to preserve existing
		# claims; returning undef indicates a fresh first-time deploy.
		exodus_lookup => sub { return undef },
		cpi_enabled => 0,
		cpi_name => undef,
		ocfp_config_lookup => sub {
			my ($self, $key) = @_;
			return struct_lookup($self->ocfp_config, $key);
		},
		config => { params => { cloud_config_prefix => 'test-env-mgmt.bosh' } },
	};

	local $ENV{GENESIS_ENVIRONMENT} = 'test-env-mgmt';

	my $dir_hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env     => $mgmt_env,
		purpose => 'director',
	);

	isa_ok($dir_hook, 'Genesis::Hook::CloudConfig::Bosh::Director',
		'director hook initialised');

	# Define compilation network on ocfp-1 with 4-IP allocation
	my $comp_net = $dir_hook->network_definition('compilation',
		strategy => 'ocfp',
		dynamic_subnets => {
			subnets    => ['ocfp-1'],
			allocation => { size => 4, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $dir_hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	);

	ok($comp_net, 'director compilation network definition generated');
	is($comp_net->{name}, 'test-env-mgmt.bosh.net-compilation',
		'director compilation network has correct name');

	$mgmt_env->_mock_set_responses(workdir => {value => workdir});
	ok($dir_hook->perform, 'director hook perform succeeds');

	$director_network_exodus = $dir_hook->results->{network};

	# Verify the exodus shows the correct allocation on ocfp-1
	is(
		$director_network_exodus->{subnets}{'ocfp-1'}{claims}{'test-env-mgmt.bosh.net-compilation'},
		'10.0.1.37-10.0.1.40',
		'director exodus records compilation claim 10.0.1.37-10.0.1.40 on ocfp-1',
	);
};

# ---------------------------------------------------------------------------
# Helper: create a fresh deployment-hook env that uses the director exodus.
# Each call uses a unique name to avoid the CloudConfig object cache.
# ---------------------------------------------------------------------------
my $env_seq = 0;
sub make_deploy_env {
	$env_seq++;
	my $seq = $env_seq;
	mock "Genesis::Env" => {(
		name           => "test-env-ocf-$seq",
		type           => 'bosh',
		kit            => $kit,
		bosh           => $bosh,
		use_create_env => 0,
		features       => Mock::ReferencedValue->new(['ocfp', 'some-feature']),
		iaas           => 'openstack',
		scale          => 'dev',

		env_config_overrides      => {},
		director_config_overrides => {},

		ocfp_subnet_prefix => 'ocfp',
		ocfp_config        => $ocfp_config,

		is_ocfp => sub {
			return $_[0]->features && grep { $_ eq 'ocfp' } ($_[0]->features);
		},
		lookup => sub {
			my ($self, $key, $default) = @_;
			return struct_lookup($self->config, $key, $default);
		},
		director_exodus_lookup => sub {
			my ($self, $key) = @_;
			# Deep-copy so each hook instance gets its own isolated copy of the
			# director network data; prevents test-state leakage across subtests.
			return dclone($director_network_exodus) if $key eq '/network';
			die "Unknown exodus key: $key";
		},
		ocfp_config_lookup => sub {
			my ($self, $key) = @_;
			return struct_lookup($self->ocfp_config, $key);
		},
		cpi_enabled => 0,
		cpi_name    => undef,
		config => { params => { cloud_config_prefix => 'test-env.test' } },
	), @_};
}

# ---------------------------------------------------------------------------
# AZ Management
# ---------------------------------------------------------------------------
subtest 'get_available_azs - returns full AZ hash from director network data' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $azs  = $hook->get_available_azs;

	is(ref($azs), 'HASH', 'get_available_azs() returns a hashref');
	# The director hook stores index, name (env-name + '-z' + index), and
	# cloud_properties in each AZ entry.  The base CloudConfig.pm always derives
	# the az_prefix as "$env->name . '-z'", so canonical names are '-z1' etc.
	cmp_deeply($azs, {
		'az1' => superhashof({ 'cloud_properties' => '{"zone": "us-east-1a"}', 'name' => 'test-env-mgmt-z1' }),
		'az2' => superhashof({ 'cloud_properties' => '{"zone": "us-east-1b"}', 'name' => 'test-env-mgmt-z2' }),
		'az3' => superhashof({ 'cloud_properties' => '{"zone": "us-east-1c"}', 'name' => 'test-env-mgmt-z3' }),
	}, 'get_available_azs() returns all three AZs with correct name and cloud_properties');
};

subtest 'lookup_az - resolves short AZ name to canonical full name' => sub {
	plan tests => 3;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	is($hook->lookup_az('az1'), 'test-env-mgmt-z1',
		'lookup_az("az1") returns canonical name test-env-mgmt-z1');

	is($hook->lookup_az('az2'), 'test-env-mgmt-z2',
		'lookup_az("az2") returns canonical name test-env-mgmt-z2');

	is($hook->lookup_az('az3'), 'test-env-mgmt-z3',
		'lookup_az("az3") returns canonical name test-env-mgmt-z3');
};

subtest 'lookup_az - bails for unknown AZ identifier' => sub {
	plan tests => 1;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	throws_ok {
		$hook->lookup_az('az99')
	} qr/Availability zone az99 not found in the available AZs for the network/,
		'lookup_az() dies with informative message for unknown AZ';
};

subtest 'lookup_az - also resolves by canonical full name' => sub {
	plan tests => 1;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	is($hook->lookup_az('test-env-mgmt-z1'), 'test-env-mgmt-z1',
		'lookup_az() also resolves canonical full name to itself');
};

subtest 'get_available_azs_in_network - returns AZs for allocated network' => sub {
	plan tests => 4;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	# Build a bosh network so there are allocations to query
	$hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	);

	my $azs = $hook->get_available_azs_in_network('bosh');

	ok(defined $azs, 'get_available_azs_in_network() returns a defined value');
	is(ref($azs), 'ARRAY', 'get_available_azs_in_network() returns an arrayref');

	# bosh network uses ocfp-0 (az1) and ocfp-2 (az3) — ocfp-1 (az2) is
	# fully claimed by the director compilation network
	my @sorted = sort @$azs;
	is(scalar @sorted, 2, 'get_available_azs_in_network() returns 2 AZs for bosh network');
	cmp_deeply(\@sorted, ['test-env-mgmt-z1', 'test-env-mgmt-z3'],
		'get_available_azs_in_network() returns the AZs for subnets actually used');
};

# ---------------------------------------------------------------------------
# Subnet Filtering
# ---------------------------------------------------------------------------
subtest '_filter_subnets - no args returns all subnets' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets();
	is(ref($result), 'HASH', '_filter_subnets() returns a hashref');
	cmp_deeply([sort keys %$result], ['ocfp-0', 'ocfp-1', 'ocfp-2'],
		'_filter_subnets() with no args returns all three subnets');
};

subtest '_filter_subnets - single string filter' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets('ocfp-0');
	cmp_deeply([sort keys %$result], ['ocfp-0'],
		'_filter_subnets("ocfp-0") returns exactly one subnet');
	cmp_deeply($result, {
		'ocfp-0' => {
			az             => 'az1',
			cidr_block     => '10.0.0.0/24',
			dns            => '10.0.0.2',
			gateway        => '10.0.0.1',
			'reserved-ips' => {
				'available_a' => '10.0.0.37',
				'available_b' => '10.0.0.250',
				'bosh_ip'     => '10.0.0.5',
			},
		},
	}, '_filter_subnets("ocfp-0") returns correct subnet data');
};

subtest '_filter_subnets - multiple name array filter' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets(['ocfp-0', 'ocfp-2', 'ocfp-4']);
	cmp_deeply([sort keys %$result], ['ocfp-0', 'ocfp-2'],
		'_filter_subnets(["ocfp-0","ocfp-2","ocfp-4"]) returns only existing subnets');

	my $result2 = $hook->_filter_subnets(['ocfp-1', 'ocfp-2']);
	cmp_deeply([sort keys %$result2], ['ocfp-1', 'ocfp-2'],
		'_filter_subnets(["ocfp-1","ocfp-2"]) returns both matching subnets');
};

subtest '_filter_subnets - regex filter' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets(qr/ocfp-[2-4]/);
	cmp_deeply([sort keys %$result], ['ocfp-2'],
		'_filter_subnets(qr/ocfp-[2-4]/) matches only ocfp-2');

	my $result2 = $hook->_filter_subnets(qr/ocfp-[0-1]/);
	cmp_deeply([sort keys %$result2], ['ocfp-0', 'ocfp-1'],
		'_filter_subnets(qr/ocfp-[0-1]/) matches ocfp-0 and ocfp-1');
};

subtest '_filter_subnets - mixed array of regex and string, no duplicates' => sub {
	plan tests => 1;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets([qr/ocfp-[2-4]/, 'ocfp-0', 'ocfp-2']);
	cmp_deeply([sort keys %$result], ['ocfp-0', 'ocfp-2'],
		'_filter_subnets([regex, string, string]) deduplicates and returns correct subnets');
};

subtest '_filter_subnets - nonexistent name returns empty hashref' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets('nonexistent');
	is(ref($result), 'HASH', '_filter_subnets("nonexistent") returns a hashref');
	cmp_deeply([keys %$result], [],
		'_filter_subnets("nonexistent") returns an empty hashref');
};

subtest 'dynamic_subnets - subnet named exactly the prefix is selected' => sub {
	plan tests => 3;

	# A bloc may hold a single subnet whose name IS the prefix (e.g. an
	# 'infra' subnet with ocfp_subnet_prefix 'infra') alongside numbered
	# '<prefix>-N' subnets for other prefixes.
	my $config = dclone($ocfp_config);
	$config->{vpc}{subnets} = {
		'infra' => {
			az => 'az1', cidr_block => '10.0.3.0/24',
			gateway => '10.0.3.1', dns => '10.0.3.2',
			'reserved-ips' => {
				'wireguard_ip' => '10.0.3.6',
			},
		},
	};

	my $env  = make_deploy_env(
		ocfp_subnet_prefix => 'infra',
		ocfp_config        => $config,
	);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net;
	lives_ok {
		$net = $hook->network_definition('wireguard',
			strategy => 'ocfp',
			dynamic_subnets => {
				allocation => { size => 0, statics => 0 },
				cloud_properties_for_iaas => {
					openstack => {
						'net_id'          => $hook->network_reference('id'),
						'security_groups' => ['default'],
					},
				},
			},
		);
	} 'network_definition() succeeds when the only subnet is named exactly the prefix';

	is(scalar @{$net->{subnets}}, 1, 'network definition contains one subnet');
	is($net->{subnets}[0]{range}, '10.0.3.0/24',
		'subnet range comes from the prefix-named subnet');
};

# ---------------------------------------------------------------------------
# Allocation Tracking
# ---------------------------------------------------------------------------
subtest '_get_existing_allocations - reflects director compilation claim' => sub {
	plan tests => 5;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $allocs = $hook->_get_existing_allocations();
	is(ref($allocs), 'HASH', '_get_existing_allocations() returns a hashref');

	cmp_deeply([keys %$allocs], ['test-env-mgmt.bosh.net-compilation'],
		'_get_existing_allocations() shows only director compilation network is allocated');

	cmp_deeply([keys %{$allocs->{'test-env-mgmt.bosh.net-compilation'}}], ['ocfp-1'],
		'director compilation allocation is on ocfp-1 only');

	my $span = $allocs->{'test-env-mgmt.bosh.net-compilation'}{'ocfp-1'};
	isa_ok($span, 'IPv4::Span', 'allocation value is an IPv4::Span');
	is($span->range, '10.0.1.37-10.0.1.40',
		'compilation allocation range is 10.0.1.37-10.0.1.40');
};

subtest 'get_allocated_networks - returns per-subnet allocation details' => sub {
	plan tests => 4;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	# Build a bosh network first to create an allocation
	$hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	);

	my $allocated = $hook->get_allocated_networks();
	is(ref($allocated), 'HASH', 'get_allocated_networks() returns a hashref');

	my $bosh_net_name = $hook->basename . '.net-bosh';
	ok(exists $allocated->{$bosh_net_name},
		"get_allocated_networks() contains entry for $bosh_net_name");

	my $bosh_alloc = $allocated->{$bosh_net_name};
	ok(exists $bosh_alloc->{'ocfp-0'}, 'bosh network allocation includes ocfp-0');

	cmp_deeply($bosh_alloc->{'ocfp-0'}, {
		allocated => '10.0.0.5',
		az        => 'test-env-mgmt-z1',
	}, 'ocfp-0 allocation shows bosh_ip 10.0.0.5 and correct AZ');
};

subtest 'get_network_size - returns total IP count for a network' => sub {
	plan tests => 3;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	$hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	);

	my $total_size = $hook->get_network_size('bosh');
	ok(defined $total_size, 'get_network_size() returns a defined value');
	ok($total_size > 0, 'get_network_size() returns a positive value');

	# bosh network uses bosh_ip on ocfp-0 (1 IP) and bosh_ip on ocfp-2 (1 IP)
	is($total_size, 2, 'get_network_size("bosh") returns 2 (one bosh_ip per subnet)');
};

subtest 'get_network_size - filtered by AZ returns subset' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	$hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	);

	my $az1_size = $hook->get_network_size('bosh', 'az1');
	is($az1_size, 1, 'get_network_size("bosh", "az1") returns 1 (ocfp-0 only)');

	my $az3_size = $hook->get_network_size('bosh', 'az3');
	is($az3_size, 1, 'get_network_size("bosh", "az3") returns 1 (ocfp-2 only)');
};

subtest 'update_network - records allocations for named network' => sub {
	plan tests => 4;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	# Start: no bosh claims yet
	my $allocs_before = $hook->_get_existing_allocations();
	ok(!exists $allocs_before->{$hook->basename.'.net-bosh'},
		'no bosh network claim before network_definition is called');

	# Build network definition — this internally calls update_network
	$hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	);

	# After: claims on ocfp-0 and ocfp-2
	cmp_deeply($hook->network->{subnets}{'ocfp-0'}{claims}, {
		$hook->basename.'.net-bosh' => '10.0.0.5',
	}, 'update_network records bosh_ip claim on ocfp-0');

	cmp_deeply($hook->network->{subnets}{'ocfp-2'}{claims}, {
		$hook->basename.'.net-bosh' => '10.0.2.6',
	}, 'update_network records bosh_ip claim on ocfp-2');

	# director claim on ocfp-1 is preserved
	cmp_deeply($hook->network->{subnets}{'ocfp-1'}{claims}, {
		'test-env-mgmt.bosh.net-compilation' => '10.0.1.37-10.0.1.40',
	}, 'director compilation claim on ocfp-1 is not disturbed');
};

subtest 'relinquish_networks - removes claim records for named networks' => sub {
	plan tests => 3;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	# Build two networks
	$hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	);

	my $bosh_net = $hook->basename . '.net-bosh';
	ok(
		exists $hook->network->{subnets}{'ocfp-0'}{claims}{$bosh_net},
		'bosh network claim exists on ocfp-0 before relinquish',
	);

	$hook->relinquish_networks('bosh');

	ok(
		!exists $hook->network->{subnets}{'ocfp-0'}{claims}{$bosh_net},
		'bosh network claim removed from ocfp-0 after relinquish',
	);
	ok(
		!exists $hook->network->{subnets}{'ocfp-2'}{claims}{$bosh_net},
		'bosh network claim removed from ocfp-2 after relinquish',
	);
};

# ---------------------------------------------------------------------------
# Network Definition
# ---------------------------------------------------------------------------
subtest 'network_definition - ocfp strategy returns hashref with name/type/subnets' => sub {
	plan tests => 5;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net = $hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	);

	ok($net, 'network_definition() returns a defined value');
	is(ref($net), 'HASH', 'network_definition() returns a hashref');
	is($net->{name}, $hook->basename.'.net-bosh',
		'network name follows basename.net-target format');
	is($net->{type}, 'manual', 'network type is "manual" for ocfp strategy');
	ok(scalar @{$net->{subnets}}, 'network definition contains at least one subnet');
};

subtest 'network_definition - vip strategy returns name and type only' => sub {
	plan tests => 3;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net = $hook->network_definition('floaters', strategy => 'vip');

	ok($net, 'network_definition() with vip strategy returns a defined value');
	is($net->{name}, $hook->basename.'.net-floaters',
		'vip network name is correct');
	is($net->{type}, 'vip', 'vip strategy sets type to "vip"');
};

subtest 'network_definition - vip strategy has no subnets key' => sub {
	plan tests => 1;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net = $hook->network_definition('floaters', strategy => 'vip');
	ok(!exists $net->{subnets},
		'vip network definition has no subnets key');
};

subtest 'network_definition - unsupported strategy throws error' => sub {
	plan tests => 1;

	# The unsupported-strategy bail fires when (strategy eq 'ocfp') xor is_ocfp
	# evaluates to FALSE.  For a non-OCFP env, any non-ocfp strategy reaches the
	# bail path because the env and strategy are both non-ocfp (xor = false).
	my $env  = make_deploy_env(
		is_ocfp  => 0,
		features => Mock::ReferencedValue->new([]),
	);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	throws_ok {
		$hook->network_definition('bosh', strategy => 'badstrategy')
	} qr/Network definition strategy badstrategy is not supported/,
		'network_definition() throws for unsupported strategy on non-ocfp env';
};

subtest 'network_definition - name_prefix overrides default prefix' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net = $hook->network_definition('floaters',
		strategy    => 'vip',
		name_prefix => 'custom-prefix-',
	);

	ok($net, 'network_definition() with name_prefix returns a value');
	is($net->{name}, 'custom-prefix-floaters',
		'name_prefix option replaces default basename prefix');
};

subtest 'network_definition - ocfp subnets: 2 subnets (ocfp-1 fully claimed)' => sub {
	plan tests => 4;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net = $hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	);

	is(scalar @{$net->{subnets}}, 2,
		'bosh network has 2 subnets (ocfp-1 excluded as fully claimed by director)');

	is($net->{subnets}[0]{az}, 'test-env-mgmt-z1',
		'first subnet AZ is test-env-mgmt-z1 (ocfp-0)');

	is($net->{subnets}[1]{az}, 'test-env-mgmt-z3',
		'second subnet AZ is test-env-mgmt-z3 (ocfp-2)');

	cmp_deeply($net->{subnets}[0]{static}, ['10.0.0.5'],
		'first subnet static list contains bosh_ip 10.0.0.5');
};

# ---------------------------------------------------------------------------
# subnets accessor
# ---------------------------------------------------------------------------
subtest 'subnets - returns OCFP subnet definitions from ocfp_config' => sub {
	plan tests => 3;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $subnets = $hook->subnets;
	is(ref($subnets), 'HASH', 'subnets() returns a hashref');
	cmp_deeply([sort keys %$subnets], ['ocfp-0', 'ocfp-1', 'ocfp-2'],
		'subnets() contains all three OCFP subnets');
	ok(exists $subnets->{'ocfp-0'}{cidr_block},
		'subnet data includes cidr_block field');
};

# ---------------------------------------------------------------------------
# Network Security Groups
# ---------------------------------------------------------------------------
subtest 'get_network_security_groups - returns a LookupNetworkRef' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $ref = $hook->get_network_security_groups('id');
	isa_ok($ref, 'Genesis::Hook::CloudConfig::LookupNetworkRef',
		'get_network_security_groups() returns a LookupNetworkRef');

	is($ref->{ref}, 'sgs',
		'LookupNetworkRef is keyed on "sgs"');
};

subtest 'get_network_security_groups - resolves to SG ids when resolved' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $ref    = $hook->get_network_security_groups('id');
	my $vpc_data = $hook->env->ocfp_config_lookup(['net','vpc']);

	my $result = $ref->resolve($hook, $vpc_data);
	ok(defined $result, 'resolved security groups is defined');
	cmp_deeply($result, ['xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxx02'],
		'resolved SG ids match expected default SG id');
};

# ---------------------------------------------------------------------------
# Reserved IP target aliasing (openbao/vault rename fallback)
# ---------------------------------------------------------------------------
# ocfp-0 reserves a single vault_ip, ocfp-1 reserves a vault_a/vault_b pair,
# and ocfp-2 has no target-specific reservation at all (used to prove the
# no-match/no-alias case still drops the subnet and now warns).
my $alias_ocfp_config = {
	vpc => {
		azs => {
			'az1' => { cloud_properties => '{"zone": "us-east-1a"}' },
			'az2' => { cloud_properties => '{"zone": "us-east-1b"}' },
			'az3' => { cloud_properties => '{"zone": "us-east-1c"}' },
		},
		cidr_block => '10.9.0.0/20',
		dns        => '1.1.1.1',
		id         => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx09',
		region     => 'us-east-1',
		sgs => {
			default => {
				'description' => 'Default security group',
				'id'          => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxx09',
				'name'        => 'default',
			},
		},
		subnets => {
			'ocfp-0' => {
				az => 'az1', cidr_block => '10.9.0.0/24',
				gateway => '10.9.0.1', dns => '10.9.0.2',
				'reserved-ips' => {
					'vault_ip' => '10.9.0.5',
				},
			},
			'ocfp-1' => {
				az => 'az2', cidr_block => '10.9.1.0/24',
				gateway => '10.9.1.1', dns => '10.9.1.2',
				'reserved-ips' => {
					'vault_a' => '10.9.1.9',
					'vault_b' => '10.9.1.11',
				},
			},
			'ocfp-2' => {
				az => 'az3', cidr_block => '10.9.2.0/24',
				gateway => '10.9.2.1', dns => '10.9.2.2',
				'reserved-ips' => {},
			},
		},
	},
};

subtest '_get_reserved_allocation - openbao falls back to vault reserved-ips' => sub {
	plan tests => 3;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $subnets = $hook->subnets;

	my ($ip_alloc) = $hook->_get_reserved_allocation('openbao', $subnets->{'ocfp-0'});
	is($ip_alloc->range, '10.9.0.5',
		'openbao resolves the single vault_ip reservation on ocfp-0');

	my ($pair_alloc) = $hook->_get_reserved_allocation('openbao', $subnets->{'ocfp-1'});
	is($pair_alloc->range, '10.9.1.10',
		'openbao resolves the vault_a/vault_b pair reservation on ocfp-1');

	my ($empty_alloc) = $hook->_get_reserved_allocation('openbao', $subnets->{'ocfp-2'});
	is($empty_alloc->size, 0,
		'openbao has no allocation on ocfp-2, which defines no vault reservation either');
};

subtest '_get_reserved_allocation - vault target is unchanged (regression)' => sub {
	plan tests => 3;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $subnets = $hook->subnets;

	my ($ip_alloc) = $hook->_get_reserved_allocation('vault', $subnets->{'ocfp-0'});
	is($ip_alloc->range, '10.9.0.5',
		'vault still resolves its own vault_ip reservation directly on ocfp-0');

	my ($pair_alloc) = $hook->_get_reserved_allocation('vault', $subnets->{'ocfp-1'});
	is($pair_alloc->range, '10.9.1.10',
		'vault still resolves its own vault_a/vault_b pair directly on ocfp-1');

	my ($empty_alloc) = $hook->_get_reserved_allocation('vault', $subnets->{'ocfp-2'});
	is($empty_alloc->size, 0,
		'vault has no allocation on ocfp-2, which defines no reservation at all');
};

subtest '_get_reserved_allocation - unaliased target with no keys returns empty' => sub {
	plan tests => 1;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my ($alloc) = $hook->_get_reserved_allocation('foobar', $hook->subnets->{'ocfp-0'});
	is($alloc->size, 0,
		'target with no matching keys and no alias table entry resolves to no allocation');
};

subtest '_get_reserved_allocation - kit-declared aliases resolve (scalar + arrayref forms)' => sub {
	plan tests => 3;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);

	# Scalar form.
	{
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
		no warnings 'redefine';
		local *Genesis::Hook::CloudConfig::ocfp_reserved_ip_target_aliases = sub {
			my (undef, $target) = @_;
			return $target eq 'foobar' ? 'vault' : undef;
		};
		my ($alloc) = $hook->_get_reserved_allocation('foobar', $hook->subnets->{'ocfp-0'});
		is($alloc->range, '10.9.0.5',
			'kit override (scalar) resolves foobar via vault');
	}

	# Arrayref form.
	{
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
		no warnings 'redefine';
		local *Genesis::Hook::CloudConfig::ocfp_reserved_ip_target_aliases = sub {
			my (undef, $target) = @_;
			return $target eq 'foobar' ? ['nonexistent', 'vault'] : undef;
		};
		my ($alloc) = $hook->_get_reserved_allocation('foobar', $hook->subnets->{'ocfp-1'});
		is($alloc->range, '10.9.1.10',
			'kit override (arrayref) walks candidates and finds vault');
	}

	# Kit override supersedes core-registered fallback.
	{
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
		no warnings 'redefine';
		local *Genesis::Hook::CloudConfig::ocfp_reserved_ip_target_aliases = sub {
			my (undef, $target) = @_;
			# Divert openbao to a nonexistent alias -- core would send it to
			# vault, so if the kit path wins we get no allocation.
			return $target eq 'openbao' ? 'nonexistent' : undef;
		};
		my ($alloc) = $hook->_get_reserved_allocation('openbao', $hook->subnets->{'ocfp-0'});
		is($alloc->size, 0,
			'kit-declared aliases run before core fallback (openbao->nonexistent yields empty)');
	}
};

subtest 'network_definition - openbao target keeps subnets via vault alias fallback' => sub {
	plan tests => 3;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net;
	my $warn = stderr_from {
		$net = $hook->network_definition('openbao',
			strategy => 'ocfp',
			dynamic_subnets => {
				allocation => { size => 0, statics => 0 },
				cloud_properties_for_iaas => {
					openstack => {
						'net_id'          => $hook->network_reference('id'),
						'security_groups' => ['default'],
					},
				},
			},
		);
	};

	is(scalar @{$net->{subnets}}, 2,
		'openbao network keeps ocfp-0 and ocfp-1, which resolve via the vault alias');

	my @names = map { $_->{az} } @{$net->{subnets}};
	cmp_deeply(\@names, ['test-env-mgmt-z1', 'test-env-mgmt-z2'],
		'surviving subnets are ocfp-0 (az1) and ocfp-1 (az2)');

	like($warn, qr/ocfp-2.*openbao|openbao.*ocfp-2/,
		'dropping ocfp-2 for openbao (no vault reservation either) emits a warning naming both');
};

subtest 'network_definition - unaliased target with no reservations drops and warns for every subnet' => sub {
	plan tests => 2;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net;
	my $warn = stderr_from {
		$net = $hook->network_definition('foobar',
			strategy => 'ocfp',
			dynamic_subnets => {
				allocation => { size => 0, statics => 0 },
				cloud_properties_for_iaas => {
					openstack => {
						'net_id'          => $hook->network_reference('id'),
						'security_groups' => ['default'],
					},
				},
			},
		);
	};

	is(scalar @{$net->{subnets}}, 0,
		'foobar network has no alias and no reservations, so every subnet is dropped');

	like($warn, qr/ocfp-0/,
		'warning names at least one dropped subnet for the unaliased target');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
