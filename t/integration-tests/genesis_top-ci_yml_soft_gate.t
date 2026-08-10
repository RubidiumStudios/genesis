#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;
use Genesis;

# Coverage for Genesis::Top->has_legacy_ci_yml.
#
# Under the softened ci.yml v2->v3 handling, Top no longer bail()s at
# config-load when a legacy pipeline ci.yml is present.  Instead it
# sets a flag on the Top instance that command dispatch reads to
# decide whether to gate PIPELINE-group commands.  These subtests pin
# the flag's behaviour across all the relevant repo shapes.

use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Top';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# make_repo(type, version, ci_yml_content?)
#
# Builds a repo skeleton (.genesis/config with the given schema
# version) and optionally drops a ci.yml at the repo root with the
# supplied contents.  Returns the repo path so tests can chdir /
# instantiate Top against it.
sub make_repo {
	my (%o) = @_;
	my $tmp = workdir($o{name} || 'ci-yml-soft-gate');
	system("rm -rf $tmp && mkdir -p $tmp/.genesis") == 0
		or die "make_repo setup failed";
	mkfile_or_fail("$tmp/.genesis/config", <<EOF);
---
version: $o{version}
creator_version: "3.1.0"
deployment_type: testkit
EOF
	if ($o{version} == 3) {
		# v3 schema requires manifest_store; add the minimum so
		# schema validation passes.
		open my $fh, '>>', "$tmp/.genesis/config" or die $!;
		print $fh "manifest_store: exodus\n";
		if ($o{v3_ci_configured}) {
			print $fh "ci:\n";
			print $fh "  enabled: true\n";
			print $fh "  provider:\n";
			print $fh "    type: concourse\n";
		}
		close $fh;
	}
	if (defined $o{ci_yml}) {
		mkfile_or_fail("$tmp/ci.yml", $o{ci_yml});
	}
	return $tmp;
}

my $legacy_pipeline_yml = <<EOF;
---
meta:
  target-vault: (( vault "secret/prod/genesis:target" ))
pipeline:
  name: legacy-repo
  git:
    branch: main
  boshes:
    prod-us-east:
      auth: ((admin))
EOF

my $env_yml_named_ci = <<EOF;
---
kit:
  name: cf
  version: 1.0.0
genesis:
  env: ci
params:
  base_domain: ci.example.com
EOF

subtest 'v2 config + legacy ci.yml -> flag is set' => sub {
	my $tmp = make_repo(name => 'v2-with-legacy', version => 2,
		ci_yml => $legacy_pipeline_yml);
	my $top = Genesis::Top->new($tmp, no_vault => 1);
	ok($top, 'Top loads cleanly (no bail)');
	is($top->has_legacy_ci_yml, 1, 'has_legacy_ci_yml is 1');
};

subtest 'v3 config + legacy ci.yml + no ci configured -> flag is set' => sub {
	my $tmp = make_repo(name => 'v3-legacy-only', version => 3,
		ci_yml => $legacy_pipeline_yml);
	my $top = Genesis::Top->new($tmp, no_vault => 1);
	ok($top, 'Top loads cleanly (no bail)');
	is($top->has_legacy_ci_yml, 1, 'has_legacy_ci_yml is 1');
};

subtest 'v3 config + legacy ci.yml + ci already configured -> flag is 0, warning' => sub {
	my $tmp = make_repo(name => 'v3-ci-configured', version => 3,
		v3_ci_configured => 1,
		ci_yml => $legacy_pipeline_yml);
	my ($top, $has_flag);
	$Genesis::Log::Logger = undef;
	my ($stdout, $stderr) = output_from {
		$top = Genesis::Top->new($tmp, no_vault => 1);
		$has_flag = $top->has_legacy_ci_yml;
	};
	ok($top, 'Top loads cleanly (no bail)');
	is($has_flag, 0,
		'has_legacy_ci_yml is 0 -- v3 config wins, ci.yml is ignored');
	# \s+ between the words, not a literal space: the message interpolates
	# a temp path and the logger wraps the result, so where the line breaks
	# moves with the length of $TMPDIR.  Matching a literal space passes or
	# fails depending on the machine it runs on.
	like($stderr, qr/Legacy.*present\s+alongside.*v3\s+CI\s+configuration/s,
		'warning emitted about the stale ci.yml');
};

subtest 'no ci.yml at all -> flag is 0' => sub {
	my $tmp = make_repo(name => 'no-ci-yml', version => 2);
	my $top = Genesis::Top->new($tmp, no_vault => 1);
	is($top->has_legacy_ci_yml, 0, 'has_legacy_ci_yml is 0');
};

subtest 'ci.yml that is an env file (not a pipeline config) -> flag is 0' => sub {
	# A file named ci.yml but whose content is a Genesis env file
	# (has `kit:` and `genesis:`, no top-level `pipeline:`) must NOT
	# be treated as a legacy CI config.  See _is_legacy_ci_file.
	my $tmp = make_repo(name => 'env-named-ci', version => 2,
		ci_yml => $env_yml_named_ci);
	my $top = Genesis::Top->new($tmp, no_vault => 1);
	is($top->has_legacy_ci_yml, 0,
		'has_legacy_ci_yml is 0 -- env-shaped ci.yml is not a pipeline config');
};

done_testing;
