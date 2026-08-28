#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::Exception;
use Test::Output;

use Genesis;
use Genesis::Config;
use_ok 'Genesis::Commands::Repo';
use_ok 'Genesis::Top';

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

### Config v3 validation tests ################################################

# Initialize $Genesis::RC for tests that consult global config
provide_rc();

sub make_v3_repo {
	my ($dir, %opts) = @_;
	my $genesis_dir = "$dir/.genesis";
	mkdir_or_fail($genesis_dir);

	my $version = $opts{version} // 3;
	my $content = "---\ncreator_version: 3.2.0\ndeployment_type: test-kit\nversion: $version\n";
	if ($opts{ci}) {
		$content .= "ci:\n";
		for my $key (sort keys %{$opts{ci}}) {
			my $val = $opts{ci}{$key};
			if (ref($val) eq 'HASH') {
				$content .= "  $key:\n";
				for my $subkey (sort keys %$val) {
					$content .= "    $subkey: $val->{$subkey}\n";
				}
			} else {
				$content .= "  $key: $val\n";
			}
		}
	}
	mkfile_or_fail("$genesis_dir/config", $content);
	return $dir;
}

subtest 'v2 config loads and augments ci.enabled default' => sub {
	my $dir = make_v3_repo(workdir("v2-augment"), version => 2);

	my $top = Genesis::Top->new($dir, no_vault => 1);
	ok !$top->ci_enabled, "ci_enabled is false for v2 config";
	ok !$top->ci_configured, "ci_configured is false for v2 config";
	is $top->config->get('ci.enabled'), 0, "ci.enabled defaults to false";
	is $top->config->get_source('ci'), 'default', "ci section comes from default layer";
};

subtest 'v2 config with ci.yml flags as legacy' => sub {
	# Soft-gate migration: repo loads with has_legacy_ci_yml set so
	# dispatch can gate pipeline commands behind the migration prompt
	# while non-pipeline commands (deploy, check, ...) keep working.
	my $dir = make_v3_repo(workdir("v2-ci-yml"), version => 2);
	mkfile_or_fail("$dir/ci.yml", "---\npipeline:\n  layouts:\n    - sandbox\n");

	my $top = Genesis::Top->new($dir, no_vault => 1);
	lives_ok { $top->config } "v2 + ci.yml loads without bailing";
	ok $top->has_legacy_ci_yml, "has_legacy_ci_yml flag is set";
};

subtest 'v3 config validates with CI disabled' => sub {
	my $dir = make_v3_repo(workdir("v3-disabled"), ci => { enabled => 'false' });

	my $top = Genesis::Top->new($dir, no_vault => 1);
	ok !$top->ci_enabled, "ci_enabled is false";
	ok !$top->ci_configured, "ci_configured is false";
};

subtest 'v3 config validates with CI enabled and provider' => sub {
	my $dir = make_v3_repo(workdir("v3-enabled"), ci => {
		enabled  => 'true',
		provider => { type => 'concourse', target => 'pipes/lmelt', url => 'https://pipes.example.com', team => 'lmelt' },
		name => 'bosh',
	});

	my $top = Genesis::Top->new($dir, no_vault => 1);
	ok $top->ci_enabled, "ci_enabled is true";
	ok $top->ci_configured, "ci_configured is true";
	is $top->config->get('ci.provider.type'), 'concourse', "provider type is concourse";
	is $top->config->get('ci.provider.target'), 'pipes/lmelt', "provider target correct";
	is $top->config->get('ci.name'), 'bosh', "ci name correct";
};

subtest 'v3 config bails when enabled but no provider' => sub {
	my $dir = make_v3_repo(workdir("v3-no-provider"), ci => { enabled => 'true' });

	my $top = Genesis::Top->new($dir, no_vault => 1);
	eval { $top->config };
	like $@, qr/missing required key/, "bails when enabled without provider";
	like $@, qr/provider/, "bail message references provider";
};

subtest 'v3 config with ci.yml and CI configured warns' => sub {
	# v3 already declares CI; the stale ci.yml is a noise warning, not
	# a bail.  The v3 config wins downstream.
	my $dir = make_v3_repo(workdir("v3-conflict"), ci => {
		enabled  => 'true',
		provider => { type => 'concourse', target => 'pipes/test', url => 'https://ci.example.com', team => 'test' },
	});
	mkfile_or_fail("$dir/ci.yml", "---\npipeline:\n  layouts:\n    - sandbox\n");

	my $top = Genesis::Top->new($dir, no_vault => 1);

	# Capture it: this is the one path that actually emits the warning, so
	# letting it print both leaks into the TAP stream and leaves the
	# behaviour this subtest is named for unasserted.  Assertions stay
	# outside the block -- Test::Output would swallow their TAP output too.
	my $err;
	my $out = combined_from { eval { $top->config }; $err = $@; };

	is $err, '', "v3 + ci.yml + configured CI loads without bailing";
	like $out, qr/Legacy .*ci\.yml.* present alongside a v3 CI configuration/,
		"and warns that the stale ci.yml is being ignored";
	ok $top->ci_configured, "v3 CI config still wins";
	ok !$top->has_legacy_ci_yml, "legacy flag not set when v3 CI is configured";
};

subtest 'v3 config with ci.yml and CI not configured flags as legacy' => sub {
	my $dir = make_v3_repo(workdir("v3-migrate"), ci => { enabled => 'false' });
	mkfile_or_fail("$dir/ci.yml", "---\npipeline:\n  layouts:\n    - sandbox\n");

	my $top = Genesis::Top->new($dir, no_vault => 1);
	lives_ok { $top->config } "v3 + ci.yml + disabled CI loads without bailing";
	ok $top->has_legacy_ci_yml, "has_legacy_ci_yml flag is set";
};

subtest 'v3 config rejects unknown ci keys' => sub {
	my $dir = workdir("v3-unknown-key");
	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<EOF);
---
creator_version: 3.2.0
deployment_type: test-kit
version: 3
ci:
  enabled: false
  bogus_key: should_fail
EOF

	my $top = Genesis::Top->new($dir, no_vault => 1);
	eval { $top->config };
	like $@, qr/unknown configuration key/, "rejects unknown key in ci section";
	like $@, qr/bogus_key/, "error mentions the offending key";
};

subtest 'v3 config rejects invalid provider type' => sub {
	my $dir = workdir("v3-bad-provider");
	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<EOF);
---
creator_version: 3.2.0
deployment_type: test-kit
version: 3
ci:
  enabled: true
  provider:
    type: jenkins
EOF

	my $top = Genesis::Top->new($dir, no_vault => 1);
	eval { $top->config };
	like $@, qr/jenkins|expected/, "rejects invalid provider type enum value";
};

subtest 'v2 config write-back does not persist ci defaults' => sub {
	my $dir = make_v3_repo(workdir("v2-writeback"), version => 2);

	my $top = Genesis::Top->new($dir, no_vault => 1);
	# ci.enabled should be accessible
	is $top->config->get('ci.enabled'), 0, "ci.enabled is available via get";

	# But _explicit_contents (what gets saved) should NOT have ci
	my $explicit = $top->config->_explicit_contents;
	ok !exists $explicit->{ci}, "ci section not in explicit contents (won't persist)";
};

subtest 'new repos created with LATEST_CONFIG_VERSION' => sub {
	is Genesis::Top::LATEST_CONFIG_VERSION(), 3, "LATEST_CONFIG_VERSION is 3";
};

subtest 'ci_control_branch returns constant for MVP' => sub {
	my $dir = make_v3_repo(workdir("v3-control"), ci => {
		enabled  => 'true',
		provider => { type => 'concourse', target => 'pipes/test', url => 'https://ci.example.com', team => 'test' },
	});

	my $top = Genesis::Top->new($dir, no_vault => 1);
	is $top->ci_control_branch, 'control', "ci_control_branch returns 'control'";
};

done_testing;
