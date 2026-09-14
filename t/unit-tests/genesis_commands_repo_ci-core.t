#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
# For automation_blocks, the three blocks the schema requires of an
# automated provider, which the fixtures below carry.
use Harness::Propagation;
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
	if ($opts{pipeline_provider}) {
		$content .= "pipeline:\n  provider: $opts{pipeline_provider}\n";
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
	if ($opts{pipeline}) {
		$content .= "pipeline:\n";
		for my $key (sort keys %{$opts{pipeline}}) {
			my $val = $opts{pipeline}{$key};
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

	# An enabled pipeline derives its remote and its repository from git, so
	# the fixture is a checkout with a GitHub remote rather than a bare
	# directory holding a configuration file.
	run({dir => $dir}, 'git', 'init', '-q');
	run({dir => $dir}, 'git', 'remote', 'add', 'origin',
		'https://github.com/genesis/test-kit-deployments.git');

	return $dir;
}

subtest 'v2 config loads and augments pipeline.enabled default' => sub {
	my $dir = make_v3_repo(workdir("v2-augment"), version => 2);

	my $top = Genesis::Top->new($dir, no_vault => 1);
	ok !$top->pipeline_enabled, "pipeline_enabled is false for v2 config";
	is $top->pipeline_provider_type, undef,
		"pipeline_provider_type is undef for v2 config";
	is $top->config->get('pipeline.enabled'), 0, "pipeline.enabled defaults to false";
	is $top->config->get_source('pipeline'), 'default', "the pipeline section comes from the default layer";
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
	my $dir = make_v3_repo(workdir("v3-disabled"), pipeline => { enabled => 'false' });

	my $top = Genesis::Top->new($dir, no_vault => 1);
	ok !$top->pipeline_enabled, "pipeline_enabled is false";
	is $top->pipeline_provider_type, undef,
		"pipeline_provider_type is undef with the pipeline switched off";
};

subtest 'v3 config validates with CI enabled and provider' => sub {
	my $dir = make_v3_repo(workdir("v3-enabled"), pipeline => {
		enabled  => 'true',
		provider => { type => 'concourse', target => 'pipes/lmelt', url => 'https://pipes.example.com', team => 'lmelt' },
		name => 'bosh',
		automation_blocks(),
	});

	my $top = Genesis::Top->new($dir, no_vault => 1);
	ok $top->pipeline_enabled, "pipeline_enabled is true";
	ok !$top->manual_pipeline, "a concourse pipeline is not the manual one";
	is $top->config->get('pipeline.provider.type'), 'concourse', "provider type is concourse";
	is $top->config->get('pipeline.provider.target'), 'pipes/lmelt', "provider target correct";
	is $top->config->get('pipeline.name'), 'bosh', "pipeline name correct";
};

subtest 'v3 config treats an enabled gate with no provider as manual' => sub {
	my $dir = make_v3_repo(workdir("v3-no-provider"), pipeline => { enabled => 'true' });

	my $top = Genesis::Top->new($dir, no_vault => 1);
	lives_ok { $top->config } "an enabled gate with no provider still loads";
	ok $top->pipeline_enabled, "the gate reads back as on";
	is $top->config->get('pipeline.provider.type'), 'manual',
		"and the absent provider block reads back as a manual pipeline";
};

subtest 'v3 config with ci.yml and CI configured warns' => sub {
	# v3 already declares CI; the stale ci.yml is a noise warning, not
	# a bail.  The v3 config wins downstream.
	my $dir = make_v3_repo(workdir("v3-conflict"), pipeline => {
		enabled  => 'true',
		provider => { type => 'concourse', target => 'pipes/test', url => 'https://ci.example.com', team => 'test' },
		automation_blocks(),
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
	ok $top->pipeline_enabled, "v3 CI config still wins";
	ok !$top->has_legacy_ci_yml, "legacy flag not set when v3 CI is configured";
};

subtest 'v3 config with ci.yml and CI not configured flags as legacy' => sub {
	my $dir = make_v3_repo(workdir("v3-migrate"), pipeline => { enabled => 'false' });
	mkfile_or_fail("$dir/ci.yml", "---\npipeline:\n  layouts:\n    - sandbox\n");

	my $top = Genesis::Top->new($dir, no_vault => 1);
	lives_ok { $top->config } "v3 + ci.yml + disabled CI loads without bailing";
	ok $top->has_legacy_ci_yml, "has_legacy_ci_yml flag is set";
};

subtest 'v3 config rejects unknown pipeline keys' => sub {
	my $dir = workdir("v3-unknown-key");
	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<EOF);
---
creator_version: 3.2.0
deployment_type: test-kit
version: 3
pipeline:
  enabled: false
  bogus_key: should_fail
EOF

	my $top = Genesis::Top->new($dir, no_vault => 1);
	eval { $top->config };
	like $@, qr/unknown configuration key/, "rejects unknown key in the pipeline section";
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
pipeline:
  enabled: true
  provider:
    type: jenkins
EOF

	my $top = Genesis::Top->new($dir, no_vault => 1);
	eval { $top->config };
	like $@, qr/jenkins|expected/, "rejects invalid provider type enum value";
};

subtest 'v2 config write-back does not persist pipeline defaults' => sub {
	my $dir = make_v3_repo(workdir("v2-writeback"), version => 2);

	my $top = Genesis::Top->new($dir, no_vault => 1);
	# ci.enabled should be accessible
	is $top->config->get('pipeline.enabled'), 0, "pipeline.enabled is available via get";

	# But _explicit_contents (what gets saved) should NOT have ci
	my $explicit = $top->config->_explicit_contents;
	ok !exists $explicit->{pipeline}, "pipeline section not in explicit contents (won't persist)";
};

subtest 'new repos created with LATEST_CONFIG_VERSION' => sub {
	is Genesis::Top::LATEST_CONFIG_VERSION(), 3, "LATEST_CONFIG_VERSION is 3";
};

done_testing;
