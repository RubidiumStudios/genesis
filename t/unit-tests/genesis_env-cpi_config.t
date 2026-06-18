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
use Test::Output;

use Genesis;
use_ok 'Genesis::Config';
# Initialize $Genesis::RC for tests that consult global config
provide_rc();

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Helper: build an env whose `bosh-configs:` block is taken verbatim.
sub make_cpi_env {
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

# ======================================================================
# _resolve_director_cpi_config
# ======================================================================

subtest 'resolver - empty list when cpi disabled' => sub {
	plan tests => 1;

	my $env = make_cpi_env('cpi-off', <<'YAML');
  cpi:
    enabled: false
YAML

	my @result = $env->_resolve_director_cpi_config;
	is_deeply \@result, [], 'no source returned when cpi_enabled is false';
};

subtest 'resolver - inline single entry, default name' => sub {
	plan tests => 4;

	my $env = make_cpi_env('cpi-inline-default', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - name: vsphere-prod
      type: vsphere
      properties:
        host: vcenter.example.com
YAML

	my ($config, $secrets, $source, $name)
		= $env->_resolve_director_cpi_config;

	is $source, 'inline',  'source = inline';
	is $name,   'default', 'bosh config name defaults to "default"';
	is_deeply $config, {
		cpis => [{
			name => 'vsphere-prod',
			type => 'vsphere',
			properties => { host => 'vcenter.example.com' },
		}],
	}, 'config payload lifted verbatim under cpis key';
	is_deeply $secrets, {}, 'no secrets when inline (vault refs pre-resolved)';
};

subtest 'resolver - inline single entry, custom bosh config name' => sub {
	plan tests => 2;

	my $env = make_cpi_env('cpi-inline-named', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    name: vsphere-main
    cpis:
    - name: only-cpi
      type: vsphere
      properties: {}
YAML

	my ($config, $secrets, $source, $name)
		= $env->_resolve_director_cpi_config;

	is $source, 'inline',       'source = inline';
	is $name,   'vsphere-main', 'bosh config name comes from director-cpi.name';
};

subtest 'resolver - inline N entries with explicit default' => sub {
	plan tests => 2;

	my $env = make_cpi_env('cpi-multi-ok', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    default: east
    cpis:
    - name: east
      type: vsphere
      properties: {}
    - name: west
      type: vsphere
      properties: {}
YAML

	my ($config, $secrets, $source, $name)
		= $env->_resolve_director_cpi_config;

	is $source, 'inline', 'source = inline';
	is scalar @{$config->{cpis}}, 2, 'both cpis present in payload';
};

subtest 'resolver - inline N entries without default bails' => sub {
	plan tests => 1;

	my $env = make_cpi_env('cpi-multi-nodef', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - name: east
      type: vsphere
      properties: {}
    - name: west
      type: vsphere
      properties: {}
YAML

	throws_ok {
		$env->_resolve_director_cpi_config;
	} qr/Multiple entries.*director-cpi\.cpis.*specify.*director-cpi\.default/ims,
		'multi-cpi without explicit default bails';
};

subtest 'resolver - inline default not in cpis bails' => sub {
	plan tests => 1;

	my $env = make_cpi_env('cpi-baddef', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    default: nonsense
    cpis:
    - name: east
      type: vsphere
      properties: {}
    - name: west
      type: vsphere
      properties: {}
YAML

	throws_ok {
		$env->_resolve_director_cpi_config;
	} qr/director-cpi\.default.*nonsense.*does not match.*cpis/ims,
		'declared default not in cpis[] bails';
};

subtest 'resolver - inline scalar bails (schema)' => sub {
	plan tests => 1;

	my $env = make_cpi_env('cpi-bad-scalar', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis: not-an-array
YAML

	throws_ok {
		$env->_resolve_director_cpi_config;
	} qr/director-cpi\.cpis.*must be a non-empty array/ims,
		'scalar cpis bails with schema message';
};

subtest 'resolver - cpi-config hook fallback' => sub {
	plan tests => 4;

	my $env = make_cpi_env('cpi-hook', <<'YAML');
  cpi:
    enabled: true
YAML

	my $hook_config  = { cpis => [{ name => 'aws-east', type => 'aws' }] };
	my $hook_secrets = { '/cpi-config/properties/key' => 'value' };

	no warnings qw(redefine once);
	local *Genesis::Env::has_hook = sub { $_[1] eq 'cpi-config' };
	local *Genesis::Env::run_hook = sub {
		my ($self, $hook, %opts) = @_;
		return ($hook_config, $hook_secrets, undef) if $hook eq 'cpi-config';
		return ();
	};
	local *Genesis::Env::cpi_name = sub { 'aws-east' };

	my ($config, $secrets, $source, $name)
		= $env->_resolve_director_cpi_config;

	is $source, 'cpi-config hook',  'source = cpi-config hook';
	is $name,   'aws-east.director', 'name = <cpi_name>.director';
	is_deeply $config,  $hook_config,  'config from hook';
	is_deeply $secrets, $hook_secrets, 'secrets from hook';
};

subtest 'resolver - inline wins over cpi-config hook' => sub {
	plan tests => 2;

	my $env = make_cpi_env('cpi-both', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - name: inline-only
      type: vsphere
      properties: {}
YAML

	my $run_hook_called = 0;
	no warnings 'redefine';
	local *Genesis::Env::has_hook = sub { $_[1] eq 'cpi-config' };
	local *Genesis::Env::run_hook = sub { $run_hook_called++; () };

	my (undef, undef, $source) = $env->_resolve_director_cpi_config;

	is $source, 'inline', 'source = inline even when cpi-config hook exists';
	is $run_hook_called, 0, 'run_hook is not invoked when inline is present';
};

subtest 'resolver - reads the entombed manifest (credhub vars already substituted)' => sub {
	plan tests => 4;

	my $env = make_cpi_env('cpi-entombed', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - name: vsphere-prod
      type: vsphere
      properties:
        host:     vcenter.example.com
        user:     admin
        password: (( vault "secret/vcenter/prod:password" ))
YAML

	# Simulate the EntombedSelf manifest having already done its job:
	# vault refs are replaced by credhub-var references targeting the
	# deployed director's OWN credhub.
	no warnings qw(redefine once);
	local *Genesis::Env::lookup_entombed_self = sub {
		my ($self, $key, $default) = @_;
		return [{
			name => 'vsphere-prod',
			type => 'vsphere',
			properties => {
				host     => 'vcenter.example.com',
				user     => 'admin',
				password => '((/cpi-config/properties/genesis-entombed/secret-vcenter-prod--password--abc12345))',
			},
		}] if $key eq 'bosh-configs.director-cpi.cpis';
		return $default;
	};

	my ($config, $secrets, $source) = $env->_resolve_director_cpi_config;

	is $source, 'inline', 'source is inline';
	is $config->{cpis}[0]{properties}{host}, 'vcenter.example.com',
		'non-vault values pass through unchanged';
	is $config->{cpis}[0]{properties}{password},
		'((/cpi-config/properties/genesis-entombed/secret-vcenter-prod--password--abc12345))',
		'password is the credhub-var ref from the entombed manifest, not plaintext';
	is_deeply $secrets, {},
		'secrets dict is empty — entombment was done at deploy time';
};

subtest 'lookup_entombed_self - reads from EntombedSelf manifest data' => sub {
	plan tests => 2;

	my $env = make_cpi_env('le-direct', <<'YAML');
  cpi:
    enabled: true
YAML

	# Verifies that lookup_entombed_self pulls from
	# manifest_provider->entombed_self (the new Manifest::EntombedSelf
	# variant introduced in this ticket).  We stub manifest_provider to
	# expose a fake entombed_self manifest with known data, then assert
	# struct_lookup reaches in to the right subtree and respects the
	# default for missing keys.
	my $fake_manifest = bless {
		data => {
			'bosh-configs' => {
				'director-cpi' => {
					cpis => [{ name => 'ent', type => 'vsphere', properties => {} }],
				},
			},
		},
	}, 'Test::Mock::Manifest';
	{ no strict 'refs'; *{"Test::Mock::Manifest::data"} = sub { $_[0]->{data} }; }

	my $fake_provider = bless {}, 'Test::Mock::Provider';
	no warnings qw(redefine once);
	local *Genesis::Env::manifest_provider = sub { $fake_provider };
	{ no strict 'refs'; *{"Test::Mock::Provider::entombed_self"} = sub { $fake_manifest }; }

	is_deeply scalar $env->lookup_entombed_self('bosh-configs.director-cpi.cpis'),
		[{ name => 'ent', type => 'vsphere', properties => {} }],
		'lookup_entombed_self reads from the entombed_self manifest data';
	is scalar $env->lookup_entombed_self('absent.key', 'fallback'), 'fallback',
		'lookup_entombed_self returns default for missing keys';
};

subtest 'resolver - no source returns empty' => sub {
	plan tests => 1;

	my $env = make_cpi_env('cpi-empty', <<'YAML');
  cpi:
    enabled: true
YAML

	no warnings 'redefine';
	local *Genesis::Env::has_hook = sub { 0 };

	my @result = $env->_resolve_director_cpi_config;
	is_deeply \@result, [], 'no inline + no hook returns empty list';
};

# ======================================================================
# default_cpi_name
# ======================================================================

subtest 'default_cpi_name - undef when cpi disabled' => sub {
	plan tests => 1;

	my $env = make_cpi_env('dcn-off', <<'YAML');
  cpi:
    enabled: false
YAML

	is $env->default_cpi_name, undef,
		'default_cpi_name returns undef when cpi_enabled is false';
};

subtest 'default_cpi_name - inline sole entry (implicit default)' => sub {
	plan tests => 1;

	my $env = make_cpi_env('dcn-sole', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - name: only-cpi
      type: vsphere
      properties: {}
YAML

	is $env->default_cpi_name, 'only-cpi',
		'sole inline entry name is the implicit default';
};

subtest 'default_cpi_name - inline N entries with declared default' => sub {
	plan tests => 1;

	my $env = make_cpi_env('dcn-declared', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    default: west
    cpis:
    - name: east
      type: vsphere
      properties: {}
    - name: west
      type: vsphere
      properties: {}
YAML

	is $env->default_cpi_name, 'west',
		'director-cpi.default wins over cpis[0] ordering';
};

subtest 'default_cpi_name - director-cpi.default honored without cpis (advertise-only)' => sub {
	plan tests => 1;

	my $env = make_cpi_env('dcn-advertise-only', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    default: externally-uploaded-cpi
YAML

	no warnings qw(redefine once);
	local *Genesis::Env::cpi_name = sub {
		die "cpi_name should not be reached when director-cpi.default is set";
	};

	is $env->default_cpi_name, 'externally-uploaded-cpi',
		'director-cpi.default is honored even without cpis: (advertise-only)';
};

subtest 'default_cpi_name - falls through to cpi_name when no inline' => sub {
	plan tests => 1;

	my $env = make_cpi_env('dcn-noinline', <<'YAML');
  cpi:
    enabled: true
YAML

	no warnings qw(redefine once);
	local *Genesis::Env::cpi_name = sub { 'fallthrough-cpi' };

	is $env->default_cpi_name, 'fallthrough-cpi',
		'default_cpi_name delegates to cpi_name when inline is absent';
};

# ======================================================================
# _cpi_exodus_overrides
# ======================================================================

subtest 'exodus overrides - empty for non-bosh-director env' => sub {
	plan tests => 1;

	my $env = make_cpi_env('exo-nondir', <<'YAML');
  cpi:
    enabled: true
YAML

	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 0 };

	is_deeply $env->_cpi_exodus_overrides, {},
		'non-bosh-director env contributes no cpi exodus overrides';
};

subtest 'exodus overrides - empty when cpi disabled' => sub {
	plan tests => 1;

	my $env = make_cpi_env('exo-cpioff', <<'YAML');
  cpi:
    enabled: false
YAML

	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 1 };

	is_deeply $env->_cpi_exodus_overrides, {},
		'cpi disabled contributes no cpi exodus overrides';
};

subtest 'exodus overrides - no inline, default_cpi_config only' => sub {
	plan tests => 1;

	my $env = make_cpi_env('exo-nohook', <<'YAML');
  cpi:
    enabled: true
YAML

	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 1 };
	local *Genesis::Env::cpi_name        = sub { 'convention-name' };

	is_deeply $env->_cpi_exodus_overrides,
		{ default_cpi_config => 'convention-name' },
		'no inline → only default_cpi_config (from cpi_name) is set';
};

subtest 'exodus overrides - inline sole entry populates all three fields' => sub {
	plan tests => 1;

	my $env = make_cpi_env('exo-sole', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - name: only-cpi
      type: vsphere
      properties: {}
YAML

	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 1 };

	is_deeply $env->_cpi_exodus_overrides, {
		default_cpi_config => 'only-cpi',
		available_cpis     => ['only-cpi'],
		cpi_config_name    => 'default',
	}, 'sole inline entry → default_cpi_config, available_cpis, cpi_config_name';
};

subtest 'exodus overrides - advertise-only (default without cpis)' => sub {
	plan tests => 1;

	my $env = make_cpi_env('exo-advertise', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    default: externally-uploaded-cpi
YAML

	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 1 };

	is_deeply $env->_cpi_exodus_overrides,
		{ default_cpi_config => 'externally-uploaded-cpi' },
		'advertise-only: only default_cpi_config published, no inventory keys';
};

subtest 'exodus overrides - inline N entries with declared default and custom name' => sub {
	plan tests => 1;

	my $env = make_cpi_env('exo-multi', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    name:    cpi-fleet
    default: west
    cpis:
    - name: east
      type: vsphere
      properties: {}
    - name: west
      type: vsphere
      properties: {}
    - name: aws-staging
      type: aws
      properties: {}
YAML

	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 1 };

	is_deeply $env->_cpi_exodus_overrides, {
		default_cpi_config => 'west',
		available_cpis     => ['east', 'west', 'aws-staging'],
		cpi_config_name    => 'cpi-fleet',
	}, 'multi-cpi inline populates all three fields with operator values';
};

# ======================================================================
# upload_director_cpi_config — I/O wrapper around the resolver
# ======================================================================
#
# These tests use a hand-rolled mock for the bosh director (via the existing
# t/Mock.pm) so the uploader is exercised end-to-end without touching the
# Vault layer or spawning a subprocess. Each test installs a fresh mock,
# stubs Genesis::Env::get_target_bosh to return it, and asserts on the
# captured upload_config call (or its absence).

# Captured-call mock bosh director built via t/Mock.pm. upload_config is
# called in list context (my ($out,$rc,$err) = ...), which Mock.pm now
# propagates correctly to CODE-valued methods.
sub mock_bosh {
	my %opts = @_;
	my $rc    = $opts{rc}  // 0;
	my $err   = $opts{err} // '';
	my $calls = [];
	mock 'Test::Mock::Director' => {
		_calls => $calls,
		upload_config => sub {
			my ($self, $config, $type, $name, $confirm) = @_;
			push @$calls, {
				config => $config, type => $type,
				name => $name, confirm => $confirm,
			};
			return ('ok', $rc, $err);
		},
	};
}

subtest 'uploader - inline single uploads under default name' => sub {
	plan tests => 4;

	my $env = make_cpi_env('up-default', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - name: vsphere-prod
      type: vsphere
      properties:
        host: vcenter.example.com
YAML

	my $bosh = mock_bosh();
	no warnings qw(redefine once);
	local *Genesis::Env::get_target_bosh = sub { $bosh };

	my $ok;
	quietly { $ok = $env->upload_director_cpi_config };
	ok $ok, 'upload returns 1 on success';
	is scalar @{$bosh->{_calls}}, 1, 'upload_config called exactly once';

	my $call = $bosh->{_calls}[0];
	is $call->{name}, 'default', 'bosh config name defaults to "default"';
	is_deeply $call->{config}, {
		cpis => [{
			name => 'vsphere-prod',
			type => 'vsphere',
			properties => { host => 'vcenter.example.com' },
		}],
	}, 'payload lifted from inline cpis[]';
};

subtest 'uploader - inline custom director-cpi.name routed to bosh' => sub {
	plan tests => 2;

	my $env = make_cpi_env('up-named', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    name: cpi-fleet
    cpis:
    - name: only-cpi
      type: vsphere
      properties: {}
YAML

	my $bosh = mock_bosh();
	no warnings qw(redefine once);
	local *Genesis::Env::get_target_bosh = sub { $bosh };

	my $ok;
	quietly { $ok = $env->upload_director_cpi_config };
	ok $ok, 'upload returns 1';
	is $bosh->{_calls}[0]{name}, 'cpi-fleet',
		'director-cpi.name passes through as bosh config name';
};

subtest 'uploader - bosh non-zero rc returns 0' => sub {
	plan tests => 2;

	my $env = make_cpi_env('up-fail', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - name: vsphere-prod
      type: vsphere
      properties: {}
YAML

	my $bosh = mock_bosh(rc => 1, err => 'simulated bosh failure');
	no warnings qw(redefine once);
	local *Genesis::Env::get_target_bosh = sub { $bosh };

	my $result;
	quietly { $result = $env->upload_director_cpi_config };
	is $result, 0, 'upload returns 0 when bosh rc is non-zero';
	is scalar @{$bosh->{_calls}}, 1, 'upload was still attempted';
};

subtest 'uploader - no-op when cpi disabled' => sub {
	plan tests => 1;

	my $env = make_cpi_env('up-disabled', <<'YAML');
  cpi:
    enabled: false
YAML

	no warnings qw(redefine once);
	local *Genesis::Env::get_target_bosh = sub {
		die "get_target_bosh must not be called when cpi is disabled";
	};

	is $env->upload_director_cpi_config, 1,
		'upload returns 1 (success no-op) when cpi disabled';
};

subtest 'uploader - no-op when no source and cpi enabled' => sub {
	plan tests => 1;

	my $env = make_cpi_env('up-nosource', <<'YAML');
  cpi:
    enabled: true
YAML

	no warnings qw(redefine once);
	local *Genesis::Env::has_hook       = sub { 0 };
	local *Genesis::Env::get_target_bosh = sub {
		die "get_target_bosh must not be called when there's no source";
	};

	is $env->upload_director_cpi_config, 1,
		'upload returns 1 (no-op) when cpi enabled but no source';
};

# ======================================================================
# _upload_director_cpi_if_necessary — genesis-driven fallback
# fired from Env::deploy's success path. Targets older bosh kits (< 4.0.0)
# whose post-deploy hook predates inline director-cpi awareness — for those,
# genesis core must perform the self-upload itself. Newer bosh kits (>= 4.0.0
# and dev) delegate via PostDeploy::upload_director_cpi_config, so this helper
# is a no-op for them to avoid double-uploading.
# ======================================================================

# Build a fixture env claiming to be a bosh director kit at $version (use
# 'dev' to mark the kit as a dev kit).
sub fallback_env {
	my ($name, $bosh_configs, $kit_version) = @_;
	my $env = make_cpi_env($name, $bosh_configs);
	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 1 };
	# is_bosh_director is consulted via $self->is_bosh_director — patch in
	# place by re-blessing isn't needed because we re-stub per subtest.
	$env;
}

subtest 'fallback - no-op when env is not a bosh director' => sub {
	plan tests => 2;

	my $env = make_cpi_env('fb-nondir', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - { name: a, type: vsphere, properties: {} }
YAML

	my $upload_called = 0;
	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 0 };
	local *Genesis::Env::upload_director_cpi_config = sub { $upload_called++; 1 };

	my $ret = $env->_upload_director_cpi_if_necessary;
	is $ret, 0, 'returns 0 when env is not a bosh director kit';
	is $upload_called, 0, 'upload is not invoked';
};

subtest 'fallback - no-op when no inline director-cpi' => sub {
	plan tests => 2;

	my $env = make_cpi_env('fb-noinline', <<'YAML');
  cpi:
    enabled: true
YAML

	my $upload_called = 0;
	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 1 };
	local *Genesis::Env::upload_director_cpi_config = sub { $upload_called++; 1 };

	my $ret = $env->_upload_director_cpi_if_necessary;
	is $ret, 0, 'returns 0 when no inline director-cpi declared';
	is $upload_called, 0, 'upload is not invoked';
};

subtest 'fallback - no-op when bosh kit version >= 4.0.0' => sub {
	plan tests => 2;

	my $env = make_cpi_env('fb-new-kit', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - { name: a, type: vsphere, properties: {} }
YAML

	my $kit = mock 'Test::Mock::Kit::New' => {
		version => '4.0.0',
		is_dev  => 0,
	};
	$env->{kit} = $kit;

	my $upload_called = 0;
	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 1 };
	local *Genesis::Env::upload_director_cpi_config = sub { $upload_called++; 1 };

	my $ret = $env->_upload_director_cpi_if_necessary;
	is $ret, 0, 'returns 0 when kit >= 4.0.0 (post-deploy hook handles it)';
	is $upload_called, 0, 'upload is not invoked';
};

subtest 'fallback - no-op when kit is dev (assume latest)' => sub {
	plan tests => 2;

	my $env = make_cpi_env('fb-dev-kit', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - { name: a, type: vsphere, properties: {} }
YAML

	my $kit = mock 'Test::Mock::Kit::Dev' => {
		version => 'latest',
		is_dev  => 1,
	};
	$env->{kit} = $kit;

	my $upload_called = 0;
	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 1 };
	local *Genesis::Env::upload_director_cpi_config = sub { $upload_called++; 1 };

	my $ret = $env->_upload_director_cpi_if_necessary;
	is $ret, 0, 'returns 0 when kit is dev (assumed latest)';
	is $upload_called, 0, 'upload is not invoked';
};

subtest 'fallback - fires for bosh kit < 4.0.0 with inline director-cpi' => sub {
	plan tests => 2;

	my $env = make_cpi_env('fb-old-kit', <<'YAML');
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - { name: a, type: vsphere, properties: {} }
YAML

	my $kit = mock 'Test::Mock::Kit::Old' => {
		version => '3.0.2',
		is_dev  => 0,
	};
	$env->{kit} = $kit;

	my $upload_called = 0;
	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 1 };
	local *Genesis::Env::upload_director_cpi_config = sub {
		$upload_called++;
		return 'upload-return';
	};

	my $ret;
	quietly { $ret = $env->_upload_director_cpi_if_necessary };
	is $ret, 'upload-return',
		'returns whatever upload_director_cpi_config returned';
	is $upload_called, 1, 'upload was invoked exactly once';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
