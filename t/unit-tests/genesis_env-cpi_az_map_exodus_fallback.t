#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

use Test::More;
use Test::Exception;

use_ok 'Genesis::Env';

# ---------------------------------------------------------------------------
# When manifest_lookup('azs', []) is empty for a director-deployed env, the
# fallback reads from the parent director's exodus /network entry.  Same
# source Genesis::Hook::CloudConfig::network() uses.  The extraction inverts
# the exodus per-az structure into the array-of-hashref shape cpi_az_map's
# downstream code already knows how to consume.
#
# Exodus /network az schema (as observed on real deployed mgmt directors):
#
#   azs.<key>.name           - rendered name under mgmt's default CPI
#   azs.<key>.cloud_properties (opaque to us)
#   azs.<key>.index          - opaque to us
#   azs.<key>.for_cpi.<cpi_name> - rendered name under a named CPI
#
# The stored form has `~` as a placeholder for `.` in flat keys; unflatten
# reverses that, so runtime keys have real dots.
# ---------------------------------------------------------------------------

# Stub $env's collaborators so cpi_az_map can be exercised in isolation.
# Each stub lets a test override just the accessors it cares about.
sub make_env {
	my (%stubs) = @_;
	my $env = bless {%stubs}, 'Genesis::Env';
	no warnings 'redefine', 'once';
	local *Genesis::Env::instance_group_azs = sub {
		@{$_[0]->{__instance_group_azs} // []};
	};
	local *Genesis::Env::manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return $self->{__manifest_azs} if $key eq 'azs';
		return $default;
	};
	local *Genesis::Env::use_create_env = sub {
		$_[0]->{__use_create_env} // 0;
	};
	local *Genesis::Env::director_exodus_lookup = sub {
		my ($self, $key) = @_;
		return $self->{__director_network} if $key eq '/network';
		return undef;
	};
	local *Genesis::Env::bosh = sub {
		bless {alias => $_[0]->{__bosh_alias} // 'test-mgmt'}, 'Test::FakeBosh';
	};
	$env->cpi_az_map;   # trigger under stubs
}
{
	package Test::FakeBosh;
	sub alias { $_[0]->{alias} }
}

# AWS-sample-shape fixture (from real mgmt env dump)
sub aws_sample_network {
	return {
		azs => {
			'us-east-1a' => {
				name             => 'ocfp-aws-mgmt-us-east-1-z1',
				cloud_properties => '{"availability_zone":"us-east-1a"}',
				index            => '1',
				for_cpi          => {
					'ocfp-aws-lab-ocf-us-east-1.aws.bosh' => 'ocfp-aws-lab-ocf-us-east-1-z1',
				},
			},
			'us-east-1b' => {
				name    => 'ocfp-aws-mgmt-us-east-1-z2',
				index   => '2',
				for_cpi => {
					'ocfp-aws-lab-ocf-us-east-1.aws.bosh' => 'ocfp-aws-lab-ocf-us-east-1-z2',
				},
			},
			'us-east-1c' => {
				name    => 'ocfp-aws-mgmt-us-east-1-z3',
				index   => '3',
				for_cpi => {
					'ocfp-aws-lab-ocf-us-east-1.aws.bosh' => 'ocfp-aws-lab-ocf-us-east-1-z3',
				},
			},
		},
	};
}

# PVE-sample-shape fixture (6 azs, single child env)
sub pve_sample_network {
	my %azs;
	for my $i (1..6) {
		my $key = 'pve' . chr(ord('a') + $i - 1);   # pvea..pvef
		$azs{$key} = {
			name    => "ocfp-lab-pve-cpi-mgmt-z$i",
			index   => "$i",
			for_cpi => {
				'ocfp-lab-pve-cpi-ocf.pve.bosh' => "ocfp-lab-pve-cpi-ocf-z$i",
			},
		};
	}
	return {azs => \%azs};
}

subtest 'manifest.azs present -> skip fallback (backward compat)' => sub {
	plan tests => 2;

	my $map = make_env(
		__instance_group_azs => ['z1', 'z2'],
		__manifest_azs       => [
			{name => 'z1', cpi => 'aws-east'},
			{name => 'z2'},   # no cpi = <default>
		],
	);

	is_deeply($map->{'aws-east'}, ['z1'],
		'manifest.azs cpi assignment wins over exodus');
	is_deeply($map->{'<default>'}, ['z2'],
		'manifest.azs undef-cpi bucketed under <default>');
};

subtest 'create-env -> skip fallback entirely' => sub {
	plan tests => 1;

	# create-env envs get their azs from their own manifest; they never
	# consult a parent director's /network exodus.  Feeding a populated
	# exodus should NOT be used when use_create_env is true (and would
	# be misleading, so verify the bail happens instead of silent use).
	throws_ok {
		make_env(
			__use_create_env     => 1,
			__instance_group_azs => ['z1'],
			__manifest_azs       => [],
			__director_network   => aws_sample_network(),
		)
	} qr/not present in the cloud-config|use_create_env/i,
		'create-env with empty manifest.azs bails (does not silently pull from exodus)';
};

subtest 'director-deployed, mgmt-default child (AWS sample shape)' => sub {
	plan tests => 2;

	# Child env whose instance_groups reference the mgmt's own rendered
	# az names.  Since none of those names appears in any for_cpi entry
	# from THIS env's POV, they bucket under <default>.
	my $map = make_env(
		__instance_group_azs => [
			'ocfp-aws-mgmt-us-east-1-z1',
			'ocfp-aws-mgmt-us-east-1-z2',
			'ocfp-aws-mgmt-us-east-1-z3',
		],
		__manifest_azs     => [],
		__director_network => aws_sample_network(),
	);

	is_deeply([sort keys %$map], ['<default>'],
		'all three azs bucket under <default> (mgmt-served)');
	is_deeply($map->{'<default>'}, [
		'ocfp-aws-mgmt-us-east-1-z1',
		'ocfp-aws-mgmt-us-east-1-z2',
		'ocfp-aws-mgmt-us-east-1-z3',
	], 'sorted az list under <default>');
};

subtest 'director-deployed, named-cpi child (AWS sample shape)' => sub {
	plan tests => 2;

	# Child env whose instance_groups reference the for_cpi rendered
	# names.  Those bucket under the CPI name that owns them.
	my $map = make_env(
		__instance_group_azs => [
			'ocfp-aws-lab-ocf-us-east-1-z1',
			'ocfp-aws-lab-ocf-us-east-1-z2',
			'ocfp-aws-lab-ocf-us-east-1-z3',
		],
		__manifest_azs     => [],
		__director_network => aws_sample_network(),
	);

	is_deeply([sort keys %$map], ['ocfp-aws-lab-ocf-us-east-1.aws.bosh'],
		'all three azs bucket under the named cpi');
	is_deeply($map->{'ocfp-aws-lab-ocf-us-east-1.aws.bosh'}, [
		'ocfp-aws-lab-ocf-us-east-1-z1',
		'ocfp-aws-lab-ocf-us-east-1-z2',
		'ocfp-aws-lab-ocf-us-east-1-z3',
	], 'sorted az list under the named cpi');
};

subtest 'director-deployed, PVE sample (6 azs)' => sub {
	plan tests => 2;

	my $map = make_env(
		__instance_group_azs => [
			map { "ocfp-lab-pve-cpi-ocf-z$_" } (1..6)
		],
		__manifest_azs     => [],
		__director_network => pve_sample_network(),
	);

	is_deeply([sort keys %$map], ['ocfp-lab-pve-cpi-ocf.pve.bosh'],
		'all six azs bucket under the pve child cpi');
	is scalar(@{$map->{'ocfp-lab-pve-cpi-ocf.pve.bosh'}}), 6,
		'six azs present';
};

subtest 'mixed instance_group_azs (default + named)' => sub {
	plan tests => 3;

	# Some instance groups deploy under mgmt's default, some under the
	# named child cpi.  Both buckets present in the returned map.
	my $map = make_env(
		__instance_group_azs => [
			'ocfp-aws-mgmt-us-east-1-z1',    # default
			'ocfp-aws-lab-ocf-us-east-1-z2', # named
		],
		__manifest_azs     => [],
		__director_network => aws_sample_network(),
	);

	is_deeply([sort keys %$map],
		['<default>', 'ocfp-aws-lab-ocf-us-east-1.aws.bosh'],
		'both cpi buckets present');
	is_deeply($map->{'<default>'}, ['ocfp-aws-mgmt-us-east-1-z1'],
		'mgmt-served az under <default>');
	is_deeply($map->{'ocfp-aws-lab-ocf-us-east-1.aws.bosh'},
		['ocfp-aws-lab-ocf-us-east-1-z2'],
		'child-served az under named cpi');
};

subtest 'missing /network exodus -> bail' => sub {
	plan tests => 1;

	throws_ok {
		make_env(
			__instance_group_azs => ['z1'],
			__manifest_azs       => [],
			__director_network   => undef,
		)
	} qr/no network exodus|deploy the director first/i,
		'undef /network exodus bails with actionable message';
};

subtest 'empty azs in /network -> bail' => sub {
	plan tests => 1;

	throws_ok {
		make_env(
			__instance_group_azs => ['z1'],
			__manifest_azs       => [],
			__director_network   => { azs => {} },
		)
	} qr/no network exodus|deploy the director first/i,
		'empty azs bails same as missing /network';
};

subtest 'unresolvable az in exodus -> still bails via existing check' => sub {
	plan tests => 1;

	# instance_group AZ that doesn't match any exodus name or for_cpi
	# entry: same as the pre-existing "not present in cloud-config"
	# bail -- the fallback resolved SOME azs, just not this one.
	throws_ok {
		make_env(
			__instance_group_azs => ['ghost-az'],
			__manifest_azs       => [],
			__director_network   => aws_sample_network(),
		)
	} qr/not present in the cloud-config/i,
		'unresolvable az bails via existing @unresolvable check';
};

subtest 'child director as parent: no for_cpi, all default' => sub {
	plan tests => 2;

	# A director-deployed BOSH that hosts non-director tenants (e.g. cf
	# deploying against the ocf child director) has no for_cpi entries
	# in its own exodus /network -- only .name.  Tenants of that
	# director all bucket under <default>.  From the PVE ocf sample.
	my $network = {
		azs => {
			map { my $i = $_;
				"pve" . chr(ord('a') + $i - 1) => {
					name    => "ocfp-lab-pve-cpi-ocf-z$i",
					index   => "$i",
				}
			} (1..6),
		},
	};
	my $map = make_env(
		__instance_group_azs => [
			map { "ocfp-lab-pve-cpi-ocf-z$_" } (1..3)
		],
		__manifest_azs     => [],
		__director_network => $network,
	);

	is_deeply([sort keys %$map], ['<default>'],
		'no for_cpi entries -> everything under <default>');
	is scalar(@{$map->{'<default>'}}), 3,
		'three azs from tenant';
};

subtest 'multi-child hypothetical: two for_cpi entries per az' => sub {
	plan tests => 3;

	# Simulates a mgmt director hosting TWO child envs.  Each az has
	# two for_cpi entries.  Extraction should produce entries for both
	# child cpi names.
	my $network = {
		azs => {
			'z1' => {
				name    => 'mgmt-z1',
				for_cpi => {
					'child-a.aws.bosh' => 'child-a-z1',
					'child-b.aws.bosh' => 'child-b-z1',
				},
			},
			'z2' => {
				name    => 'mgmt-z2',
				for_cpi => {
					'child-a.aws.bosh' => 'child-a-z2',
					'child-b.aws.bosh' => 'child-b-z2',
				},
			},
		},
	};

	my $map = make_env(
		__instance_group_azs => ['child-a-z1', 'child-b-z2'],
		__manifest_azs       => [],
		__director_network   => $network,
	);

	is_deeply([sort keys %$map],
		['child-a.aws.bosh', 'child-b.aws.bosh'],
		'both child cpis present');
	is_deeply($map->{'child-a.aws.bosh'}, ['child-a-z1'],
		'child-a azs correctly attributed');
	is_deeply($map->{'child-b.aws.bosh'}, ['child-b-z2'],
		'child-b azs correctly attributed');
};

done_testing;
