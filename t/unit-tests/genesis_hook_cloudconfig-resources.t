#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Differences;
use Carp qw/croak/;
use Genesis qw(logger struct_lookup bail);
use Cwd qw(abs_path);
use JSON::PP;

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

BEGIN { use_ok('Genesis::Hook::CloudConfig::Helpers', qw/gigabytes megabytes/) }

# ---------------------------------------------------------------------------
# Shared mock data
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
				'reserved-ips' => { 'available_a' => '10.0.0.37', 'available_b' => '10.0.0.250', 'bosh_ip' => '10.0.0.5' }
			},
			'ocfp-1' => {
				az => 'az2', cidr_block => '10.0.1.0/24',
				gateway => '10.0.1.1', dns => '10.0.1.2',
				'reserved-ips' => { 'available_a' => '10.0.1.16', 'available_b' => '10.0.1.250', 'reserved_a' => '10.0.1.0', 'reserved_b' => '10.0.1.36' }
			},
			'ocfp-2' => {
				az => 'az3', cidr_block => '10.0.2.0/24',
				gateway => '10.0.2.1', dns => '10.0.2.2',
				'reserved-ips' => { 'reserved_a' => '10.0.2.0', 'reserved_b' => '10.0.2.36', 'reserved_c' => '10.0.2.255', 'reserved_d' => '10.0.2.255', 'bosh_ip' => '10.0.2.6' }
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

# Director network exodus (pre-populated, no claims)
my $director_network_exodus = {
	'azs' => {
		'az1' => { 'cloud_properties' => '{"zone": "us-east-1a"}', 'name' => 'test-env-mgmt-az1' },
		'az2' => { 'cloud_properties' => '{"zone": "us-east-1b"}', 'name' => 'test-env-mgmt-az2' },
		'az3' => { 'cloud_properties' => '{"zone": "us-east-1c"}', 'name' => 'test-env-mgmt-az3' }
	},
	'subnets' => {
		'ocfp-0' => { 'az' => 'test-env-mgmt-az1', 'claims' => {}, 'range' => '10.0.0.0-10.0.0.255' },
		'ocfp-1' => { 'az' => 'test-env-mgmt-az2', 'claims' => {}, 'range' => '10.0.1.0-10.0.1.255' },
		'ocfp-2' => { 'az' => 'test-env-mgmt-az3', 'claims' => {}, 'range' => '10.0.2.0-10.0.2.255' }
	}
};

my $test_seq = 0;
sub mock_env {
	$test_seq++;
	mock "Genesis::Env" => {(
		name           => "test-env-res-$test_seq",
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
		is_ocfp => sub { return $_[0]->features && grep { $_ eq 'ocfp' } ($_[0]->features); },
		lookup => sub { my ($self, $key, $default) = @_; return struct_lookup($self->config, $key, $default); },
		director_exodus_lookup => sub {
			my ($self, $key) = @_;
			return $director_network_exodus if $key eq '/network';
			die "Unknown key: $key";
		},
		ocfp_config_lookup => sub { my ($self, $key) = @_; return struct_lookup($self->ocfp_config, $key); },
		config => { params => { cloud_config_prefix => 'test-env.test' } },
	), @_};
}

$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{"GENESIS_KIT_HOOK"} = "cloud-config";

require_ok "hooks/cloud-config-bosh.pm";

# ---------------------------------------------------------------------------
# Helper: create a fresh hook with a fresh env
# ---------------------------------------------------------------------------
sub make_hook {
	my (%overrides) = @_;
	my $env = mock_env(%overrides);
	return Genesis::Hook::CloudConfig::Bosh->init(env => $env);
}

# ===========================================================================
# 1. vm_type_definition
# ===========================================================================
subtest 'vm_type_definition' => sub {
	plan tests => 5;

	# 1a. Basic: name is basename.vm-<target>
	subtest 'name format is basename.vm-<target>' => sub {
		plan tests => 2;

		my $hook = make_hook();
		my $vm_type = $hook->vm_type_definition('default',
			cloud_properties_for_iaas => {
				openstack => { instance_type => 'm1.small' },
			},
		);
		ok(defined $vm_type, 'vm_type_definition returns a defined value');
		is($vm_type->{name}, $hook->basename . '.vm-default',
			'name is prefixed with basename and vm- prefix');
	};

	# 1b. for_scale returns dev value when scale is dev
	subtest 'for_scale resolves dev value at dev scale' => sub {
		plan tests => 1;

		my $hook = make_hook();
		my $vm_type = $hook->vm_type_definition('bosh',
			cloud_properties_for_iaas => {
				openstack => {
					'instance_type' => $hook->for_scale({ dev => 'm1.1', prod => 'm1.3' }, 'm1.2'),
					'boot_from_volume' => $hook->TRUE,
					'root_disk' => { 'size' => $hook->for_scale({ dev => 32, prod => 64 }, 48) },
				},
			},
		);
		cmp_deeply($vm_type, {
			'name' => $hook->basename . '.vm-bosh',
			'cloud_properties' => {
				'boot_from_volume' => $hook->TRUE,
				'instance_type' => 'm1.1',
				'root_disk' => { 'size' => 32 }
			}
		}, 'vm_type_definition resolves for_scale with dev scale correctly');
	};

	# 1c. for_scale returns prod value when scale is prod
	subtest 'for_scale resolves prod value at prod scale' => sub {
		plan tests => 1;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('scale' => 'prod');
		my $vm_type = $hook->vm_type_definition('bosh',
			cloud_properties_for_iaas => {
				openstack => {
					'instance_type' => $hook->for_scale({ dev => 'm1.1', prod => 'm1.3' }, 'm1.2'),
					'root_disk' => { 'size' => $hook->for_scale({ dev => 32, prod => 64 }, 48) },
				},
			},
		);
		cmp_deeply($vm_type, {
			'name' => $hook->basename . '.vm-bosh',
			'cloud_properties' => {
				'instance_type' => 'm1.3',
				'root_disk' => { 'size' => 64 }
			}
		}, 'vm_type_definition resolves for_scale with prod scale correctly');
	};

	# 1d. for_scale returns default value for unknown scale
	subtest 'for_scale resolves default value for unknown scale' => sub {
		plan tests => 1;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('scale' => 'staging');
		my $vm_type = $hook->vm_type_definition('bosh',
			cloud_properties_for_iaas => {
				openstack => {
					'instance_type' => $hook->for_scale({ dev => 'm1.1', prod => 'm1.3' }, 'm1.2'),
					'root_disk' => { 'size' => $hook->for_scale({ dev => 32, prod => 64 }, 48) },
				},
			},
		);
		cmp_deeply($vm_type, {
			'name' => $hook->basename . '.vm-bosh',
			'cloud_properties' => {
				'instance_type' => 'm1.2',
				'root_disk' => { 'size' => 48 }
			}
		}, 'vm_type_definition resolves for_scale default for unknown scale correctly');
	};

	# 1e. IaaS selection: aws selects aws cloud_properties
	subtest 'cloud_properties_for_iaas selects correct IaaS properties' => sub {
		plan tests => 2;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('iaas' => 'aws');
		my $vm_type = $hook->vm_type_definition('bosh',
			cloud_properties_for_iaas => {
				aws => {
					'instance_type' => 'c4.2xlarge',
					'root_disk' => { 'size' => 25, 'type' => 'gp3' },
				},
				openstack => {
					'instance_type' => 'm1.2',
					'boot_from_volume' => $hook->TRUE,
				},
			},
		);
		cmp_deeply($vm_type, {
			'name' => $hook->basename . '.vm-bosh',
			'cloud_properties' => {
				'instance_type' => 'c4.2xlarge',
				'root_disk' => { 'size' => 25, 'type' => 'gp3' }
			}
		}, 'vm_type_definition selects aws cloud_properties when iaas is aws');

		# When no IaaS matches, returns empty list (not an error)
		$env->_mock_set_responses('iaas' => 'vsphere');
		my @result = $hook->vm_type_definition('bosh',
			cloud_properties_for_iaas => {
				aws => { 'instance_type' => 'c4.2xlarge' },
				openstack => { 'instance_type' => 'm1.2' },
			},
		);
		is(scalar(@result), 0,
			'vm_type_definition returns empty list when no IaaS match and no common properties');
	};
};

# ===========================================================================
# 2. disk_type_definition
# ===========================================================================
subtest 'disk_type_definition' => sub {
	plan tests => 5;

	# 2a. Basic: name format and gigabytes helper
	subtest 'name format is basename.disk-<target> and gigabytes helper works' => sub {
		plan tests => 3;

		my $hook = make_hook();
		my $disk_type = $hook->disk_type_definition('data',
			common => { disk_size => gigabytes(64) },
			cloud_properties_for_iaas => {
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		ok(defined $disk_type, 'disk_type_definition returns a defined value');
		is($disk_type->{name}, $hook->basename . '.disk-data',
			'name is prefixed with basename and disk- prefix');
		is($disk_type->{disk_size}, 64 * 1024,
			'gigabytes(64) correctly converts to 65536 MB for disk_size');
	};

	# 2b. for_scale resolves dev disk size
	subtest 'for_scale resolves dev disk size' => sub {
		plan tests => 1;

		my $hook = make_hook();
		my $disk_type = $hook->disk_type_definition('bosh',
			common => {
				disk_size => $hook->for_scale({ dev => gigabytes(64), prod => gigabytes(128) }, gigabytes(96)),
			},
			cloud_properties_for_iaas => {
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		cmp_deeply($disk_type, {
			'name' => $hook->basename . '.disk-bosh',
			'disk_size' => 64 * 1024,
			'cloud_properties' => { 'type' => 'storage_premium_perf6' }
		}, 'disk_type_definition returns correct dev-scale disk size (64 GB)');
	};

	# 2c. for_scale resolves prod disk size
	subtest 'for_scale resolves prod disk size' => sub {
		plan tests => 1;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('scale' => 'prod');
		my $disk_type = $hook->disk_type_definition('bosh',
			common => {
				disk_size => $hook->for_scale({ dev => gigabytes(64), prod => gigabytes(128) }, gigabytes(96)),
			},
			cloud_properties_for_iaas => {
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		cmp_deeply($disk_type, {
			'name' => $hook->basename . '.disk-bosh',
			'disk_size' => 128 * 1024,
			'cloud_properties' => { 'type' => 'storage_premium_perf6' }
		}, 'disk_type_definition returns correct prod-scale disk size (128 GB)');
	};

	# 2d. for_scale resolves default disk size for unknown scale
	subtest 'for_scale resolves default disk size for unknown scale' => sub {
		plan tests => 1;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('scale' => 'canary');
		my $disk_type = $hook->disk_type_definition('bosh',
			common => {
				disk_size => $hook->for_scale({ dev => gigabytes(64), prod => gigabytes(128) }, gigabytes(96)),
			},
			cloud_properties_for_iaas => {
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		cmp_deeply($disk_type, {
			'name' => $hook->basename . '.disk-bosh',
			'disk_size' => 96 * 1024,
			'cloud_properties' => { 'type' => 'storage_premium_perf6' }
		}, 'disk_type_definition returns correct default-scale disk size (96 GB)');
	};

	# 2e. IaaS selection for disk types
	subtest 'cloud_properties_for_iaas selects correct IaaS properties for disk' => sub {
		plan tests => 2;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('iaas' => 'aws');
		my $disk_type = $hook->disk_type_definition('bosh',
			common => { disk_size => gigabytes(64) },
			cloud_properties_for_iaas => {
				aws => { 'type' => 'gp3' },
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		cmp_deeply($disk_type, {
			'name' => $hook->basename . '.disk-bosh',
			'disk_size' => 64 * 1024,
			'cloud_properties' => { 'type' => 'gp3' }
		}, 'disk_type_definition selects aws cloud_properties when iaas is aws');

		# When IaaS has no match but common is present, name+common fields remain
		$env->_mock_set_responses('iaas' => 'vsphere');
		my $disk_type_no_cp = $hook->disk_type_definition('bosh',
			common => { disk_size => gigabytes(64) },
			cloud_properties_for_iaas => {
				aws => { 'type' => 'gp3' },
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		cmp_deeply($disk_type_no_cp, {
			'name' => $hook->basename . '.disk-bosh',
			'disk_size' => 64 * 1024,
		}, 'disk_type_definition returns common properties without cloud_properties when IaaS not in map');
	};
};

# ===========================================================================
# 3. vm_extension_definition
# ===========================================================================
subtest 'vm_extension_definition' => sub {
	plan tests => 4;

	# 3a. Name is used verbatim (not prefixed with basename)
	subtest 'name is used verbatim without basename prefix' => sub {
		plan tests => 2;

		my $hook = make_hook();
		my $ext = $hook->vm_extension_definition('100GB_ephemeral_disk', {
			cloud_properties_for_iaas => {
				openstack => { ephemeral_disk => { size => 102400 } },
			},
		});
		ok(defined $ext, 'vm_extension_definition returns a defined value for matching IaaS');
		is($ext->{name}, '100GB_ephemeral_disk',
			'vm extension name is used verbatim, not prefixed with basename');
	};

	# 3b. cloud_properties_for_iaas key triggers IaaS lookup
	subtest 'cloud_properties_for_iaas key triggers IaaS-based property selection' => sub {
		plan tests => 1;

		my $hook = make_hook();
		my $ext = $hook->vm_extension_definition('cf-router-network-properties', {
			cloud_properties_for_iaas => {
				openstack => {
					'security_groups' => ['cf-public'],
				},
				aws => {
					'lb_target_groups' => ['cf-router-lb'],
				},
			},
		});
		cmp_deeply($ext, {
			name => 'cf-router-network-properties',
			cloud_properties => {
				'security_groups' => ['cf-public'],
			},
		}, 'vm_extension_definition selects openstack cloud_properties correctly');
	};

	# 3c. Returns empty list when no cloud_properties for current IaaS
	subtest 'returns empty list when IaaS has no cloud properties' => sub {
		plan tests => 1;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('iaas' => 'vsphere');
		my @result = $hook->vm_extension_definition('some-extension', {
			cloud_properties_for_iaas => {
				openstack => { 'security_groups' => ['default'] },
				aws => { 'lb_target_groups' => ['web-lb'] },
			},
		});
		is(scalar(@result), 0,
			'vm_extension_definition returns empty list when IaaS not in cloud_properties_for_iaas');
	};

	# 3d. Data treated as IaaS map when cloud_properties_for_iaas key is absent
	subtest 'data treated as IaaS map when cloud_properties_for_iaas key is absent' => sub {
		plan tests => 2;

		my $hook = make_hook();
		# When data itself is the IaaS map (no nested cloud_properties_for_iaas key)
		my $ext = $hook->vm_extension_definition('direct-iaas-extension', {
			openstack => { 'network_type' => 'provider' },
			aws => { 'enhanced_networking' => 1 },
		});
		ok(defined $ext, 'vm_extension_definition returns a value when data is an IaaS map directly');
		is($ext->{name}, 'direct-iaas-extension',
			'name is verbatim when data is used as IaaS map directly');
	};
};

# ===========================================================================
# 4. override processing
# ===========================================================================
subtest 'override processing' => sub {
	plan tests => 4;

	# 4a. vm_type_defaults override merges into all vm_type definitions
	subtest 'vm_type_defaults are merged into vm_type definitions' => sub {
		plan tests => 2;

		my $env = mock_env(
			config => {
				params => { cloud_config_prefix => 'test-env.test' },
				'bosh-configs' => {
					cloud => {
						vm_type_defaults => {
							'cloud_properties' => { 'boot_from_volume' => JSON::PP::true },
						},
					},
				},
			},
		);
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		my $vm_type = $hook->vm_type_definition('web',
			cloud_properties_for_iaas => {
				openstack => { 'instance_type' => 'm1.medium' },
			},
		);

		ok(defined $vm_type, 'vm_type_definition returns a value with defaults override');
		is($vm_type->{cloud_properties}{'boot_from_volume'}, JSON::PP::true,
			'vm_type_defaults boot_from_volume is merged into vm_type cloud_properties');
	};

	# 4b. vm_types specific override replaces properties for named target
	subtest 'vm_types specific override replaces properties for named vm_type' => sub {
		plan tests => 2;

		my $env = mock_env(
			config => {
				params => { cloud_config_prefix => 'test-env.test' },
				'bosh-configs' => {
					cloud => {
						vm_types => {
							worker => {
								'cloud_properties' => {
									'instance_type' => 'c4.4xlarge',
									'root_disk' => { 'size' => 50 },
								},
							},
						},
					},
				},
			},
		);
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		my $vm_type = $hook->vm_type_definition('worker',
			cloud_properties_for_iaas => {
				openstack => { 'instance_type' => 'm1.medium' },
			},
		);

		ok(defined $vm_type, 'vm_type_definition returns a value with specific vm_types override');
		is($vm_type->{cloud_properties}{'instance_type'}, 'c4.4xlarge',
			'specific vm_types override replaces instance_type in cloud_properties');
	};

	# 4c. env_config_overrides via matching_vm_types conditionally applies overrides
	subtest 'matching_vm_types conditionally applies overrides based on conditions' => sub {
		plan tests => 2;

		my $env = mock_env(
			config => {
				params => { cloud_config_prefix => 'test-env.test' },
				'bosh-configs' => {
					cloud => {
						matching_vm_types => [
							{
								conditions => [
									{ 'name' => '/\.vm-large$/' },
								],
								properties => {
									'cloud_properties' => { 'instance_type' => 'm1.xlarge' },
								},
							},
						],
					},
				},
			},
		);
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		# This vm type name ends in .vm-large, so the matching rule fires
		my $large = $hook->vm_type_definition('large',
			cloud_properties_for_iaas => {
				openstack => { 'instance_type' => 'm1.small' },
			},
		);
		is($large->{cloud_properties}{'instance_type'}, 'm1.xlarge',
			'matching_vm_types override applies when condition matches name pattern');

		# This vm type name does NOT end in .vm-large, so the rule does not fire
		my $small = $hook->vm_type_definition('small',
			cloud_properties_for_iaas => {
				openstack => { 'instance_type' => 'm1.small' },
			},
		);
		is($small->{cloud_properties}{'instance_type'}, 'm1.small',
			'matching_vm_types override does not apply when condition does not match');
	};

	# 4d. matching_networks is refused until it is implemented, so an env file
	# carrying rules that would silently do nothing fails at hook init
	subtest 'matching_networks is rejected by the override schema' => sub {
		plan tests => 1;

		my $env = mock_env(
			config => {
				params => { cloud_config_prefix => 'test-env.test' },
				'bosh-configs' => {
					cloud => {
						matching_networks => [
							{
								conditions => [ { 'az' => 'az3' } ],
								properties => { 'dns' => ['10.4.0.2'] },
							},
						],
					},
				},
			},
		);
		throws_ok { Genesis::Hook::CloudConfig::Bosh->init(env => $env) }
			qr/bosh-configs\.cloud\.matching_networks is not yet supported.*subnet_defaults/s,
			'init refuses an env file carrying matching_networks and names the working overrides';
	};
};

# ===========================================================================
# 5. _evaluate_matching_rule pattern forms
# ===========================================================================
subtest '_evaluate_matching_rule - every pattern form' => sub {
	plan tests => 9;

	my $hook = make_hook();
	my $config = {name => 'x.vm-large', 'cloud_properties.instance_type' => 'm1.small'};
	my $props  = {size => 1};
	my $rule   = sub { {conditions => [@_], properties => $props} };

	is_deeply($hook->_evaluate_matching_rule('large', $rule->({name => '!~/\.vm-large$/'}), $config), {},
		'a negated regex does not match a name it would otherwise match');
	is_deeply($hook->_evaluate_matching_rule('large', $rule->({name => '!~/\.vm-small$/'}), $config), $props,
		'a negated regex matches a name the regex does not');
	is_deeply($hook->_evaluate_matching_rule('large', $rule->({'cloud_properties.instance_type' => 'm1.small'}), $config), $props,
		'a dotted key names a flattened config key and matches a literal');
	is_deeply($hook->_evaluate_matching_rule('large', $rule->({'cloud_properties.instance_type' => '/^m1\./'}), $config), $props,
		'a dotted key matches a regex');
	is_deeply($hook->_evaluate_matching_rule('large', $rule->({'cloud_properties.instance_type' => ['m1.tiny', 'm1.small']}), $config), $props,
		'a list of literals matches when any literal equals the field');
	is_deeply($hook->_evaluate_matching_rule('large', $rule->({'cloud_properties.nonexistent' => undef}), $config), $props,
		'a null pattern matches a field the config does not carry');
	is_deeply($hook->_evaluate_matching_rule('large', $rule->({name => '/\.vm-large$/', 'cloud_properties.instance_type' => 'm1.huge'}), $config), {},
		'every field in a condition set must match');
	is_deeply($hook->_evaluate_matching_rule('large', $rule->({name => '/nope/'}, {name => '/\.vm-large$/'}), $config), $props,
		'a rule applies when any one of its condition sets matches');
	throws_ok { $hook->_evaluate_matching_rule('large', $rule->({cloud_properties => {instance_type => 'm1.small'}}), $config) }
		qr/must name a flattened\s+config key.*cloud_properties\.<subkey>/s,
		'a nested map as a condition is refused and told the flat form';
};

# ===========================================================================
# 6. _add_extended_cloud_config <based-on>
# ===========================================================================
subtest '_add_extended_cloud_config - <based-on> inheritance' => sub {
	plan tests => 11;

	# The kit defines one vm type, 'base'.  Each case adds extended entries
	# under bosh-configs.cloud and asserts what reaches the cloud config.
	my $kit_config = sub {
		my ($hook) = @_;
		return {vm_types => [{
			name => $hook->name_for('vm', 'base'),
			cloud_properties => {instance_type => 'm1.small', boot_from_volume => 1},
		}]};
	};
	my $hook_with = sub {
		my (%cloud) = @_;
		my $env = mock_env(config => {
			params => {cloud_config_prefix => 'test-env.test'},
			'bosh-configs' => {cloud => \%cloud},
		});
		return Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	};
	my $built = sub {
		my ($hook, $group, $name) = @_;
		my $config = $hook->_add_extended_cloud_config($kit_config->($hook));
		my ($entry) = grep {$_->{name} eq $name} @{$config->{$group}};
		return $entry // {}; # an entry that was never emitted fails its assertion rather than dying
	};

	# 1. inherit from a kit entry
	my $hook = $hook_with->(vm_types => {big => {'<based-on>' => 'base', cloud_properties => {instance_type => 'm1.large'}}});
	is_deeply($built->($hook, 'vm_types', $hook->name_for('vm', 'big'))->{cloud_properties},
		{instance_type => 'm1.large', boot_from_volume => 1},
		'a target based on a kit entry inherits its properties and overrides the ones it names');

	# 2. a chain of extended entries resolves whatever order the hash yields
	$hook = $hook_with->(vm_types => {
		a => {'<based-on>' => 'b',    cloud_properties => {a => 1}},
		b => {'<based-on>' => 'c',    cloud_properties => {b => 1}},
		c => {'<based-on>' => 'base', cloud_properties => {c => 1}},
	});
	is_deeply($built->($hook, 'vm_types', $hook->name_for('vm', 'a'))->{cloud_properties},
		{instance_type => 'm1.small', boot_from_volume => 1, a => 1, b => 1, c => 1},
		'a chain of extended targets resolves in full, each deferred until its source is built');

	# 3. two entries sharing one deferred source both get it
	$hook = $hook_with->(vm_types => {
		x => {'<based-on>' => 'z', cloud_properties => {x => 1}},
		y => {'<based-on>' => 'z', cloud_properties => {y => 1}},
		z => {'<based-on>' => 'base', cloud_properties => {z => 1}},
	});
	my $config = $hook->_add_extended_cloud_config($kit_config->($hook));
	my %by_name = map {$_->{name} => $_} @{$config->{vm_types}};
	is_deeply([map {$by_name{$hook->name_for('vm', $_)}{cloud_properties}{z}} qw(x y)], [1, 1],
		'two targets based on the same deferred source both inherit from it');

	# 4. the environment's config is left as the operator wrote it
	$hook = $hook_with->(vm_types => {big => {'<based-on>' => 'base', cloud_properties => {instance_type => 'm1.large'}}});
	$hook->_add_extended_cloud_config($kit_config->($hook));
	is($hook->env->config->{'bosh-configs'}{cloud}{vm_types}{big}{'<based-on>'}, 'base',
		'processing an extended entry does not strip the meta-key from the environment config');
	is_deeply($built->($hook, 'vm_types', $hook->name_for('vm', 'big'))->{cloud_properties},
		{instance_type => 'm1.large', boot_from_volume => 1},
		'a second build in the same process inherits exactly as the first did');

	# 5. missing source
	$hook = $hook_with->(vm_types => {big => {'<based-on>' => 'nowhere'}});
	throws_ok { $hook->_add_extended_cloud_config($kit_config->($hook)) }
		qr/depends on 'nowhere'.*does not exist/s,
		'a source that is neither a kit entry nor an extended target is refused';

	# 6. cycles of every length
	$hook = $hook_with->(vm_types => {a => {'<based-on>' => 'b'}, b => {'<based-on>' => 'a'}});
	throws_ok { $hook->_add_extended_cloud_config($kit_config->($hook)) }
		qr/Cyclic dependency/,
		'two targets based on each other are refused';
	$hook = $hook_with->(vm_types => {a => {'<based-on>' => 'a'}});
	throws_ok { $hook->_add_extended_cloud_config($kit_config->($hook)) }
		qr/Cyclic dependency/,
		'a target based on itself is refused';
	$hook = $hook_with->(vm_types => {a => {'<based-on>' => 'b'}, b => {'<based-on>' => 'c'}, c => {'<based-on>' => 'a'}});
	throws_ok { $hook->_add_extended_cloud_config($kit_config->($hook)) }
		qr/Cyclic dependency/,
		'a three-link cycle is refused rather than deferred forever';

	# 7. explicit naming
	$hook = $hook_with->(disk_types => {'shared-storage' => {'<explicit-name>' => 1, disk_size => 1024}});
	ok($built->($hook, 'disk_types', 'shared-storage'),
		'an entry with <explicit-name> is emitted under its bare name');

	# 8. a new entry inherits the source as built, overrides and defaults included
	$hook = $hook_with->(
		vm_type_defaults => {cloud_properties => {encrypted => 1}},
		vm_types => {
			base => {cloud_properties => {instance_type => 'm1.medium'}},
			big  => {'<based-on>' => 'base', cloud_properties => {boot_from_volume => 0}},
		},
	);
	$config = {vm_types => [$hook->vm_type_definition('base', cloud_properties_for_iaas => {openstack => {instance_type => 'm1.small'}})]};
	$hook->build_cloud_config($config);
	my ($big) = grep {$_->{name} eq $hook->name_for('vm', 'big')} @{$config->{vm_types}};
	is_deeply($big->{cloud_properties}, {instance_type => 'm1.medium', encrypted => 1, boot_from_volume => 0},
		'a new entry inherits its source as built, with the source\'s own overrides and defaults applied');
};

subtest '_process_config_overrides - meta-keys on a kit-defined entry are refused' => sub {
	plan tests => 2;

	for my $meta ('<based-on>', '<explicit-name>') {
		my $env = mock_env(config => {
			params => {cloud_config_prefix => 'test-env.test'},
			'bosh-configs' => {cloud => {vm_types => {web => {$meta => 'base', cloud_properties => {instance_type => 'm1.large'}}}}},
		});
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
		throws_ok { $hook->vm_type_definition('web', cloud_properties_for_iaas => {openstack => {instance_type => 'm1.small'}}) }
			qr/vm_type 'web'.*\Q$meta\E.*kit already defines/s,
			"$meta on an override of a kit-defined vm_type is refused rather than emitted as a property";
	}
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
