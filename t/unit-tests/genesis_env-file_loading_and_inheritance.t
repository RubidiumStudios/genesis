#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;
use Test::Exception;
use Test::More;

use Genesis;
$Genesis::VERSION = '999.999.999'; # force dev mode for testing
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

$ENV{GENESIS_OUTPUT_COLUMNS}=80;

# Create test repository with dev kit (unit test - no vault)
my $top = Genesis::Top->create(workdir, 'env-loading-test', no_vault => 1);
$top->link_dev_kit('t/src/simple');
isa_ok($top, 'Genesis::Top', 'test repository created');

subtest 'Single File Environment' => sub {
	put_file $top->path('minimal.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: minimal
EOF

	my $env;
	lives_ok {
		$env = $top->load_env('minimal');
	} 'minimal environment loads without error';

	isa_ok($env, 'Genesis::Env', 'loaded environment');
	is($env->name, 'minimal', 'environment name is correct');

	ok($env->defines('kit.name'), 'kit.name is defined');
	is($env->lookup('kit.name'), 'dev', 'kit name is dev (development kit)');
	is($env->lookup('kit.version'), 'latest', 'kit version is latest');

	put_file $top->path('prod.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: prod

params:
  deployment_name: test-prod
  network: prod-network
EOF

	lives_ok {
		$env = $top->load_env('prod');
	} 'prod environment loads without error';

	is($env->name, 'prod', 'prod environment name is correct');
	is($env->lookup('params.deployment_name'), 'test-prod', 'deployment_name is set');
	is($env->lookup('params.network'), 'prod-network', 'network param is set');

	ok($env->defines('kit.name'), 'required kit.name field present');
	ok($env->defines('kit.version'), 'required kit.version field present');
};

subtest 'Name-Based Hierarchy - Complete Linear Progression' => sub {
	put_file $top->path('us.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: us

params:
  region: us
  level: 1
  override_test: level-1
  us_specific: true
EOF

	put_file $top->path('us-west.yml'), <<EOF;
---
genesis:
  env: us-west

params:
  sub_region: west
  level: 2
  override_test: level-2
  west_specific: true
EOF

	my $test_env = bless({name => "us-west", top => $top}, 'Genesis::Env');
	cmp_deeply([$test_env->potential_environment_files()], [
		'./us.yml',
		'./us-west.yml'
	], 'us-west potential files correct');

	cmp_deeply([$test_env->actual_environment_files()], [
		'./us.yml',
		'./us-west.yml'
	], 'us-west actual files correct');

	my $env;
	lives_ok {
		$env = $top->load_env('us-west');
	} 'two-level hierarchy environment loads';

	is($env->name, 'us-west', 'environment name includes hierarchy');
	is($env->lookup('params.region'), 'us', 'base region parameter inherited');
	ok($env->lookup('params.us_specific'), 'base-specific param inherited');
	is($env->lookup('params.sub_region'), 'west', 'sub-region parameter added');
	ok($env->lookup('params.west_specific'), 'west-specific param added');
	is($env->lookup('params.level'), 2, 'level parameter overridden');
	is($env->lookup('params.override_test'), 'level-2', 'override works - level 2 wins');

	put_file $top->path('us-west-1.yml'), <<EOF;
---
genesis:
  env: us-west-1

params:
  az: 1
  level: 3
  override_test: level-3
  az1_specific: true
EOF

	$test_env = bless({ name => "us-west-1", top => $top }, 'Genesis::Env');
	cmp_deeply([$test_env->potential_environment_files()], [
		'./us.yml',
		'./us-west.yml',
		'./us-west-1.yml'
	], 'us-west-1 potential files correct');

	cmp_deeply([$test_env->actual_environment_files()], [
		'./us.yml',
		'./us-west.yml',
		'./us-west-1.yml'
	], 'us-west-1 actual files correct');

	lives_ok {
		$env = $top->load_env('us-west-1');
	} 'three-level hierarchy environment loads';

	is($env->name, 'us-west-1', 'three-level environment name');
	is($env->lookup('params.region'), 'us', 'level 1 param inherited');
	is($env->lookup('params.sub_region'), 'west', 'level 2 param inherited');
	is($env->lookup('params.az'), 1, 'level 3 param added');
	is($env->lookup('params.level'), 3, 'level overridden three times');
	is($env->lookup('params.override_test'), 'level-3', 'override works - level 3 wins');
};

subtest 'Name-Based Hierarchy - Gaps in Ancestry' => sub {
	put_file $top->path('comp.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: comp

params:
  company: acme
  level: comp
EOF

	put_file $top->path('comp-dept-iaas.yml'), <<EOF;
---
genesis:
  env: comp-dept-iaas

params:
  iaas: aws
  level: comp-dept-iaas
EOF

	put_file $top->path('comp-dept-iaas-region-env.yml'), <<EOF;
---
genesis:
  env: comp-dept-iaas-region-env

params:
  region: us-east-1
  level: comp-dept-iaas-region-env
EOF

	my $test_env = bless({ name => "comp-dept-iaas-region-env", top => $top }, 'Genesis::Env');
	cmp_deeply([$test_env->potential_environment_files()], [
		'./comp.yml',
		'./comp-dept.yml',
		'./comp-dept-iaas.yml',
		'./comp-dept-iaas-region.yml',
		'./comp-dept-iaas-region-env.yml'
	], 'comp-dept-iaas-region-env potential files include all hierarchy levels');

	cmp_deeply([$test_env->actual_environment_files()], [
		'./comp.yml',
		'./comp-dept-iaas.yml',
		'./comp-dept-iaas-region-env.yml'
	], 'comp-dept-iaas-region-env actual files only includes existing files');

	my $env;
	lives_ok {
		$env = $top->load_env('comp-dept-iaas-region-env');
	} 'environment with gaps in hierarchy loads without error';

	is($env->name, 'comp-dept-iaas-region-env', 'full environment name');
	is($env->lookup('params.company'), 'acme', 'param from comp.yml inherited');
	is($env->lookup('params.iaas'), 'aws', 'param from comp-dept-iaas.yml inherited');
	is($env->lookup('params.region'), 'us-east-1', 'param from leaf file present');
	is($env->lookup('params.level'), 'comp-dept-iaas-region-env', 'leaf overrides all ancestors');
	ok(!$env->defines('params.dept'), 'missing comp-dept.yml does not cause issues');
	ok(!$env->defines('params.env_name'), 'missing comp-dept-iaas-region.yml does not cause issues');
};

subtest 'genesis.inherits Chains' => sub {
	put_file $top->path('base.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: base

params:
  base_param: base-value
  shared_param: base-default
  network: base-network
EOF

	put_file $top->path('inherit-single.yml'), <<EOF;
---
genesis:
  env: inherit-single
  inherits:
    - base

params:
  override_param: single-value
  shared_param: single-override
EOF

	my $env;
	lives_ok {
		$env = $top->load_env('inherit-single');
	} 'environment with single inheritance loads';

	is($env->name, 'inherit-single', 'inheriting environment name correct');
	is($env->lookup('params.base_param'), 'base-value', 'base param inherited');
	is($env->lookup('params.network'), 'base-network', 'network inherited from base');
	is($env->lookup('params.shared_param'), 'single-override', 'child overrides base param');
	is($env->lookup('kit.name'), 'dev', 'kit inherited from base');

	put_file $top->path('inherit-chain-base.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: inherit-chain-base

params:
  chain_level: base
  chain_param: base-value
  override_chain: base
EOF

	put_file $top->path('inherit-chain-mid.yml'), <<EOF;
---
genesis:
  env: inherit-chain-mid
  inherits:
    - inherit-chain-base

params:
  chain_level: mid
  chain_param: mid-value
  override_chain: mid
  mid_specific: true
EOF

	put_file $top->path('inherit-chain-top.yml'), <<EOF;
---
genesis:
  env: inherit-chain-top
  inherits:
    - inherit-chain-mid

params:
  chain_level: top
  override_chain: top
  top_specific: true
EOF

	lives_ok {
		$env = $top->load_env('inherit-chain-top');
	} 'multi-level inheritance chain loads';

	is($env->name, 'inherit-chain-top', 'top of chain name correct');
	is($env->lookup('params.chain_param'), 'mid-value', 'middle value wins');
	is($env->lookup('params.override_chain'), 'top', 'top overrides cascade correctly');
	ok($env->defines('params.mid_specific'), 'mid-specific param inherited');
	ok($env->defines('params.top_specific'), 'top-specific param present');
};

subtest 'Mixed Hierarchy + Inheritance' => sub {
	put_file $top->path('mixed-base.yml'), <<EOF;
---
genesis:
  env: mixed-base
  inherits:
    - base

params:
  env_type: mixed
  level: base
  mixed_base: true
EOF

	put_file $top->path('mixed-base-level1.yml'), <<EOF;
---
genesis:
  env: mixed-base-level1
  inherits:
    - base

params:
  env_type: mixed
  level: 1
  mixed_level1: true
EOF

	my $env;
	lives_ok {
		$env = $top->load_env('mixed-base-level1');
	} 'hierarchical child with inheritance loads';

	is($env->name, 'mixed-base-level1', 'mixed hierarchy child name');

	# Should merge hierarchy (mixed-base.yml -> mixed-base-level1.yml)
	# AND inheritance (both inherit from base.yml)
	is($env->lookup('params.base_param'), 'base-value', 'inherited from base via inheritance');
	is($env->lookup('params.env_type'), 'mixed', 'inherited from hierarchy parent');
	is($env->lookup('params.level'), 1, 'child level overrides parent');
	ok($env->defines('params.mixed_level1'), 'child-specific param present');
};

subtest 'Advanced Inheritance Edge Cases' => sub {
	put_file $top->path('hierarchy-base.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: hierarchy-base

params:
  hierarchy_base_param: base-value
  explicit_test: base
EOF

	put_file $top->path('hierarchy-base-child.yml'), <<EOF;
---
genesis:
  env: hierarchy-base-child
  inherits:
    - hierarchy-base

params:
  child_param: child-value
  explicit_test: child
EOF

	my $env;
	lives_ok {
		$env = $top->load_env('hierarchy-base-child');
	} 'explicit inheritance of hierarchical parent loads';

	# Should inherit from hierarchy-base both via name hierarchy AND explicit inherits
	is($env->lookup('params.hierarchy_base_param'), 'base-value', 'base param inherited');
	is($env->lookup('params.explicit_test'), 'child', 'child overrides base despite explicit inheritance');

	put_file $top->path('dedup-base.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: dedup-base

params:
  dedup_marker: base
  load_count: 1
EOF

	put_file $top->path('dedup-a.yml'), <<EOF;
---
genesis:
  env: dedup-a
  inherits:
    - dedup-base

params:
  a_param: a-value
EOF

	put_file $top->path('dedup-a-b.yml'), <<EOF;
---
genesis:
  env: dedup-a-b
  inherits:
    - dedup-base

params:
  b_param: b-value
EOF

	put_file $top->path('dedup-a-b-c.yml'), <<EOF;
---
genesis:
  env: dedup-a-b-c
  inherits:
    - dedup-base

params:
  c_param: c-value
EOF

	lives_ok {
		$env = $top->load_env('dedup-a-b-c');
	} 'multiple inheritance of same base loads';

	is($env->lookup('params.dedup_marker'), 'base', 'base marker present');
	is($env->lookup('params.a_param'), 'a-value', 'a param inherited via hierarchy');
	is($env->lookup('params.b_param'), 'b-value', 'b param inherited via hierarchy');
	is($env->lookup('params.c_param'), 'c-value', 'c param present');

	put_file $top->path('cross-e.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: cross-e

params:
  e_param: e-value
  cross_level: e
EOF

	put_file $top->path('cross-e-f.yml'), <<EOF;
---
genesis:
  env: cross-e-f

params:
  f_param: f-value
  cross_level: f
EOF

	put_file $top->path('cross-a-b-c.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: cross-a-b-c
  inherits:
    - cross-e-f

params:
  abc_param: abc-value
EOF

	my 	$test_env = bless({ name => "cross-a-b-c", top => $top }, 'Genesis::Env');
	cmp_deeply([$test_env->potential_environment_files()], [
		'./cross.yml',
		'./cross-a.yml',
		'./cross-a-b.yml',
		'./cross-a-b-c.yml'
	], 'cross-a-b-c potential files include its own hierarchy');

	# actual don't include non-existent hierarchy files, but do include the inherited ones, including their hierarchy.
	cmp_deeply([$test_env->actual_environment_files()], [
		'./cross-e.yml',
		'./cross-e-f.yml',
		'./cross-a-b-c.yml'
	], 'cross-a-b-c actual files only includes leaf file (no hierarchy files exist)');

	lives_ok {
		$env = $top->load_env('cross-a-b-c');
	} 'cross-hierarchy inheritance loads';

	is($env->lookup('params.e_param'), 'e-value', 'e param inherited via hierarchy of inherited file');
	is($env->lookup('params.f_param'), 'f-value', 'f param inherited from explicitly inherited file');
	is($env->lookup('params.abc_param'), 'abc-value', 'own param present');
	is($env->lookup('params.cross_level'), 'f', 'f overrides e');

	put_file $top->path('diamond-f.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: diamond-f

params:
  diamond_level: f
  f_specific: true
EOF

	put_file $top->path('diamond-e.yml'), <<EOF;
---
genesis:
  env: diamond-e
  inherits:
    - diamond-f

params:
  diamond_level: e
  e_specific: true
EOF

	put_file $top->path('diamond-d.yml'), <<EOF;
---
genesis:
  env: diamond-d
  inherits:
    - diamond-f

params:
  diamond_level: d
  d_specific: true
EOF

	put_file $top->path('diamond-a-b-c.yml'), <<EOF;
---
genesis:
  env: diamond-a-b-c
  inherits:
    - diamond-e
    - diamond-d

params:
  diamond_level: abc
  abc_specific: true
EOF

	lives_ok {
		$env = $top->load_env('diamond-a-b-c');
	} 'diamond inheritance pattern loads';

	ok($env->defines('params.f_specific'), 'f level present');
	ok($env->defines('params.e_specific'), 'e level present');
	ok($env->defines('params.d_specific'), 'd level present');
	ok($env->defines('params.abc_specific'), 'abc level present');
	is($env->lookup('params.diamond_level'), 'abc', 'abc overrides all previous levels');
};

subtest 'Parameter Validation' => sub {
	my $env = $top->load_env('us-west-1');

	ok($env->defines('params.region'), 'level 1 param exists');
	ok($env->defines('params.sub_region'), 'level 2 param exists');
	ok($env->defines('params.az'), 'level 3 param exists');
	is($env->lookup('params.override_test'), 'level-3', 'later file wins override');

	$env = $top->load_env('minimal');
	ok(!$env->defines('params.nonexistent'), 'nonexistent param returns false');
	is($env->lookup('params.nonexistent'), undef, 'nonexistent param lookup returns undef');
};

subtest 'Circular Dependency Detection' => sub {
	# Test case: cycle-a-b includes cycle-a (hierarchy), cycle-a inherits cycle-b,
	# cycle-b inherits cycle-x-y, cycle-x-y includes cycle-x (hierarchy),
	# cycle-x inherits cycle-a-b (completes the cycle)

	put_file $top->path('cycle-a.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: cycle-a
  inherits:
    - cycle-b

params:
  from_a: true
  cycle_marker: a
EOF

	put_file $top->path('cycle-a-b.yml'), <<EOF;
---
genesis:
  env: cycle-a-b

params:
  from_a_b: true
  cycle_marker: a-b
EOF

	put_file $top->path('cycle-b.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: cycle-b
  inherits:
    - cycle-x-y

params:
  from_b: true
  cycle_marker: b
EOF

	put_file $top->path('cycle-x.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest

genesis:
  env: cycle-x
  inherits:
    - cycle-a-b

params:
  from_x: true
  cycle_marker: x
EOF

	put_file $top->path('cycle-x-y.yml'), <<EOF;
---
genesis:
  env: cycle-x-y

params:
  from_x_y: true
  cycle_marker: x-y
EOF

	my $test_env = bless({ name => "cycle-a-b", top => $top }, 'Genesis::Env');

	# Use alarm to detect infinite loops - set 5 second timeout
	my $timeout = 5;
	my $timed_out = 0;
	local $SIG{ALRM} = sub { $timed_out = 1; die "timeout\n" };

	# Test actual_environment_files with timeout
	my @actual_files;
	eval {
		alarm($timeout);
		@actual_files = $test_env->actual_environment_files();
		alarm(0);
	};
	my $actual_files_error = $@;
	alarm(0);  # Ensure alarm is cleared

	ok(!$timed_out, 'actual_environment_files completed within timeout (no infinite loop)');
	is($actual_files_error, '', 'actual_environment_files did not die') or diag("Error: $actual_files_error");

	if (!$timed_out && !$actual_files_error) {
		cmp_deeply(\@actual_files, [
			'./cycle-x.yml',
			'./cycle-x-y.yml',
			'./cycle-b.yml',
			'./cycle-a.yml',
			'./cycle-a-b.yml'
		], 'circular environment actual files resolved correctly');
	}

	# Test load_env with timeout
	my $env;
	$timed_out = 0;
	eval {
		alarm($timeout);
		$env = $top->load_env('cycle-a-b');
		alarm(0);
	};
	my $load_error = $@;
	alarm(0);  # Ensure alarm is cleared

	ok(!$timed_out, 'load_env completed within timeout (no infinite loop)');
	is($load_error, '', 'load_env did not die') or diag("Error: $load_error");

	# Only run remaining tests if load succeeded
	if (!$timed_out && !$load_error && $env) {
		is($env->name, 'cycle-a-b', 'circular environment name correct');
		ok($env->defines('params.from_a_b'), 'params from cycle-a-b present');
		ok($env->defines('params.from_a'), 'params from cycle-a present');
		ok($env->defines('params.from_b'), 'params from cycle-b present');
		ok($env->defines('params.from_x'), 'params from cycle-x present');
		ok($env->defines('params.from_x_y'), 'params from cycle-x-y present');
		is($env->lookup('params.cycle_marker'), 'a-b', 'cycle-a-b overrides all in the cycle');
	}

	# Duplicate tests for cycle-x.
	$test_env = bless({ name => "cycle-x", top => $top }, 'Genesis::Env');

	eval {
		alarm($timeout);
		$ENV{TEST} = 'cycle-x';
		@actual_files = $test_env->actual_environment_files();
		alarm(0);
	};
	$actual_files_error = $@;
	alarm(0);  # Ensure alarm is cleared

	ok(!$timed_out, '[cycle-x] actual_environment_files completed within timeout (no infinite loop)');
	is($actual_files_error, '', '[cycle-x] actual_environment_files did not die') or diag("Error: $actual_files_error");

	if (!$timed_out && !$actual_files_error) {
		cmp_deeply(\@actual_files, [
			'./cycle-x-y.yml',
			'./cycle-b.yml',
			'./cycle-a.yml',
			'./cycle-a-b.yml',
			'./cycle-x.yml'
		], '[cycle-x] circular environment actual files resolved correctly');
	}

	# Test load_env with timeout [cycle-x]
	$env = undef;
	$timed_out = 0;
	eval {
		alarm($timeout);
		$env = $top->load_env('cycle-x');
		alarm(0);
	};
	$load_error = $@;
	alarm(0);  # Ensure alarm is cleared

	ok(!$timed_out, 'load_env completed within timeout (no infinite loop)');
	is($load_error, '', 'load_env did not die') or diag("Error: $load_error");

	# Only run remaining tests if load succeeded
	if (!$timed_out && !$load_error && $env) {
		is($env->name, 'cycle-x', '[cycle-x] circular environment name correct');
		ok($env->defines('params.from_a_b'), '[cycle-x] params from cycle-a-b present');
		ok($env->defines('params.from_a'), '[cycle-x] params from cycle-a present');
		ok($env->defines('params.from_b'), '[cycle-x] params from cycle-b present');
		ok($env->defines('params.from_x'), '[cycle-x] params from cycle-x present');
		ok($env->defines('params.from_x_y'), '[cycle-x] params from cycle-x-y present');
		is($env->lookup('params.cycle_marker'), 'x', 'cycle-x overrides all in the cycle');
	}

	# Duplicate tests for cycle-a.
	$test_env = bless({ name => "cycle-a", top => $top }, 'Genesis::Env');

	eval {
		alarm($timeout);
		$ENV{TEST} = 'cycle-a';
		@actual_files = $test_env->actual_environment_files();
		alarm(0);
	};
	$actual_files_error = $@;
	alarm(0);  # Ensure alarm is cleared

	ok(!$timed_out, '[cycle-a] actual_environment_files completed within timeout (no infinite loop)');
	is($actual_files_error, '', '[cycle-a] actual_environment_files did not die') or diag("Error: $actual_files_error");

	if (!$timed_out && !$actual_files_error) {
		cmp_deeply(\@actual_files, [
			'./cycle-a-b.yml',
			'./cycle-x.yml',
			'./cycle-x-y.yml',
			'./cycle-b.yml',
			'./cycle-a.yml'
		], '[cycle-a] circular environment actual files resolved correctly');
	}

	# Test load_env with timeout [cycle-a]
	$env = undef;
	$timed_out = 0;
	eval {
		alarm($timeout);
		$env = $top->load_env('cycle-a');
		alarm(0);
	};

	$load_error = $@;
	alarm(0);  # Ensure alarm is cleared

	ok(!$timed_out, 'load_env completed within timeout (no infinite loop)');
	is($load_error, '', 'load_env did not die') or diag("Error: $load_error");

	# Only run remaining tests if load succeeded
	if (!$timed_out && !$load_error && $env) {
		is($env->name, 'cycle-a', '[cycle-a] circular environment name correct');
		ok($env->defines('params.from_a_b'), '[cycle-a] params from cycle-a-b present');
		ok($env->defines('params.from_a'), '[cycle-a] params from cycle-a present');
		ok($env->defines('params.from_b'), '[cycle-a] params from cycle-b present');
		ok($env->defines('params.from_x'), '[cycle-a] params from cycle-x present');
		ok($env->defines('params.from_x_y'), '[cycle-a] params from cycle-x-y present');
		is($env->lookup('params.cycle_marker'), 'a', 'cycle-a overrides all in the cycle');
	}
};

subtest 'environment name validation during load' => sub {
	# Test that invalid names are rejected during load
	# This ensures validation happens at load time, not just in _env_name_errors
	# Uses the existing $top Genesis::Top object with dev kit already linked

	# Disable color output for cleaner error message matching
	local $ENV{NOCOLOR} = 1;

	my @invalid_cases = (
		{
			name => 'Prod',
			desc => 'starts with uppercase letter',
			pattern => qr/environment name.*must start with.*lowercase.*letter/ims,
		},
		{
			name => 'test-env-',
			desc => 'ends with hyphen',
			pattern => qr/environment name.*must not end with.*hyphen/ims,
		},
		{
			name => '123-test--env',
			desc => 'starts with number and contains sequential hyphens',
			pattern => qr/environment name/ims,  # Should mention multiple violations
		},
		{
			name => '_private',
			desc => 'starts with underscore',
			pattern => qr/environment name.*must start with.*lowercase.*letter/ims,
		},
		{
			name => 'my env',
			desc => 'contains whitespace',
			pattern => qr/environment name.*whitespace/ims,
		},
		{
			name => 'env!prod',
			desc => 'contains special character',
			pattern => qr/environment name.*lowercase letters.*numbers.*underscores.*hyphens/ims,
		},
	);

	foreach my $case (@invalid_cases) {
		my $name = $case->{name};
		my $desc = $case->{desc};
		my $pattern = $case->{pattern};

		# Create environment file with invalid name
		put_file $top->path("$name.yml"), <<EOF;
---
kit:
  name:    dev
  version: latest
EOF

		# Attempt to load - should fail with validation error
		my $error;
		dies_ok {
			eval {
				$top->load_env($name);
			};
			$error = $@;
			die $error if $error;
		} "loading env with invalid name '$name' ($desc) fails";

		if ($error) {
			like($error, $pattern,
				"error for '$name' mentions environment name validation")
				or diag("Actual error: $error");
		}
	}

	# Test that files not ending with .yml are not considered
	# (This is a different kind of validation - file discovery, not name validation)
	{
		# Create file without .yml extension
		put_file $top->path("testenv.yaml"), <<EOF;
---
kit:
  name:    dev
  version: latest
EOF

		# Should fail to find the file (wrong extension)
		dies_ok {
			$top->load_env('testenv');
		} 'environment file without .yml extension is not found';

		# Create with wrong extension that has .yml somewhere
		put_file $top->path("prod.yml.bak"), <<EOF;
---
kit:
  name:    dev
  version: latest
EOF

		dies_ok {
			$top->load_env('prod.yml.bak');
		} 'environment name cannot contain .yml in the name';
	}

	# Test that valid names still work (sanity check)
	{
		put_file $top->path("valid-env-123.yml"), <<EOF;
---
genesis:
  env: valid-env-123
kit:
  name:    dev
  version: latest
EOF

		my $env;
		my $error;
		lives_ok {
			eval {
				$env = $top->load_env('valid-env-123');
			};
			$error = $@;
			die $error if $error;
		} 'valid environment name loads successfully'
			or diag("Error loading valid env: $error");

		is($env->name, 'valid-env-123', 'loaded environment has correct name')
			if $env;
	}
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
