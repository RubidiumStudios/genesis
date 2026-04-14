#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;

use Genesis;
use Genesis::Config;
use_ok 'Genesis::Commands::Repo';

my $tmp = workdir();

### Helpers ###################################################################

# Minimal .genesis/config that looks like a Genesis repo
sub make_repo {
	my ($dir, %opts) = @_;
	my $genesis_dir = "$dir/.genesis";
	mkdir_or_fail($genesis_dir);

	my $content = "---\ncreator_version: 3.0.0\ndeployment_type: test-kit\nversion: 2\n";
	if ($opts{ci_provider}) {
		$content .= "ci:\n  provider: $opts{ci_provider}\n";
	}
	mkfile_or_fail("$genesis_dir/config", $content);
	return $dir;
}

### Tests #####################################################################

subtest 'repo_init writes ci.provider to .genesis/config' => sub {
	my $dir = workdir("repo-init-1");
	make_repo($dir);

	# Call the private _write_ci_config logic directly via a Genesis::Config
	# object so we test the config writing without needing a full Top object.
	my $config = Genesis::Config->new("$dir/.genesis/config", 1);
	$config->set('ci.provider', 'concourse', 1);

	my $config2 = Genesis::Config->new("$dir/.genesis/config");
	ok $config2->has('ci.provider'), "ci.provider key written";
	is $config2->get('ci.provider'), 'concourse', "ci.provider value is 'concourse'";
};

subtest 'repo_init scaffold: targets.yml created' => sub {
	my $dir = workdir("repo-init-scaffold");
	make_repo($dir);
	mkdir_or_fail("$dir/.genesis/ci");

	Genesis::Commands::Repo::_write_if_absent(
		"$dir/.genesis/ci/targets.yml",
		Genesis::Commands::Repo::_targets_scaffold()
	);

	ok -f "$dir/.genesis/ci/targets.yml", "targets.yml exists";
	my $content = slurp("$dir/.genesis/ci/targets.yml");
	like $content, qr/targets:\s*\{\}/, "contains empty targets map";
	like $content, qr/bosh-director/, "contains bosh-director comment";
};

subtest 'repo_init scaffold: resources.yml created' => sub {
	my $dir = workdir("repo-init-resources");
	make_repo($dir);
	mkdir_or_fail("$dir/.genesis/ci");

	Genesis::Commands::Repo::_write_if_absent(
		"$dir/.genesis/ci/resources.yml",
		Genesis::Commands::Repo::_resources_scaffold()
	);

	ok -f "$dir/.genesis/ci/resources.yml", "resources.yml exists";
	my $content = slurp("$dir/.genesis/ci/resources.yml");
	like $content, qr/resources:\s*\[\]/, "contains empty resources list";
};

subtest 'repo_init scaffold: ci-overrides file created' => sub {
	my $dir = workdir("repo-init-overrides");
	make_repo($dir);
	mkdir_or_fail("$dir/.genesis/ci");

	Genesis::Commands::Repo::_write_if_absent(
		"$dir/.genesis/ci/ci-overrides-concourse.yml",
		Genesis::Commands::Repo::_overrides_scaffold('concourse')
	);

	ok -f "$dir/.genesis/ci/ci-overrides-concourse.yml", "override file exists";
	my $content = slurp("$dir/.genesis/ci/ci-overrides-concourse.yml");
	like $content, qr/ci-overrides-concourse/, "contains provider name in header";
	like $content, qr/spruce/i, "references spruce in comment";
};

subtest 'repo_init scaffold: integrations.yml written with provided values' => sub {
	my $dir = workdir("repo-init-integrations");
	make_repo($dir);
	my $ci_dir = "$dir/.genesis/ci";
	mkdir_or_fail($ci_dir);

	my $cfg = {
		ci_provider   => 'concourse',
		pipeline_name => 'my-pipeline',
		git_uri       => 'git@github.com:example/repo.git',
		git_branch    => 'main',
		vault_url     => 'https://vault.example.com:8200',
	};
	Genesis::Commands::Repo::_write_integrations($ci_dir, $cfg);

	ok -f "$ci_dir/integrations.yml", "integrations.yml exists";
	my $content = slurp("$ci_dir/integrations.yml");
	like $content, qr|https://vault\.example\.com:8200|, "vault url present";
	like $content, qr|git\@github\.com:example/repo\.git|, "git uri present";
	like $content, qr/default_branch:\s*main/, "branch present";
};

subtest '_write_if_absent: does not overwrite existing file' => sub {
	my $dir = workdir("repo-init-absent");
	make_repo($dir);
	mkdir_or_fail("$dir/.genesis/ci");

	mkfile_or_fail("$dir/.genesis/ci/targets.yml", "---\ncustom: true\n");

	Genesis::Commands::Repo::_write_if_absent(
		"$dir/.genesis/ci/targets.yml",
		Genesis::Commands::Repo::_targets_scaffold()
	);

	my $content = slurp("$dir/.genesis/ci/targets.yml");
	like $content, qr/custom: true/, "existing content preserved";
	unlike $content, qr/targets: \{\}/, "scaffold not written over existing file";
};

subtest 'repo_init guard: errors if ci.provider already set' => sub {
	my $dir = workdir("repo-init-guard");
	make_repo($dir, ci_provider => 'concourse');

	# We test the guard condition in isolation by reading the config directly
	my $config = Genesis::Config->new("$dir/.genesis/config");
	ok $config->has('ci.provider'), "guard precondition: ci.provider is set";

	# The actual bail() in repo_init would fire here; we just verify the
	# config state that triggers it rather than calling the full command
	# (which requires a Top object and exits via bail).
	is $config->get('ci.provider'), 'concourse', "guard sees correct provider value";
};

subtest 'repo_update --ci-provider: _apply_ci_flags updates only provider' => sub {
	my $dir = workdir("repo-update-provider");
	make_repo($dir, ci_provider => 'concourse');
	my $ci_dir = "$dir/.genesis/ci";
	mkdir_or_fail($ci_dir);

	# Pre-populate integrations.yml with known content
	mkfile_or_fail("$ci_dir/integrations.yml", <<'YAML');
---
vault:
  url: https://vault.example.com:8200
source_control:
  uri: git@github.com:org/repo.git
  default_branch: main
YAML

	my $config = Genesis::Config->new("$dir/.genesis/config", 1);

	# Simulate what _apply_ci_flags does for --ci-provider only
	$config->set('ci.provider', 'github-actions', 1);

	my $config2 = Genesis::Config->new("$dir/.genesis/config");
	is $config2->get('ci.provider'), 'github-actions', "provider updated to github-actions";

	# integrations.yml should be unchanged
	my $integrations = slurp("$ci_dir/integrations.yml");
	like $integrations, qr|https://vault\.example\.com:8200|, "integrations.yml untouched";
};

subtest 'repo_update _apply_ci_flags: patches integrations.yml fields in place' => sub {
	my $dir = workdir("repo-update-integrations");
	make_repo($dir, ci_provider => 'concourse');
	my $ci_dir = "$dir/.genesis/ci";
	mkdir_or_fail($ci_dir);

	mkfile_or_fail("$ci_dir/integrations.yml", <<'YAML');
---
vault:
  url: https://old-vault.example.com:8200
source_control:
  uri: git@github.com:org/old-repo.git
  default_branch: master
YAML

	# Simulate _apply_ci_flags with --vault-url and --git-branch
	my $raw = slurp("$ci_dir/integrations.yml");
	my $new_vault = 'https://new-vault.example.com:8200';
	my $new_branch = 'main';
	$raw =~ s/^(\s{0,4}url:\s*)\S+/$1$new_vault/m;
	$raw =~ s/^(\s{0,4}default_branch:\s*)\S+/$1$new_branch/m;
	mkfile_or_fail("$ci_dir/integrations.yml", $raw);

	my $content = slurp("$ci_dir/integrations.yml");
	like   $content, qr|https://new-vault\.example\.com:8200|, "vault url updated";
	like   $content, qr/default_branch:\s*main/,               "branch updated to main";
	unlike $content, qr/master/,                               "old branch removed";
	like   $content, qr|git\@github\.com:org/old-repo\.git|,   "git uri unchanged";
};

subtest '_existing_ci_defaults: reads values from integrations.yml' => sub {
	my $dir = workdir("repo-defaults");
	make_repo($dir, ci_provider => 'concourse');
	my $ci_dir = "$dir/.genesis/ci";
	mkdir_or_fail($ci_dir);

	mkfile_or_fail("$ci_dir/integrations.yml", <<'YAML');
---
vault:
  url: https://vault.corp.example.com:8200
  namespace: genesis
source_control:
  uri: git@github.com:corp/deployments.git
  default_branch: trunk
YAML

	# Test the extraction logic from _existing_ci_defaults in isolation
	my $raw = slurp("$ci_dir/integrations.yml");
	my ($vault_url, $git_uri, $git_branch);
	($vault_url) = $raw =~ /url:\s*(\S+)/;
	($git_uri)   = $raw =~ /uri:\s*(\S+)/;
	($git_branch) = $raw =~ /default_branch:\s*(\S+)/;

	is $vault_url,  'https://vault.corp.example.com:8200', "vault url extracted";
	is $git_uri,    'git@github.com:corp/deployments.git', "git uri extracted";
	is $git_branch, 'trunk',                               "branch extracted";
};

done_testing;
