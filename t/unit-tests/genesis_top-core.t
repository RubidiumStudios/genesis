#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;
use Test::Output;
use Cwd ();
use List::Util qw(all);

use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS}=80;
$ENV{GENESIS_ORIGINATING_DIR} = Cwd::getcwd();

# Unit tests for Genesis::Top methods that don't require vault interaction
# Uses no_vault => 1 to avoid vault dependency

sub make_test_repo {
	my ($tmp, $deployment_type, $creator_version) = @_;
	$deployment_type //= 'test';
	$creator_version //= '3.1.0';

	system("mkdir -p $tmp/.genesis");
	mkfile_or_fail("$tmp/.genesis/config", <<EOF);
---
version: 2
creator_version: $creator_version
deployment_type: $deployment_type
EOF
	return $tmp;
}

subtest 'is_repo validation' => sub {
	my $tmp = workdir();

	# Test is_repo
	my $repo = "$tmp/myrepo";
	system("mkdir -p $repo/.genesis");
	ok(!Genesis::Top->is_repo($repo), "is_repo returns false for .genesis dir without config");

	# Add config but without deployment_type
	mkfile_or_fail("$repo/.genesis/config", "---\nversion: 2\n");
	ok(!Genesis::Top->is_repo($repo), "is_repo returns false for config without deployment_type");

	# Now add proper config with deployment_type
	mkfile_or_fail("$repo/.genesis/config", "---\nversion: 2\ndeployment_type: test\n");
	ok(Genesis::Top->is_repo($repo), "is_repo returns true for valid repo");
	ok(!Genesis::Top->is_repo("$repo/subdir"), "is_repo returns false for non-repo subdirectory");
	ok(!Genesis::Top->is_repo("/nonexistent"), "is_repo returns false for nonexistent path");
	ok(!Genesis::Top->is_repo($tmp), "is_repo returns false for directory without .genesis/config");
};

subtest 'path methods' => sub {
	my $tmp = make_test_repo(workdir());

	my $top = Genesis::Top->new($tmp, no_vault => 1);
	# Use Cwd::abs_path for comparisons to handle /private/var vs /var symlink on macOS
	is(Cwd::abs_path($top->path), Cwd::abs_path($tmp), "path() returns repo root");
	is(Cwd::abs_path($top->path("foo/bar")), Cwd::abs_path("$tmp/foo/bar"), "path(rel) returns absolute path");
	is(Cwd::abs_path($top->path(".genesis/kits")), Cwd::abs_path("$tmp/.genesis/kits"), "path() handles .genesis paths");
};

subtest 'file operations' => sub {
	my $tmp = make_test_repo(workdir());

	my $top = Genesis::Top->new($tmp, no_vault => 1);

	# Test mkfile
	$top->mkfile("test.txt", "content\n");
	ok(-f "$tmp/test.txt", "mkfile creates file in repo root");
	is(slurp("$tmp/test.txt"), "content\n", "mkfile writes correct content");

	$top->mkfile("subdir/nested.txt", "nested\n");
	ok(-f "$tmp/subdir/nested.txt", "mkfile creates nested file");

	# Test mkdir
	$top->mkdir("newdir");
	ok(-d "$tmp/newdir", "mkdir creates directory in repo root");

	$top->mkdir("deep/nested/dir");
	ok(-d "$tmp/deep/nested/dir", "mkdir creates nested directories");
};

subtest 'metadata access' => sub {
	my $tmp = make_test_repo(workdir(), 'mykit', '2.7.0');

	my $top = Genesis::Top->new($tmp, no_vault => 1);

	is($top->type, "mykit", "type() returns deployment_type from config");
	is($top->version, 2, "version() returns config version");
	like($top->genesis_version, qr/^\d+\.\d+\.\d+/, "genesis_version() returns semantic version");
};

subtest 'configuration' => sub {
	my $tmp = make_test_repo(workdir(), 'test', '2.7.0');

	my $top = Genesis::Top->new($tmp, no_vault => 1);

	isa_ok($top->config, 'Genesis::Config', "config() returns Genesis::Config object");
	is($top->config->get('deployment_type'), 'test', "config has correct deployment_type");
	is($top->config->get('version'), 2, "config has correct version");
	is($top->config->get('creator_version'), '2.7.0', "config has creator_version");
};

subtest 'kit providers' => sub {
	my $tmp = make_test_repo(workdir(), 'test', '2.7.0');

	my $top = Genesis::Top->new($tmp, no_vault => 1);

	# Default kit provider object structure
	my $provider = $top->kit_provider;
	isa_ok($provider, 'Genesis::Kit::Provider', "kit_provider returns provider object");
	isa_ok($provider, 'Genesis::Kit::Provider::GenesisCommunity', "default provider is GenesisCommunity");

	is($provider->label, 'Genesis Community organization on Github',
		"provider has correct label");

	# Verify remote structure without making network calls
	my $remote = $provider->{remote};
	ok(defined($remote), "provider has remote property");
	is($remote->{domain}, 'github.com', "remote domain is github.com");
	is($remote->{org}, 'genesis-community', "remote org is genesis-community");
	is($remote->{tls}, 'yes', "remote uses TLS");

	# Test custom kit provider configuration
	mkfile_or_fail("$tmp/.genesis/config", <<EOF);
---
version: 2
deployment_type: test
creator_version: 2.7.0
kit_provider:
  label: My Custom GitHub Provider
  type: github
  domain: github.example.com
  organization: my-custom-org
  tls: "no"
EOF

	my $top2 = Genesis::Top->new($tmp, no_vault => 1);
	my $custom_provider = $top2->kit_provider;
	isa_ok($custom_provider, 'Genesis::Kit::Provider::Github', "custom provider is Github type");
	is($custom_provider->label, 'My Custom GitHub Provider', "custom provider has correct label");

	my $custom_remote = $custom_provider->{remote};
	ok(defined($custom_remote), "custom provider has remote property");
	is($custom_remote->{domain}, 'github.example.com', "custom remote domain matches config");
	is($custom_remote->{org}, 'my-custom-org', "custom remote org matches config");
	is($custom_remote->{tls}, 'no', "custom remote TLS disabled as configured");
};

subtest 'local kits path' => sub {
	my $tmp = make_test_repo(workdir(), 'test', '2.7.0');

	my $top = Genesis::Top->new($tmp, no_vault => 1);

	like($top->local_kits_path, qr/\.genesis\/kits$/,
		"local_kits_path returns .genesis/kits path");

	# Verify dev kit detection
	ok(!$top->has_dev_kit, "has_dev_kit returns false without dev/ directory");

	system("mkdir -p $tmp/dev");
	ok($top->has_dev_kit, "has_dev_kit returns true with dev/ directory");
};

subtest 'repo creation with no_vault' => sub {
	local $Genesis::VERSION = '3.1.0';
	my $basedir = workdir('repo-create-test');

	# Need a mock Vault object to satisfy Genesis::Top->create
	my $mock_vault = mock "Service::Vault::Remote" => {
		url => 'http://mock-vault.local',
		name => 'mock-vault',
		verify => undef,
		namespace => '',
		strongbox => 1,
	};
	no strict 'refs';
	*{"Service::Vault::Remote::target"} = sub { return $mock_vault; };
	use strict 'refs';

	# Test create method with no_vault
	my $top = Genesis::Top->create($basedir, "testkit", version => "v2.8.0", vault => $mock_vault);
	my $tmp = "$basedir/testkit";

	ok(-d "$tmp/.genesis", ".genesis directory created");
	ok(-f "$tmp/.genesis/config", ".genesis/config file created");

	is($top->type, "testkit", "created repo has correct type");
	like(Cwd::abs_path($top->path), qr/\Q$tmp\E$/, "created repo has correct path");

	# Verify config contents
	my $config = $top->config->_explicit_contents;
	is($config->{version}, 2, "config has version 2");
	is($config->{deployment_type}, "testkit", "config has correct deployment_type");
	is($config->{creator_version}, "3.1.0", "config has creator_version");

	# Verify kit_provider is NOT in explicit contents (using default genesis-community)
	ok(!exists $config->{kit_provider}, "config does not have kit_provider (using default)");

	# Verify secrets_provider (vault) is in explicit contents
	ok(exists $config->{secrets_provider}, "config has secrets_provider");
	is($config->{secrets_provider}{url}, 'http://mock-vault.local', "secrets_provider url matches mock vault");
	is($config->{secrets_provider}{verify}, undef, "secrets_provider verify is undef");
	is($config->{secrets_provider}{namespace}, '', "secrets_provider namespace is empty string");
	is($config->{secrets_provider}{strongbox}, 1, "secrets_provider strongbox is true");

	# Verify the actual .genesis/config file matches expected structure
	yaml_is get_file("$tmp/.genesis/config"), <<EOF, ".genesis/config file has correct content";
---
version: 2
deployment_type: testkit
creator_version: "3.1.0"
minimum_version: "3.1.0"
manifest_store: exodus
secrets_provider:
  url: http://mock-vault.local
  alias: mock-vault
  insecure: true
  strongbox: true
  namespace: ""
EOF
};

subtest 'environment discovery' => sub {
	my $tmp = make_test_repo(workdir(), 'cf');

	# Create environment files testing both name-based and explicit inheritance:
	# 1. ci.yml - parent with kit info (NO genesis.env - not an environment)
	# 2. ci-baseline.yml - inherits kit via name-based hierarchy from ci.yml
	# 3. ci-ocfp.yml - also inherits kit via name-based hierarchy from ci.yml
	# 4. prod.yml - environment using genesis.inherits
	# 5. prod-east.yml - inherits kit via name-based hierarchy from prod.yml
	# 6. staging.yml - environment using genesis.inherits
	# 7. invalid.yml - has genesis.env but NO kit and NO inheritance (INVALID!)

	mkfile_or_fail("$tmp/ci.yml", <<EOF);
---
kit:
  name: cf
  version: 1.0.0
params:
  ci_common: value
EOF

	mkfile_or_fail("$tmp/ci-baseline.yml", <<EOF);
---
genesis:
  env: ci-baseline
EOF

	mkfile_or_fail("$tmp/ci-ocfp.yml", <<EOF);
---
genesis:
  env: ci-ocfp
EOF

	mkfile_or_fail("$tmp/prod.yml", <<EOF);
---
genesis:
  env: prod
  inherits: [ci]
params:
  instances: 3
EOF

	mkfile_or_fail("$tmp/prod-east.yml", <<EOF);
---
genesis:
  env: prod-east
params:
  instances: 5
EOF

	mkfile_or_fail("$tmp/staging.yml", <<EOF);
---
genesis:
  env: staging
  inherits: [ci]
EOF

	# Invalid env - has genesis.env but no kit and no inheritance
	mkfile_or_fail("$tmp/invalid.yml", <<EOF);
---
genesis:
  env: invalid
params:
  some: value
EOF

	mkfile_or_fail("$tmp/README.md", "Not an env file");
	mkfile_or_fail("$tmp/.hidden.yml", "Hidden file");

	my $top = Genesis::Top->new($tmp, no_vault => 1);

	# Test envs() method - should handle invalid envs gracefully
	my @envs = sort { $a->name cmp $b->name } $top->envs();

	# Check the env names - invalid.yml should cause error/be skipped
	my @env_names = sort map { $_->name } @envs;

	# This test will initially fail, exposing the bug
	cmp_deeply(\@env_names, bag('ci-baseline', 'ci-ocfp', 'prod', 'prod-east', 'staging'),
		"envs() returns valid environments and skips invalid ones");

	# Verify all returned objects are Genesis::Env
	ok((all { ref($_) eq 'Genesis::Env' } @envs), "envs() returns Genesis::Env objects");

	# Verify it doesn't include parent-only hierarchy files
	ok(!(grep { $_->name eq 'ci' } @envs), "envs() doesn't include ci.yml (no genesis.env)");

	# Verify invalid.yml is not included
	ok(!(grep { $_->name eq 'invalid' } @envs), "envs() doesn't include invalid.yml (no kit info)");

	# Test has_env() method - uses same validation as envs()
	ok($top->has_env('ci-baseline'), "has_env() returns true for valid environment ci-baseline");
	ok($top->has_env('ci-ocfp'), "has_env() returns true for valid environment ci-ocfp");
	ok($top->has_env('prod'), "has_env() returns true for valid environment prod");
	ok($top->has_env('prod-east'), "has_env() returns true for valid environment prod-east");
	ok($top->has_env('staging'), "has_env() returns true for valid environment staging");

	ok(!$top->has_env('ci'), "has_env() returns false for parent-only file (no genesis.env)");
	ok(!$top->has_env('invalid'), "has_env() returns false for invalid environment (no kit info)");
	ok(!$top->has_env('nonexistent'), "has_env() returns false for nonexistent environment");
	ok(!$top->has_env('README'), "has_env() returns false for non-yml file");

	# Test with .yml extension
	ok($top->has_env('ci-baseline.yml'), "has_env() handles .yml extension");
	ok(!$top->has_env('invalid.yml'), "has_env() correctly identifies invalid env even with .yml");
};

subtest 'load_env method' => sub {
	my $tmp = make_test_repo(workdir(), 'test');

	# Test that load_env bails on non-existent environment
	my $top = Genesis::Top->new($tmp, no_vault => 1);
	eval { $top->load_env('nonexistent') };
	like($@, qr/does not exist/, "load_env() bails on non-existent environment");

	# Test that load_env with .yml extension is handled
	mkfile_or_fail("$tmp/basic.yml", <<EOF);
---
genesis:
  env: basic
EOF

	# This will fail because basic.yml has no kit info, but we can verify
	# the error message to confirm load_env is stripping .yml correctly
	eval { $top->load_env('basic.yml') };
	like($@, qr/basic/, "load_env() strips .yml extension when processing");
	unlike($@, qr/basic\.yml\.yml/, "load_env() doesn't double .yml extension");
};

subtest 'link_dev_kit method' => sub {
	my $tmp = make_test_repo(workdir(), 'test');
	my $top = Genesis::Top->new($tmp, no_vault => 1);

	# Create a fake kit directory to link to
	my $kit_dev_path = workdir('kit-dev');
	system("mkdir -p $kit_dev_path");
	mkfile_or_fail("$kit_dev_path/kit.yml", "---\nname: test\nversion: 1.0.0\n");

	# Test successful link creation
	$top->link_dev_kit($kit_dev_path);
	ok(-l "$tmp/dev", "link_dev_kit creates dev symlink");
	is(Cwd::abs_path(readlink("$tmp/dev")), Cwd::abs_path($kit_dev_path),
		"dev symlink points to correct path");

	# Test that linking again overwrites the existing link
	my $kit_dev_path2 = workdir('kit-dev-2');
	system("mkdir -p $kit_dev_path2");
	$top->link_dev_kit($kit_dev_path2);
	is(Cwd::abs_path(readlink("$tmp/dev")), Cwd::abs_path($kit_dev_path2),
		"link_dev_kit overwrites existing symlink");

	# Test that it fails if dev/ exists as a directory
	unlink("$tmp/dev");
	system("mkdir -p $tmp/dev");
	eval { $top->link_dev_kit($kit_dev_path) };
	like($@, qr/dev\/ already exists, and is not a symbolic link/,
		"link_dev_kit fails if dev/ is a directory");

	# Clean up for next test
	system("rm -rf $tmp/dev");

	# Test that it fails with nonexistent path
	eval { $top->link_dev_kit("/nonexistent/path/to/kit") };
	like($@, qr/Unable to locate/, "link_dev_kit fails with nonexistent path");
};

subtest 'embed method' => sub {
	my $tmp = make_test_repo(workdir(), 'test');
	my $top = Genesis::Top->new($tmp, no_vault => 1);

	# Create a fake genesis binary to embed
	my $bin_dir = workdir('bin-test');
	my $fake_bin = "$bin_dir/genesis";
	put_file($fake_bin, "#!/bin/bash\necho 'fake genesis'\n");
	chmod(0755, $fake_bin);

	# Test successful embed
	ok($top->embed($fake_bin), "embed() returns true on success");
	ok(-d "$tmp/.genesis/bin", "embed() creates .genesis/bin directory");
	ok(-f "$tmp/.genesis/bin/genesis", "embed() creates genesis binary");
	ok(-x "$tmp/.genesis/bin/genesis", "embed() makes genesis executable");

	# Verify the content was copied correctly
	is(slurp("$tmp/.genesis/bin/genesis"), slurp($fake_bin),
		"embed() copies binary content correctly");
};

done_testing;
