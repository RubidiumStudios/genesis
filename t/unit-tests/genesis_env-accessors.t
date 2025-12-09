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
$Genesis::VERSION = '999.999.999'; # force dev mode for testing
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';
use_ok 'Genesis::Kit';

$ENV{GENESIS_OUTPUT_COLUMNS}=80;

subtest 'basic accessors' => sub {
	plan tests => 9;

	my $top = Genesis::Top->create(workdir(), 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('test-env.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env: test-env
EOF

	my $env = $top->load_env('test-env');

	# Test name accessor
	is($env->name, 'test-env', 'name() returns environment name');

	# Test file accessor
	is($env->file, 'test-env.yml', 'file() returns environment file name');

	# Test top accessor
	isa_ok($env->top, 'Genesis::Top', 'top() returns Genesis::Top object');
	is($env->top, $top, 'top() returns the same Top object used to create env');

	# Test type accessor (delegation to top)
	is($env->type, 'thing', 'type() returns deployment type from Top');

	# Test path accessor (delegation to top)
	is($env->path, $top->path, 'path() with no args returns top path');
	is($env->path('subdir/file.yml'), $top->path('subdir/file.yml'),
		'path() delegates to top->path()');

	# Test kit accessor
	isa_ok($env->kit, 'Genesis::Kit', 'kit() returns Genesis::Kit object');
	is($env->kit->name, 'dev', 'kit has correct name');
};

subtest 'signature generation' => sub {
	plan tests => 4;

	my $top = Genesis::Top->create(workdir(), 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('env-a.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: env-a
EOF

	put_file($top->path('env-b.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: env-b
EOF

	my $env_a = $top->load_env('env-a');
	my $env_b = $top->load_env('env-b');

	# Test signature format
	my $sig_a = $env_a->signature;
	like($sig_a, qr/^[a-f0-9]{12}$/, 'signature is 12 hex characters');

	# Test signature uniqueness
	my $sig_b = $env_b->signature;
	isnt($sig_a, $sig_b, 'different environments have different signatures');

	# Test signature stability
	is($env_a->signature, $sig_a, 'signature is stable across multiple calls');

	# Test signature changes with file changes
	my $top2 = Genesis::Top->create(workdir(), 'other-type', no_vault => 1);
	$top2->link_dev_kit('t/src/simple');
	put_file($top2->path('env-a.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: env-a
EOF

	my $env_a2 = $top2->load_env('env-a');
	isnt($env_a->signature, $env_a2->signature,
		'same env name in different types has different signature');
};

subtest 'deployment_name' => sub {
	plan tests => 2;

	my $top = Genesis::Top->create(workdir(), 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('prod.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: prod
EOF

	my $env = $top->load_env('prod');
	is($env->deployment_name, 'prod-bosh',
		'deployment_name combines env name and type');

	# Test with hyphenated environment name
	put_file($top->path('us-west-1-prod.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: us-west-1-prod
EOF

	my $env2 = $top->load_env('us-west-1-prod');
	is($env2->deployment_name, 'us-west-1-prod-bosh',
		'deployment_name handles hyphenated env names');
};

subtest 'manifest_store' => sub {
	plan tests => 2;

	my $top = Genesis::Top->create(workdir(), 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	# Test default manifest store (from config)
	put_file($top->path('default.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: default
EOF

	my $env = $top->load_env('default');
	# Default is set in config, test that it returns a valid value
	ok(defined($env->manifest_store), 'manifest_store returns a defined value');
	ok($env->manifest_store =~ /^(exodus|hybrid|repository)$/,
		'manifest_store returns valid type');
};

subtest 'is_bosh_director' => sub {
	plan tests => 2;

	# Test with non-director kit
	my $top = Genesis::Top->create(workdir(), 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('regular.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: regular
EOF

	my $env = $top->load_env('regular');
	ok(!$env->is_bosh_director, 'environment with non-director kit is not a BOSH director');

	# Test with director kit (custom-bosh has is_bosh_director: true in kit.yml)
	my $top2 = Genesis::Top->create(workdir(), 'bosh', no_vault => 1);
	$top2->link_dev_kit('t/src/custom-bosh');

	put_file($top2->path('director.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: director
EOF

	my $director = $top2->load_env('director');
	ok($director->is_bosh_director, 'environment with director kit (is_bosh_director metadata) is a BOSH director');
};

subtest 'use_create_env - basic behavior' => sub {
	plan tests => 7;

	# Basic tests with simple kit (no metadata) to verify accessor works
	my $top = Genesis::Top->create(workdir(), 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	# Test 1: Explicit genesis.use_create_env: true
	put_file($top->path('explicit-true.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env:            explicit-true
  use_create_env: true
EOF

	my $env = $top->load_env('explicit-true');
	ok($env->use_create_env, 'environment with genesis.use_create_env: true uses create-env');

	# Test 2: Explicit genesis.use_create_env: false
	put_file($top->path('explicit-false.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env:            explicit-false
  use_create_env: false
  bosh_env:       parent-bosh
EOF

	$env = $top->load_env('explicit-false');
	ok(!$env->use_create_env, 'environment with genesis.use_create_env: false does not use create-env');

	# Test 3: Environment with bosh_env specified (no explicit use_create_env)
	put_file($top->path('with-bosh-env.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env:      with-bosh-env
  bosh_env: parent-bosh
EOF

	$env = $top->load_env('with-bosh-env');
	ok(!$env->use_create_env, 'environment with bosh_env does not use create-env by default');

	# Test 4: Environment with 'proto' feature
	put_file($top->path('proto-feature.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
  features:
    - proto
genesis:
  env: proto-feature
EOF

	$env = $top->load_env('proto-feature');
	ok($env->use_create_env, 'environment with proto feature uses create-env');

	# Test 5: BOSH director without bosh_env and without use_create_env
	# Should default to false with simple kit
	put_file($top->path('no-explicit.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env: no-explicit
EOF

	$env = $top->load_env('no-explicit');
	ok(!$env->use_create_env, 'environment without explicit use_create_env or proto defaults to false');

	# Test 6: Boolean-like strings for use_create_env
	put_file($top->path('string-true.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env:            string-true
  use_create_env: 'yes'
EOF

	$env = $top->load_env('string-true');
	ok($env->use_create_env, 'environment with genesis.use_create_env: "yes" uses create-env');

	# Test 7: YAML boolean no (unquoted)
	put_file($top->path('yaml-false.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env:            yaml-false
  use_create_env: no
  bosh_env:       parent-bosh
EOF

	$env = $top->load_env('yaml-false');
	ok(!$env->use_create_env, 'environment with genesis.use_create_env: no (YAML boolean false) does not use create-env');
};

subtest 'accessor error handling' => sub {
	plan tests => 4;

	# Test that accessors fail appropriately with incomplete objects

	# Create incomplete env object (bypassing normal constructors)
	my $incomplete = bless({name => 'test'}, 'Genesis::Env');

	is($incomplete->name, 'test', 'name() works with minimal object');
	is($incomplete->file, undef, 'file() returns undef when not set');

	throws_ok { $incomplete->kit }
		qr/Incompletely initialized environment.*no kit specified/,
		'kit() throws error on incomplete object';

	throws_ok { $incomplete->top }
		qr/Incompletely initialized environment.*no top specified/,
		'top() throws error on incomplete object';
};

subtest 'accessor immutability' => sub {
	plan tests => 3;

	my $top = Genesis::Top->create(workdir(), 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('test.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: test
EOF

	my $env = $top->load_env('test');

	# Verify accessors return consistent values
	my $name1 = $env->name;
	my $name2 = $env->name;
	is($name1, $name2, 'name() returns consistent value');

	my $file1 = $env->file;
	my $file2 = $env->file;
	is($file1, $file2, 'file() returns consistent value');

	my $type1 = $env->type;
	my $type2 = $env->type;
	is($type1, $type2, 'type() returns consistent value');
};

done_testing;  # 8 subtests + 4 use_ok calls = 12 tests total

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
