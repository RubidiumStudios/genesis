#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;

use Genesis;
$Genesis::VERSION = '999.999.999';
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Helper: build a standard non-create-env environment backed by 'simple' kit
sub make_simple_env {
	my ($env_name, %extra_genesis) = @_;
	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	my $genesis_block = "  env: $env_name\n";
	for my $k (keys %extra_genesis) {
		$genesis_block .= "  $k: $extra_genesis{$k}\n";
	}

	put_file($top->path("$env_name.yml"), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
$genesis_block
EOF

	return $top->load_env($env_name);
}

# Helper: build a create-env environment backed by 'bosh-3.0.0-create-env' kit
sub make_create_env {
	my ($env_name) = @_;
	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/bosh-3.0.0-create-env');

	put_file($top->path("$env_name.yml"), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: $env_name
EOF

	return $top->load_env($env_name);
}

# ======================================================================
# configs()
# ======================================================================

subtest 'configs - empty when nothing registered' => sub {
	plan tests => 3;

	# Isolate from any GENESIS_*_CONFIG vars in the outer environment
	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('no-configs');
	$env->{__configs} = {};

	my @list = $env->configs;
	is(scalar(@list), 0, 'configs() returns empty list when nothing registered');

	my $ref = $env->configs;
	is(ref($ref), 'ARRAY', 'configs() in scalar context returns an arrayref');
	is(scalar(@{$ref}), 0, 'configs() arrayref is empty when nothing registered');
};

subtest 'configs - picks up GENESIS_CLOUD_CONFIG env var' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('cloud-env-var');
	$env->{__configs} = {};

	local $ENV{GENESIS_CLOUD_CONFIG} = '/tmp/cloud.yml';

	my @list = $env->configs;
	is(scalar(@list), 1, 'configs() returns one entry when GENESIS_CLOUD_CONFIG set');
	is($list[0], 'cloud', 'configs() returns "cloud" from GENESIS_CLOUD_CONFIG');
};

subtest 'configs - picks up GENESIS_RUNTIME_CONFIG env var' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('runtime-env-var');
	$env->{__configs} = {};

	local $ENV{GENESIS_RUNTIME_CONFIG} = '/tmp/runtime.yml';

	my @list = $env->configs;
	is(scalar(@list), 1, 'configs() returns one entry when GENESIS_RUNTIME_CONFIG set');
	is($list[0], 'runtime', 'configs() returns "runtime" from GENESIS_RUNTIME_CONFIG');
};

subtest 'configs - use_config registers in both __configs and returns via configs()' => sub {
	plan tests => 3;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('use-config-test');
	$env->{__configs} = {};

	# use_config sets both __configs and the env var
	$env->use_config('/tmp/cloud.yml', 'cloud');

	my @list = $env->configs;
	is(scalar(@list), 1, 'configs() returns 1 entry after use_config(cloud)');
	is($list[0], 'cloud', 'configs() returns "cloud" after use_config(cloud)');

	$env->use_config('/tmp/runtime.yml', 'runtime');
	my @both = sort $env->configs;
	is(scalar(@both), 2, 'configs() returns 2 entries after use_config(cloud) and use_config(runtime)');
};

subtest 'configs - scalar context returns arrayref' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('scalar-context');
	$env->{__configs} = {};
	$env->use_config('/tmp/cloud.yml', 'cloud');

	my $ref = $env->configs;
	is(ref($ref), 'ARRAY', 'configs() scalar context returns arrayref');
	is($ref->[0], 'cloud', 'arrayref contains "cloud"');
};

# ======================================================================
# required_configs()
# ======================================================================

subtest 'required_configs - returns empty list for create-env environments' => sub {
	plan tests => 2;

	my $env = make_create_env('create-env-test');
	ok($env->use_create_env, 'sanity: environment is a create-env');

	my @required = $env->required_configs('blueprint');
	is(scalar(@required), 0, 'required_configs(blueprint) returns empty list for create-env');
};

subtest 'required_configs - blueprint hook requires cloud and cpi' => sub {
	# Contract changed in FWT-983 Step 6: Env appends cpi to
	# manifest-track hook results so cpi configs are surfaced in
	# the upfront "Downloading configs from..." block.  Kit-level
	# required_configs still returns ('cloud') only -- the cpi
	# append is an Env-layer concern.
	plan tests => 2;

	my $env = make_simple_env('req-blueprint');

	my @required = $env->required_configs('blueprint');
	is_deeply [sort @required], [qw(cloud cpi)],
		'required_configs(blueprint) returns cloud + cpi (Step-6 append)';
	ok((grep { $_ eq 'cloud' } @required),
		'cloud is still required (kit-level)');
};

subtest 'required_configs - manifest hook requires cloud and cpi' => sub {
	# Same contract change as blueprint subtest above.
	plan tests => 2;

	my $env = make_simple_env('req-manifest');

	my @required = $env->required_configs('manifest');
	is_deeply [sort @required], [qw(cloud cpi)],
		'required_configs(manifest) returns cloud + cpi (Step-6 append)';
	ok((grep { $_ eq 'cloud' } @required),
		'cloud is still required (kit-level)');
};

subtest 'required_configs - check hook requires cloud and cpi unless GENESIS_CONFIG_NO_CHECK' => sub {
	# Same contract change as blueprint/manifest subtests.
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{GENESIS_CONFIG_NO_CHECK};

	my $env = make_simple_env('req-check');

	my @required = $env->required_configs('check');
	is_deeply [sort @required], [qw(cloud cpi)],
		'required_configs(check) returns cloud + cpi by default (Step-6 append)';
	ok((grep { $_ eq 'cloud' } @required),
		'cloud is still required (kit-level)');
};

subtest 'required_configs - check hook requires nothing when GENESIS_CONFIG_NO_CHECK set' => sub {
	plan tests => 1;

	local $ENV{GENESIS_CONFIG_NO_CHECK} = '1';

	my $env = make_simple_env('req-check-skip');

	my @required = $env->required_configs('check');
	is(scalar(@required), 0, 'required_configs(check) returns empty when GENESIS_CONFIG_NO_CHECK set');
};

subtest 'required_configs - explicit blueprint hook requires cloud and cpi when called directly' => sub {
	# Same FWT-983 Step-6 contract change as the other manifest-
	# track subtests: cpi joins cloud in the Env-layer result.
	plan tests => 2;

	my $env = make_simple_env('req-direct');

	my @required = $env->required_configs('blueprint');
	is_deeply [sort @required], [qw(cloud cpi)],
		'required_configs(blueprint) called directly returns cloud + cpi (Step-6 append)';
	ok((grep { $_ eq 'cloud' } @required),
		'cloud is still required (kit-level)');
};

# ======================================================================
# has_config() and config_file()
# ======================================================================

subtest 'has_config - false when config not registered' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('has-config-false');
	$env->{__configs} = {};

	ok(!$env->has_config('cloud'),   'has_config(cloud) is false when not registered');
	ok(!$env->has_config('runtime'), 'has_config(runtime) is false when not registered');
};

subtest 'has_config - true after use_config registers it' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('has-config-true');
	$env->{__configs} = {};

	$env->use_config('/tmp/cloud.yml', 'cloud');
	ok($env->has_config('cloud'),    'has_config(cloud) is true after use_config(cloud)');
	ok(!$env->has_config('runtime'), 'has_config(runtime) is still false');
};

subtest 'has_config - true when GENESIS_CLOUD_CONFIG env var is set' => sub {
	plan tests => 1;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('has-config-env');
	$env->{__configs} = {};

	local $ENV{GENESIS_CLOUD_CONFIG} = '/tmp/cloud.yml';
	ok($env->has_config('cloud'), 'has_config(cloud) is true when GENESIS_CLOUD_CONFIG env var is set');
};

subtest 'has_config - with named config (type@name)' => sub {
	plan tests => 3;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('has-config-named');
	$env->{__configs} = {};

	$env->use_config('/tmp/cloud-az1.yml', 'cloud', 'az1');

	ok($env->has_config('cloud', 'az1'),
		'has_config(cloud, az1) is true after use_config with name');
	ok(!$env->has_config('cloud'),
		'has_config(cloud) without name is false (different label)');
	ok(!$env->has_config('cloud', 'az2'),
		'has_config(cloud, az2) is false for a different name');
};

# ======================================================================
# missing_required_configs()
# ======================================================================

subtest 'missing_required_configs - all required when none registered' => sub {
	# FWT-983 Step 6: required_configs(blueprint) now returns both
	# cloud AND cpi.  With nothing registered, both are missing.
	plan tests => 1;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('missing-all');
	$env->{__configs} = {};

	my @missing = $env->missing_required_configs('blueprint');
	is_deeply [sort @missing], [qw(cloud cpi)],
		'missing_required_configs(blueprint) returns cloud + cpi when nothing registered';
};

subtest 'missing_required_configs - cpi still missing when only cloud registered' => sub {
	# FWT-983 Step 6: cpi joined the required set.  Registering only
	# cloud leaves cpi as the lone missing config.
	plan tests => 1;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('missing-cpi-only');
	$env->{__configs} = {};

	$env->use_config('/tmp/cloud.yml', 'cloud');

	my @missing = $env->missing_required_configs('blueprint');
	is_deeply [@missing], ['cpi'],
		'cpi remains in missing list until use_config(cpi) is also called';
};

subtest 'missing_required_configs - empty for create-env environments' => sub {
	plan tests => 1;

	my $env = make_create_env('missing-create-env');

	my @missing = $env->missing_required_configs('deploy');
	is(scalar(@missing), 0, 'missing_required_configs() returns empty list for create-env');
};

# ======================================================================
# has_required_configs()
# ======================================================================

subtest 'has_required_configs - false when required configs absent' => sub {
	plan tests => 1;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('hrc-false');
	$env->{__configs} = {};

	ok(!$env->has_required_configs('blueprint'),
		'has_required_configs(blueprint) is false when cloud config not registered');
};

subtest 'has_required_configs - true when all required configs present' => sub {
	# FWT-983 Step 6: cpi joined the required set.  has_required_configs
	# now only returns true once BOTH cloud and cpi are registered.
	plan tests => 1;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('hrc-true');
	$env->{__configs} = {};

	$env->use_config('/tmp/cloud.yml', 'cloud');
	$env->use_config('/tmp/cpi.yml',   'cpi');

	ok($env->has_required_configs('blueprint'),
		'has_required_configs(blueprint) is true when both cloud and cpi are registered');
};

subtest 'has_required_configs - always true for create-env environments' => sub {
	plan tests => 1;

	my $env = make_create_env('hrc-create-env');

	ok($env->has_required_configs('deploy'),
		'has_required_configs(deploy) is always true for create-env environments');
};

subtest 'has_required_configs - true when hook requires no configs' => sub {
	plan tests => 1;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('hrc-no-req');
	$env->{__configs} = {};

	# cloud-config hook is special-cased in Kit::required_configs to return ()
	ok($env->has_required_configs('cloud-config'),
		'has_required_configs(cloud-config) is true (no configs required for this hook)');
};

# ======================================================================
# bosh-configs key validation
# ======================================================================

sub load_env_with_bosh_configs {
	my ($env_name, $bosh_configs_yaml) = @_;
	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path("$env_name.yml"), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: $env_name
bosh-configs:
$bosh_configs_yaml
EOF

	return $top->load_env($env_name);
}

subtest 'bosh-configs validation - accepts director-cpi key' => sub {
	plan tests => 1;

	lives_ok {
		load_env_with_bosh_configs('cpi-inline', <<'YAML');
  director-cpi:
    name: default
    cpis:
    - name: vsphere-prod
      type: vsphere
      properties:
        host: vcenter.example.com
YAML
	} 'bosh-configs.director-cpi is an accepted key';
};

subtest 'bosh-configs validation - rejects unknown key' => sub {
	plan tests => 1;

	throws_ok {
		load_env_with_bosh_configs('cpi-junk', <<'YAML');
  totally-bogus:
    nope: true
YAML
	} qr/totally-bogus.*is invalid/ms,
		'unknown bosh-configs.<key> is still rejected';
};

subtest 'bosh-configs validation - director-cpi.default alone is allowed (advertise-only)' => sub {
	plan tests => 1;

	lives_ok {
		load_env_with_bosh_configs('cpi-default-only', <<'YAML');
  director-cpi:
    default: externally-uploaded-cpi
YAML
	} 'director-cpi.default without cpis: is allowed (advertise-only path)';
};

subtest 'bosh-configs validation - director-cpi.name without cpis bails' => sub {
	plan tests => 1;

	throws_ok {
		load_env_with_bosh_configs('cpi-name-no-cpis', <<'YAML');
  director-cpi:
    name: orphan-name
YAML
	} qr/director-cpi\.name.*requires.*cpis/ims,
		'director-cpi.name without cpis: is rejected (name has no meaning without upload)';
};

# ======================================================================
# Env::required_configs - cpi added for check/manifest/blueprint/deploy
# (FWT-983 Step 6)
# ======================================================================
#
# When the env will exercise check, manifest, blueprint, or deploy
# hooks, cpi configs should be in the upfront required set so the
# "Downloading configs from..." block surfaces them alongside cloud
# and runtime.  download_configs treats cpi as always-optional so
# single-iaas envs (no cpi configs uploaded) gracefully no-op.

subtest 'required_configs - includes cpi for check hook' => sub {
	plan tests => 1;
	my $env = make_simple_env('rc-check');
	my @configs = $env->required_configs('check');
	ok((grep { $_ eq 'cpi' } @configs),
		'cpi appears in required_configs for the check hook');
};

subtest 'required_configs - includes cpi for manifest hook' => sub {
	plan tests => 1;
	my $env = make_simple_env('rc-manifest');
	my @configs = $env->required_configs('manifest');
	ok((grep { $_ eq 'cpi' } @configs),
		'cpi appears in required_configs for the manifest hook');
};

subtest 'required_configs - includes cpi for blueprint hook' => sub {
	plan tests => 1;
	my $env = make_simple_env('rc-blueprint');
	my @configs = $env->required_configs('blueprint');
	ok((grep { $_ eq 'cpi' } @configs),
		'cpi appears in required_configs for the blueprint hook');
};

subtest 'required_configs - includes cpi for deploy expansion' => sub {
	plan tests => 1;
	# 'deploy' expands to blueprint+check+manifest (+ pre/post if kit
	# has them).  cpi should be in the union.
	my $env = make_simple_env('rc-deploy');
	my @configs = $env->required_configs('deploy');
	ok((grep { $_ eq 'cpi' } @configs),
		'cpi appears in required_configs for the deploy hook expansion');
};

subtest 'required_configs - cloud-config-only hook does NOT include cpi' => sub {
	plan tests => 1;
	# The cloud-config hook is the kit-side compute of the cloud
	# config itself.  It runs WITHOUT any uploaded configs and
	# returning cpi here would create a chicken-and-egg loop.
	my $env = make_simple_env('rc-cc-only');
	my @configs = $env->required_configs('cloud-config');
	ok(!(grep { $_ eq 'cpi' } @configs),
		'cpi is NOT added for the cloud-config-only path');
};

subtest 'required_configs - create-env returns empty regardless' => sub {
	plan tests => 1;
	# create-env has no parent director, so no configs at all (kit-
	# specified or otherwise).  The cpi append must not contaminate
	# this path.
	my $env = make_create_env('rc-create');
	my @configs = $env->required_configs('check');
	is_deeply [@configs], [],
		'create-env returns empty list -- cpi is not appended';
};

# ======================================================================
# Env::download_configs - opts threading to the Director (FWT-983)
# ======================================================================
#
# After Step 3, Director::download_configs accepts `optional => 1`
# (and `refresh => 1`).  Env::download_configs is the orchestrator
# that walks @specs and dispatches per-type; it needs to forward
# those opts so env-level callers can use the new knobs without
# reaching past Env into Director directly.
#
# Calling convention: trailing hashref of opts.
#   $env->download_configs('cpi', { optional => 1 });
#   $env->download_configs(qw/cloud runtime/, { refresh => 1 });

subtest 'download_configs - silently skips cpi spec when no cpi configs uploaded' => sub {
	# FWT-983 Step 6: cpi joined the required-configs set, but
	# single-iaas envs have no cpi configs uploaded.  Rather than
	# emitting an empty success bullet ("(none uploaded)") or
	# walking the download path only to no-op, Env consults the
	# Director's cached listing (has_config_of_type from Step 1)
	# and silently drops the cpi spec when there's nothing to
	# fetch.  No UI noise, no bogus use_config registration.
	plan tests => 3;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('cpi-silent-skip');
	$env->{__configs} = {};
	$env->{__tmp} //= workdir();

	my @captured;
	my $stub_bosh = bless { alias => 'stub' }, 'Test::Mock::Bosh::CpiSkip';
	{
		no strict 'refs';
		no warnings 'redefine';
		*{'Test::Mock::Bosh::CpiSkip::has_config_of_type'} = sub {
			my ($self, $type) = @_;
			return 0;  # nothing uploaded
		};
		*{'Test::Mock::Bosh::CpiSkip::download_configs'} = sub {
			my ($self, @args) = @_;
			push @captured, [@args];
			return ();
		};
		*{'Test::Mock::Bosh::CpiSkip::alias'} = sub { $_[0]->{alias} };
	}

	no warnings qw(redefine once);
	local *Genesis::Env::with_bosh = sub { $_[0] };
	local *Genesis::Env::bosh      = sub { $stub_bosh };

	$env->download_configs('cpi');

	is scalar(@captured), 0,
		'bosh->download_configs is NOT called when has_config_of_type(cpi) is false';
	ok(!$env->has_config('cpi'),
		'has_config(cpi) remains false -- no use_config was registered');
	ok(!exists($env->{__configs}{'cpi'}),
		'overlay carries no entry for cpi (skip kept it clean)');
};

subtest 'download_configs - cpi spec proceeds (optional=>1) when configs are uploaded' => sub {
	# Companion to the silent-skip subtest above: when the director
	# DOES have cpi configs uploaded, the cpi spec flows through
	# normally with optional=>1 set defensively (covers the race
	# where the listing is fresh but the content fetch finds zero
	# entries between calls).
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('cpi-proceeds');
	$env->{__configs} = {};
	$env->{__tmp} //= workdir();

	my @captured;
	my $stub_bosh = bless { alias => 'stub' }, 'Test::Mock::Bosh::CpiProceed';
	{
		no strict 'refs';
		no warnings 'redefine';
		*{'Test::Mock::Bosh::CpiProceed::has_config_of_type'} = sub {
			my ($self, $type) = @_;
			return $type eq 'cpi' ? 1 : 0;
		};
		*{'Test::Mock::Bosh::CpiProceed::download_configs'} = sub {
			my ($self, @args) = @_;
			push @captured, [@args];
			return ({ type => 'cpi', name => 'aws-bundle', label => "cpi config 'aws-bundle'" });
		};
		*{'Test::Mock::Bosh::CpiProceed::alias'} = sub { $_[0]->{alias} };
	}

	no warnings qw(redefine once);
	local *Genesis::Env::with_bosh = sub { $_[0] };
	local *Genesis::Env::bosh      = sub { $stub_bosh };

	$env->download_configs('cpi');

	is scalar(@captured), 1,
		'bosh->download_configs IS called when cpi configs are uploaded';
	my %fwd = @{$captured[0]}[3..$#{$captured[0]}];
	is $fwd{optional}, 1,
		'optional=>1 is forced for cpi as defensive insurance';
};

subtest 'download_configs - threads trailing opts hashref to bosh->download_configs' => sub {
	plan tests => 3;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('opts-threading');
	$env->{__configs} = {};
	$env->{__tmp} //= workdir();

	# Stub bosh: capture the args to download_configs and return an
	# empty @configs list (simulating optional=>1 + nothing uploaded).
	# has_config_of_type returns true so the cpi pre-filter
	# (introduced for Step 6) doesn't drop the spec before we can
	# observe the call.
	my @captured;
	my $stub_bosh = bless {
		alias => 'stub',
		_dl   => sub {
			shift;  # $self
			push @captured, [@_];
			return ();   # empty list -- caller sees no @downloaded
		},
	}, 'Test::Mock::Bosh::Env';
	{
		no strict 'refs';
		no warnings 'redefine';
		*{'Test::Mock::Bosh::Env::download_configs'} = sub {
			my ($self, @args) = @_;
			$self->{_dl}->(undef, @args);
		};
		*{'Test::Mock::Bosh::Env::has_config_of_type'} = sub { 1 };
		*{'Test::Mock::Bosh::Env::alias'} = sub { $_[0]->{alias} };
	}

	no warnings qw(redefine once);
	local *Genesis::Env::with_bosh = sub { $_[0] };
	local *Genesis::Env::bosh      = sub { $stub_bosh };

	$env->download_configs('cpi', { optional => 1 });

	is scalar(@captured), 1,
		'one bosh->download_configs call per spec';
	# Args shape: ($path, $type, $name, %opts)
	my @args = @{$captured[0]};
	is $args[1], 'cpi', 'type is forwarded';
	# %opts at the end -- pull pairs from index 3 onwards.
	my %fwd = @args[3..$#args];
	is $fwd{optional}, 1,
		'optional => 1 is threaded through to the bosh->download_configs call';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
