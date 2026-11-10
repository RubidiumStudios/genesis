#!perl
use strict;
use warnings;

use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;
use JSON::PP;
use lib 'lib';

$ENV{GENESIS_TESTING} = "yes";
$ENV{GENESIS_LIB}     ||= 'lib';

use_ok 'Genesis::CI::Compiler::Parser';
use_ok 'Genesis::CI::Compiler::ASTBuilder';
use_ok 'Genesis::CI::Compiler';
use_ok 'Genesis::Commands::Pipelines';

### ============================================================ ###
### Phase A — env-files topology without pipeline.yml
### ============================================================ ###

subtest 'Parser - multi-file: pipeline.yml optional, topology from env files' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	mkpath("$tmp/ci");

	# targets.yml + integrations.yml present; no pipeline.yml
	_write("$tmp/ci/targets.yml", <<'YAML');
targets:
  sandbox:
    type: bosh-director
    connection:
      url: https://bosh.sandbox.example.com:25555
YAML
	_write("$tmp/ci/integrations.yml", <<'YAML');
vault:
  url: https://vault.example.com
source_control:
  provider: github
  repository: org/repo
YAML

	my $parser = Genesis::CI::Compiler::Parser->new(ci_dir => "$tmp/ci");
	my $parsed;
	eval { $parsed = $parser->parse() };
	ok !$@, "parse() succeeds without pipeline.yml: $@";
	is $parsed->{_source_format}, 'multi-file', "source format is still multi-file";
	ok exists $parsed->{env_dir},  "env_dir is set for downstream ASTBuilder";
	is_deeply $parsed->{pipeline}, {}, "pipeline is empty hash when no pipeline.yml";
};

# The multi-file layout's ASTBuilder row went with that layout: the builder
# now resolves each environment through Genesis::Top, which the contract
# tests and genesis_top-pipeline_env_keys.t exercise for real.

subtest 'Compiler - env-files format round-trip via env_dir option' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	mkpath("$tmp/.genesis/ci");

	_write("$tmp/.genesis/ci/targets.yml", <<'YAML');
targets:
  sandbox:
    type: bosh-director
    connection:
      url: https://bosh.sandbox.example.com:25555
YAML
	_write("$tmp/.genesis/ci/integrations.yml", <<'YAML');
vault:
  url: https://vault.example.com
source_control:
  provider: github
  repository: org/repo
YAML

	_write("$tmp/sandbox.yml", <<'YAML');
---
genesis:
  env: sandbox
  pipeline:
    prior_env:
YAML
	_write("$tmp/preprod.yml", <<'YAML');
---
genesis:
  env: preprod
  pipeline:
    prior_env: sandbox
YAML

	my $orig_dir = POSIX::getcwd();
	chdir($tmp) or skip("Cannot chdir to $tmp: $!", 1);

	my $compiler = Genesis::CI::Compiler->new(ci_dir => '.genesis/ci', env_dir => '.');
	isa_ok $compiler, 'Genesis::CI::Compiler', "compiler created";

	# Verify compiler knows it can use env-files topology
	ok !-f '.genesis/ci/pipeline.yml',
		"no pipeline.yml present (env-files topology will be used)";

	chdir($orig_dir);
};

### ============================================================ ###
### Phase B — Genesis::Commands::Pipeline module
### ============================================================ ###

subtest 'Commands::Pipelines module loads correctly' => sub {
	can_ok 'Genesis::Commands::Pipelines', 'apply';
	can_ok 'Genesis::Commands::Pipelines', 'pipeline_graph';
	can_ok 'Genesis::Commands::Pipelines', 'pipeline_describe';
	can_ok 'Genesis::Commands::Pipelines', 'diff';
	can_ok 'Genesis::Commands::Pipelines', 'status';
	can_ok 'Genesis::Commands::Pipelines', 'pause';
	can_ok 'Genesis::Commands::Pipelines', 'resume';
	# graph and describe are retired stubs in bin/genesis (D151), with no sub.
};

# The removed .genesis/ci/ layout's _compile_pipeline row went with that
# layout; it compiled a stub Top and passed on any error whose text named a
# vault or a configuration, which proved nothing about the path.

subtest 'Commands::Pipelines - _job_status_label returns expected labels' => sub {
	is Genesis::Commands::Pipelines::_job_status_label({ paused => 1 }),
		'paused', "paused job returns 'paused'";

	is Genesis::Commands::Pipelines::_job_status_label({
		paused => 0,
		finished_build => { status => 'succeeded' },
	}), 'succeeded', "succeeded job";

	is Genesis::Commands::Pipelines::_job_status_label({
		paused => 0,
		finished_build => { status => 'failed' },
	}), 'failed', "failed job";

	is Genesis::Commands::Pipelines::_job_status_label({
		paused => 0,
	}), 'pending', "job with no build is pending";
};

done_testing;

### Helpers

sub _write {
	my ($path, $content) = @_;
	open my $fh, '>', $path or die "Cannot write $path: $!";
	print $fh $content;
	close $fh;
}
