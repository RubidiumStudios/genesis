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
use Cwd qw(getcwd abs_path);

use Genesis;
use_ok 'Genesis::Config';
# Initialize $Genesis::RC for tests that consult global config
provide_rc();

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';
use_ok 'Genesis::Commands';
use_ok 'Genesis::Commands::Env';
use_ok 'Genesis::Commands::Bosh';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# quiet_env_call - invoke an Env method that triggers manifest
# synthesis, swallowing the "[env/cf] determining manifest fragments
# for merging..." banner that would otherwise leak into the prove
# progress line.  Use list-context invocation always (callers pick
# the context they want via scalar() / list assignment).
sub quiet_env_call {
	my ($env, $method, @args) = @_;
	my @result;
	stderr_from {
		@result = $env->$method(@args);
	};
	return wantarray ? @result : $result[0];
}

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

	my @result = quiet_env_call($env, "_resolve_director_cpi_config");
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
		= quiet_env_call($env, "_resolve_director_cpi_config");

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
		= quiet_env_call($env, "_resolve_director_cpi_config");

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
		= quiet_env_call($env, "_resolve_director_cpi_config");

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
		quiet_env_call($env, "_resolve_director_cpi_config");
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
		quiet_env_call($env, "_resolve_director_cpi_config");
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
		quiet_env_call($env, "_resolve_director_cpi_config");
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
		= quiet_env_call($env, "_resolve_director_cpi_config");

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

	my (undef, undef, $source) = quiet_env_call($env, "_resolve_director_cpi_config");

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

	my ($config, $secrets, $source) = quiet_env_call($env, "_resolve_director_cpi_config");

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
	local *Genesis::Env::is_bosh_director = sub { 1 };

	is_deeply scalar $env->lookup_entombed_self('bosh-configs.director-cpi.cpis'),
		[{ name => 'ent', type => 'vsphere', properties => {} }],
		'lookup_entombed_self reads from the entombed_self manifest data';
	is scalar $env->lookup_entombed_self('absent.key', 'fallback'), 'fallback',
		'lookup_entombed_self returns default for missing keys';
};

# ======================================================================
# lookup_entombed_self - strict for a director
# ======================================================================

my $UNEVALED = '(( vault "secret/child/pve:password" ))';
my $ENTOMBED = '((genesis-entombed/_/child/pve--password--0a1b2c3d))';
my $CREDHUB_DOWN = "Could not reach the CredHub of child-bosh-cf at https://10.0.0.5:8844\n";

sub director_env {
	return make_cpi_env('child-bosh', <<'YAML');
  cpi:
    enabled: true
    password: (( vault "secret/child/pve:password" ))
YAML
}

# The entombed manifest a test builds: its data, or the error building it dies with.
sub Test::Fake::EntombedSelf::data { ref($_[0]{data}) ? $_[0]{data} : die $_[0]{data} }

# self_lookup - runs lookup_entombed_self for a director (or not) whose
# entombment is given, and reports what came back, what was printed, how
# many times BOSH was asked anything, how many times the entombed manifest
# was built, how many times the kit's blueprint ran to merge a manifest,
# and which configs were downloaded from the parent.
#
#   director - is_bosh_director (default 1)
#   entombed - entombed data, or the message its build dies with
sub self_lookup {
	my (%s) = @_;
	my $env = $s{env} // director_env();
	my $key = $s{key} // 'bosh-configs.cpi.password';
	my (@downloads, $builds, $blueprints, $bosh);

	my $parent = Service::BOSH::Director->new('parent-bosh',
		url => 'https://10.0.0.4:25555', ca_cert => 'ca', client => 'admin',
		secret => 'password', exodus_path => 'secret/exodus');

	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { $s{director} // 1 };
	local *Genesis::Env::use_create_env = sub { 0 };
	local *Genesis::Env::bosh = sub { $parent };
	local *Genesis::Env::with_bosh = sub { $_[0] };
	local $ENV{GENESIS_CLOUD_CONFIG}; # a download registers the config here too
	local *Service::BOSH::Director::has_config_of_type = sub { 0 };
	local *Service::BOSH::Director::download_configs = sub {
		my (undef, $path, $type) = @_;
		push @downloads, $type;
		mkfile_or_fail($path, "--- {}\n");
		return {type => $type, name => 'default', label => "default $type config"};
	};
	local *Service::BOSH::Director::execute = sub { $bosh++; die "BOSH asked\n" };
	local *Genesis::Env::ManifestProvider::entombed_self = sub {
		$builds++;
		return bless {data => $s{entombed} // $CREDHUB_DOWN}, 'Test::Fake::EntombedSelf';
	};
	my $kit_files = \&Genesis::Env::ManifestProvider::kit_files;
	local *Genesis::Env::ManifestProvider::kit_files = sub { $blueprints++; goto &$kit_files };

	my (@result, $error);
	my $stderr = stderr_from {
		@result = eval { $env->lookup_entombed_self($key, $s{default}) };
		$error = untraced($@);
	};
	return {
		value => $result[0], found => $result[1], error => $error,
		stderr => $stderr, bosh => $bosh // 0, builds => $builds // 0,
		blueprints => $blueprints // 0, downloads => \@downloads,
	};
}

# Carp::Always appends a stack trace to every error; keep only the message.
sub untraced {
	my ($error) = @_;
	$error =~ s/(?<=\n) at \S+ line \d+\.\n.*\z//s;
	return $error;
}

subtest 'lookup_entombed_self reads the unevaluated manifest for an env that is not a director' => sub {
	my $r = self_lookup(director => 0);
	is $r->{error}, '', 'nothing is raised';
	is $r->{value}, $UNEVALED, 'the unevaluated value comes back';
	is $r->{found}, 'bosh-configs.cpi.password', 'and is reported found';
	is $r->{builds}, 0, 'the entombed manifest is never built';
	is $r->{bosh}, 0, 'and BOSH is never asked';
	unlike $r->{stderr}, qr/WARNING/, 'and nothing is warned about';
};

# A director answers every key from the entombed build, which here answers
# with values of its own, so each test can tell where a value came from.

subtest 'a deployed director answers an absent key from the entombed build' => sub {
	my $r = self_lookup(key => 'bosh-configs.director-cpi.cpis', default => 'none',
		entombed => {'bosh-configs' => {cpi => {password => $ENTOMBED}}});
	is $r->{error}, '', 'nothing is raised';
	is $r->{value}, 'none', 'the default comes back';
	is $r->{found}, undef, 'and is reported not found';
	is $r->{builds}, 1, 'once the entombed build shows the key is absent';
	is_deeply $r->{downloads}, ['cloud'], 'whose blueprint has the cloud config downloaded first';
	is $r->{bosh}, 0, 'and the parent is never asked anything else';

	$r = self_lookup(key => 'bosh-configs.director-cpi.cpis', default => 'none');
	is $r->{error}, $CREDHUB_DOWN, 'a build that fails is raised';
	is $r->{value}, undef, 'and no default comes back';
};

subtest 'a deployed director answers a literal key from the entombed build' => sub {
	my $r = self_lookup(
		env => make_cpi_env('child-bosh', "  cpi:\n    enabled: true\n    password: plain-text\n"),
		entombed => {'bosh-configs' => {cpi => {password => 'built'}}});
	is $r->{error}, '', 'nothing is raised';
	is $r->{value}, 'built', 'the value comes from the entombed build';
	is $r->{found}, 'bosh-configs.cpi.password', 'and is reported found';
	is $r->{builds}, 1, 'which is built once';
	is_deeply $r->{downloads}, ['cloud'], 'once the cloud config its blueprint reads is downloaded';
	is $r->{bosh}, 0, 'and the parent is never asked anything else';
	unlike $r->{stderr}, qr/WARNING/, 'and nothing is warned about';
};

subtest 'lookup_entombed_self never falls back' => sub {
	my $r = self_lookup();
	is $r->{error}, $CREDHUB_DOWN, 'the entombment error is raised';
	is $r->{value}, undef, 'and neither the unevaluated value nor anything else comes back';
	is $r->{builds}, 1, 'after the entombed manifest was built';
	is $r->{bosh}, 0, 'and BOSH is never asked about the director';
	unlike $r->{stderr}, qr/WARNING/, 'and nothing is warned about';
};

subtest 'lookup_entombed_self reports an entombment failure instead of falling back' => sub {
	my $failure = "Failed to entomb one or more secrets into Credhub.\n";
	my $r = self_lookup(entombed => $failure);
	is $r->{error}, $failure, 'the entombment failure is raised';
	is $r->{value}, undef, 'and nothing comes back';
};

subtest 'lookup_entombed_self reports a vault outage instead of falling back' => sub {
	my $outage = "Could not read secret/child/pve from vault at https://vault.test: connection refused\n";
	my $r = self_lookup(entombed => $outage);
	is $r->{error}, $outage, 'the vault outage is raised';
	is $r->{value}, undef, 'and nothing comes back';
};

sub self_upload_env {
	my ($password, $rest) = @_;
	return make_cpi_env('child-bosh', <<"YAML".($rest // ''));
  cpi:
    enabled: true
  director-cpi:
    cpis:
    - name: pve
      type: proxmox
      properties:
        host: 10.0.0.1
        password: $password
YAML
}

# self_upload - runs the director CPI self-upload for the env, whose
# entombed build dies on the director's missing CredHub, and reports what
# came back, what was raised, how many times the entombed manifest was
# built, and how many times BOSH was asked anything.
sub self_upload {
	my ($env) = @_;
	my ($builds, $bosh) = (0, 0);
	no warnings qw(redefine once);
	local *Genesis::Env::is_bosh_director = sub { 1 };
	local *Service::BOSH::Director::execute = sub { $bosh++; die "BOSH asked\n" };
	local *Genesis::Env::ManifestProvider::entombed_self = sub {
		$builds++;
		bless {data => $CREDHUB_DOWN}, 'Test::Fake::EntombedSelf';
	};
	my (@result, $error);
	stderr_from { @result = eval { $env->_resolve_director_cpi_config }; $error = untraced($@) };
	return {result => \@result, error => $error, builds => $builds, bosh => $bosh};
}

my $INJECTED = <<'YAML';
  cpi:
    enabled: true
  director-cpi:
    <<<: (( inject meta.cpi_defaults ))
    cpis:
    - name: pve
      type: proxmox
      properties:
        host: 10.0.0.1
meta:
  cpi_defaults:
    cpis:
    - name: pve
      properties:
        password: (( vault "secret/child/pve:password" ))
YAML
my $GRABBED = <<'YAML';
  cpi:
    enabled: true
  director-cpi: (( grab meta.director_cpi ))
meta:
  director_cpi:
    cpis:
    - name: pve
      type: proxmox
      properties:
        host: 10.0.0.1
YAML

# The self-upload always reads the entombed build, however the list is
# written.  Each of these lists either reads the vault or looks literal
# only until it is evaluated.  A vault reference anywhere in the manifest,
# even one the list never uses, needs the director's own CredHub, and
# without it the upload stops.
for my $case (
	['an inline literal list beside an unrelated vault reference',
		sub { self_upload_env('plain-text', qq{params:\n  admin_password: (( vault "secret/child/bosh:admin_password" ))\n}) }],
	['a vault reference in the list', sub { self_upload_env($UNEVALED) }],
	['base64 of a vault value',
		sub { self_upload_env('(( base64 meta.cpi_password ))', qq{meta:\n  cpi_password: $UNEVALED\n}) }],
	['an expression that reads the environment', sub { self_upload_env('(( grab $REDACT || "live" ))') }],
	['an inline list beside an inject', sub { make_cpi_env('child-bosh', $INJECTED) }],
	['a list whose map an operator stands in for', sub { make_cpi_env('child-bosh', $GRABBED) }],
) {
	my ($label, $make) = @$case;
	subtest "the director CPI self-upload entombs $label" => sub {
		my $r = self_upload($make->());
		is $r->{error}, $CREDHUB_DOWN, 'the entombment error is raised';
		is_deeply $r->{result}, [], 'and no config comes back';
		is $r->{builds}, 1, 'after the entombed manifest was built';
		is $r->{bosh}, 0, 'and BOSH is never asked';
	};
}

subtest 'resolver - no source returns empty' => sub {
	plan tests => 1;

	my $env = make_cpi_env('cpi-empty', <<'YAML');
  cpi:
    enabled: true
YAML

	no warnings 'redefine';
	local *Genesis::Env::has_hook = sub { 0 };

	my @result = quiet_env_call($env, "_resolve_director_cpi_config");
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

	is quiet_env_call($env, "default_cpi_name"), undef,
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

	is quiet_env_call($env, "default_cpi_name"), 'only-cpi',
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

	is quiet_env_call($env, "default_cpi_name"), 'west',
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

	is quiet_env_call($env, "default_cpi_name"), 'externally-uploaded-cpi',
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

	is quiet_env_call($env, "default_cpi_name"), 'fallthrough-cpi',
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

	is scalar(quiet_env_call($env, 'upload_director_cpi_config')), 1,
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

	is scalar(quiet_env_call($env, 'upload_director_cpi_config')), 1,
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

# ======================================================================
# _check_cpi_config - comparing with the director's copy
# ======================================================================

# cpi_check_env - just enough of an env for _check_cpi_config to reach the
# comparison: a director holding a CPI config and a cpi-config hook that
# synthesizes one with no secrets.
sub cpi_check_env {
	my $director = mock 'Test::Mock::CpiCheck::Director' => {
		alias      => 'parent',
		get_config => sub { "cpis:\n- name: current\n" },
	};
	return mock 'Test::Mock::CpiCheck::Env' => {
		use_create_env   => 0,
		cpi_name         => 'test-env.aws.cf',
		bosh             => $director,
		has_hook         => 1,
		cpi_credhub_base => '/test/credhub/',
		is_ocfp          => 1,
		run_hook         => sub { return {content => "cpis:\n- name: new\n", credhub_secrets => {}} },
	};
}

subtest '_check_cpi_config - a spruce failure is fatal, never a change' => sub {
	plan tests => 4;
	no warnings qw(redefine once);
	local *Genesis::Env::spruce_diff = sub {
		return ("unable to parse data from new: yaml: line 1: did not find expected node content", 2, undef);
	};

	my $result;
	stderr_from { $result = Genesis::Env::_check_cpi_config(cpi_check_env()) };
	is $result->{state}, 'error', 'the state is error';
	ok $result->{fatal}, 'the error is fatal';
	like $result->{msg}, qr/could not be compared.*unable to parse data from new/s,
		'the message carries what spruce said';
	ok !exists $result->{fix_data}, 'no fix is offered for a config that could not be compared';
};

subtest '_check_cpi_config - a difference is still a change' => sub {
	plan tests => 2;
	no warnings qw(redefine once);
	local *Genesis::Env::spruce_diff = sub { return ("cpis\n  - name: current\n  + name: new", 1, undef) };

	my $result;
	stderr_from { $result = Genesis::Env::_check_cpi_config(cpi_check_env()) };
	is $result->{state}, 'changed', 'the state is changed';
	ok !$result->{fatal}, 'a change is not fatal';
};

# ======================================================================
# The cpi-config hook's values for a director
# ======================================================================

# These run the real chain from a command to the hook's two lookups, the
# declared property through _resolve and the extra one through
# gather_properties, with a fixture kit whose blueprint, like a director
# kit's, reads the cloud config.  The deploy test stops the command after
# the config downloads that follow its CPI step.

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');

my $SENTINEL = "stopped after the config downloads\n";

# The hook reads the vault target and the parent's CredHub details, and the
# entombed build names the vault and finds nothing in it to entomb, so a
# fake that names a target and holds nothing else is all they need.
{
	package Test::Fake::Vault;
	sub ref {'test-vault'}
	sub name {'test-vault'}
	sub connect_and_validate {$_[0]}
	sub verify {1}
	sub get {{}}
	sub get_path {{}}
	sub read_flattened_secret {undef}
	sub env {{}}
}
my $HOOK_VAULT = bless {}, 'Test::Fake::Vault';

# download_config - stands in for the parent's config download, handing out
# an empty config of the type asked for and recording the type in
# @DOWNLOADS.  Each test that uses it also says the parent holds no CPI
# configs, so the opportunistic CPI config download is skipped.
our @DOWNLOADS;
sub download_config {
	my (undef, $path, $type) = @_;
	push @DOWNLOADS, $type;
	mkfile_or_fail($path, "--- {}\n");
	return {type => $type, name => 'default', label => "default $type config"};
}

# A dev kit whose cpi-config hook resolves one declared property through
# _resolve and passes one extra bosh-configs.cpi leaf through
# gather_properties.  Its blueprint reads the cloud config, and it counts
# its runs in $Genesis::Hook::Blueprint::CpiContext::RUNS.
sub fixture_env {
	my $top = make_top(name => 'bosh', no_vault => 1);
	my $kit = workdir().'/cpi-context-kit-'.int(rand(1_000_000));
	put_file("$kit/kit.yml", <<'YAML');
---
name: cpi-context
version: 0.0.1
genesis_version_min: 3.1.0
YAML
	put_file("$kit/manifest.yml", "---\nname: child-bosh\n");
	put_file("$kit/hooks/blueprint.pm", <<'PERL');
package Genesis::Hook::Blueprint::CpiContext;
use strict;
use warnings;
use parent qw(Genesis::Hook::Blueprint);
use Genesis;

our $RUNS = 0;

sub perform {
	my ($self) = @_;
	$RUNS++;
	bail("The blueprint needs the cloud config, which isn't downloaded yet.")
		unless $self->env->config_file('cloud');
	$self->add_files('manifest.yml');
	return $self->done();
}

1;
PERL
	put_file("$kit/hooks/cpi-config.pm", <<'PERL');
package Genesis::Hook::CpiConfig::CpiContext;
use strict;
use warnings;
use parent qw(Genesis::Hook::CpiConfig);

sub perform {
	my ($self) = @_;
	my $properties = $self->gather_properties('host');
	return $self->done({cpis => [{name => 'child', type => 'test', properties => $properties}]});
}

1;
PERL
	$top->link_dev_kit($kit);
	put_file($top->path('child.yml'), <<'YAML');
---
kit:
  name:    dev
  version: latest
  features: []
  iaas:    test
genesis:
  env:             child
  bosh_env:        parent
  minimum_version: 3.1.0
bosh-configs:
  cpi:
    enabled:      true
    credhub_base: /cpi-config/properties/
    host:         10.0.0.1
    custom:       kept
YAML
	return $top;
}

sub parent_director {
	return Service::BOSH::Director->new('parent',
		url => 'https://10.0.0.4:25555', ca_cert => 'ca', client => 'admin',
		secret => 'password', exodus_path => 'secret/exodus');
}

# deploy_past_downloads - runs genesis deploy for the fixture director up to
# the end of the config downloads that follow its CPI step.  The parent
# director answers get_config with the given config, records uploads and
# config downloads, and is never asked anything else.  The entombed
# manifest is built for real, and counts its builds.
sub deploy_past_downloads {
	my (%s) = @_;
	my $top = fixture_env();
	my (@uploads, @bosh_calls);
	my $builds = 0;
	my $entombed_self = \&Genesis::Env::ManifestProvider::entombed_self;
	local $Genesis::Hook::Blueprint::CpiContext::RUNS = 0;
	local @DOWNLOADS;
	local $ENV{GENESIS_CLOUD_CONFIG}; # a download registers the config here too
	my $parent = parent_director();
	my $credhub = bless {}, 'Test::Fake::Credhub';

	no warnings qw(redefine once);
	local *Test::Fake::Credhub::paths = sub { () };
	local *Test::Fake::Credhub::base = sub { '/parent/child-bosh/' };
	local *Genesis::Env::with_vault = sub { $_[0] };
	local *Genesis::Env::vault = sub { $HOOK_VAULT };
	local *Genesis::Env::with_bosh = sub { $_[0] };
	local *Genesis::Env::is_ocfp = sub { 1 };
	local *Genesis::Env::deployment_change_reason_required_size_policy = sub { 0 };
	local *Genesis::Env::bosh = sub { $parent };
	local *Genesis::Env::credhub = sub { $credhub };
	local *Genesis::Env::can_build_cloud_configs = sub { 0 };
	local *Genesis::Env::_check_environment_viability = sub { die $SENTINEL };
	local *Service::BOSH::Director::has_config_of_type = sub { 0 };
	local *Service::BOSH::Director::download_configs = \&download_config;
	local *Service::BOSH::Director::get_config = sub { $s{parent_config} };
	local *Service::BOSH::Director::upload_config = sub { push @uploads, $_[2]; ('', 0, '') };
	local *Service::BOSH::Director::execute = sub {
		my ($self, @cmd) = @_;
		shift(@cmd) if ref($cmd[0]) eq 'HASH';
		push @bosh_calls, "@cmd";
		die "unexpected bosh call: @cmd\n";
	};
	local *Genesis::Env::is_bosh_director = sub { 1 };
	local *Genesis::Env::ManifestProvider::entombed_self = sub { $builds++; goto &$entombed_self };

	local $Genesis::Commands::COMMAND_OPTIONS = {yes => 1};
	my $cwd = getcwd();
	chdir($top->path) or die "cannot enter ".$top->path.": $!";
	my $error;
	my $output = combined_from { eval { Genesis::Commands::Env::deploy('child') }; $error = $@ };
	chdir($cwd);
	return {
		error => $error, output => $output, uploads => \@uploads,
		bosh_calls => \@bosh_calls, builds => $builds,
		blueprints => $Genesis::Hook::Blueprint::CpiContext::RUNS, downloads => [@DOWNLOADS],
	};
}

subtest 'a director builds its CPI values once the configs its blueprint reads are downloaded' => sub {
	for my $parent_config ("cpis: []\n", undef) {
		my $r = deploy_past_downloads(parent_config => $parent_config);
		my $label = defined($parent_config) ? 'with' : 'without';
		like $r->{error}, qr/\A\Q${\($SENTINEL =~ s{\n}{}r)}\E/, "the command ran past its config downloads ($label a parent CPI config)";
		unlike $r->{output}, qr/as it is written/, 'and no value was read as written';
		ok $r->{builds}, 'the values came from the entombed build';
		is $r->{blueprints}, 1, 'whose blueprint, which needs the cloud config, ran once';
		is_deeply $r->{downloads}, ['cloud'], 'and the cloud config was downloaded once, for the build and the deploy alike';
		is scalar(@{$r->{uploads}}), 1, 'and the config was uploaded once';
		is_deeply $r->{bosh_calls}, [], 'and the parent was never asked about the director';
	}
};

subtest 'a director builds its CPI values outside deploy once the configs its blueprint reads are downloaded' => sub {
	my $top = fixture_env();
	my $env = $top->load_env('child');
	my $parent = parent_director();
	my $credhub = bless {}, 'Test::Fake::Credhub';
	my @uploads;
	local $Genesis::Hook::Blueprint::CpiContext::RUNS = 0;
	local @DOWNLOADS;
	local $ENV{GENESIS_CLOUD_CONFIG}; # a download registers the config here too

	no warnings qw(redefine once);
	local *Test::Fake::Credhub::paths = sub { () };
	local *Test::Fake::Credhub::base = sub { '/parent/child-bosh/' };
	local *Genesis::Env::is_bosh_director = sub { 1 };
	local *Genesis::Env::vault = sub { $HOOK_VAULT };
	local *Genesis::Env::with_bosh = sub { $_[0] };
	local *Genesis::Env::is_ocfp = sub { 1 };
	local *Genesis::Env::bosh = sub { $parent };
	local *Genesis::Env::credhub = sub { $credhub };
	local *Service::BOSH::Director::has_config_of_type = sub { 0 };
	local *Service::BOSH::Director::download_configs = \&download_config;
	local *Service::BOSH::Director::upload_config = sub { push @uploads, $_[1]; ('', 0, '') };
	local *Service::BOSH::Director::execute = sub { die "the parent was asked about the director\n" };

	my $error;
	combined_from {
		eval {
			Genesis::Commands::Bosh::_bosh_configs_upload_cpi($env, {
				status => 'missing', name => 'child.test.bosh', bosh => $parent,
			});
		};
		$error = $@;
	};
	is $error, '', 'bosh-configs uploads the CPI config without an error';
	is scalar(@uploads), 1, 'and uploads it once';
	is $Genesis::Hook::Blueprint::CpiContext::RUNS, 1, 'after the blueprint, which needs the cloud config, ran once';
	is_deeply \@DOWNLOADS, ['cloud'], 'and the cloud config was downloaded once';

	my $config;
	combined_from {
		eval { ($config) = $env->run_hook('cpi-config', credhub_prefix => $env->cpi_credhub_base) };
		$error = $@;
	};
	is $error, '', 'a bare run_hook renders it without an error too';
	is_deeply [map {[@{$_->{properties}}{qw/host custom/}]} @{load_yaml($config // '')->{cpis} // []}], [['10.0.0.1', 'kept']],
		'from the values the build holds';
	is_deeply \@DOWNLOADS, ['cloud'], 'and reuses the cloud config it already has';
};


done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
