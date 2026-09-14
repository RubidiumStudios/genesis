#!perl
# Proves T13, T14, and T310: the override file sits beside .genesis/config
# and is named for the configured provider, nothing looks in .genesis/ci/,
# --platform is refused as an unknown option, a provider that emits
# several files takes the per-file form under output_layout: multiple, a
# non-YAML output passes through untouched, and output_layout is refused
# where multi_file_output is false.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;
use Test::Exception;

use Genesis;
provide_rc();
use_ok 'Genesis::Top';
use_ok 'Genesis::CI::Compiler';
use_ok 'Genesis::CI::Compiler::PipelineProvider';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], provider => 'manual');

# Two rows in a row can ask for the same configuration, and the harness's
# commit needs a delta, so each load carries its own count beside the file
# under test.
my $loads = 0;

sub load_with {
	my ($body) = @_;
	commit_on_control($h, files => {
		'.genesis/config' => join("\n",
			'---', 'deployment_type: bosh', 'version: "3"',
			'creator_version: 3.2.0', $body, ''),
		'.load-count' => sprintf("%d\n", ++$loads),
	});
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	$top->config;
	return $top;
}

# The harness clones copy A from a bare repository at a filesystem path, so
# the source-control block names the repository rather than deriving it,
# and every provider here is an automated one, which is the case where the
# clone credential and the committer identity are required beside it, as
# are the shuttle, the vault, and the locker.
sub automated_config {
	my ($type, @lines) = @_;
	return join("\n", 'pipeline:', '  enabled: true',
		'  source_control:',
		'    repository: genesis/bosh-deployments',
		'    auth:',
		'      type: ssh',
		'      vault: secret/ci/git',
		'    identity:',
		'      name: Genesis CI',
		'      email: ci@genesis.example.com',
		'  provider:', "    type: $type",
		(map {"    $_"} @lines),
		'  shuttle:', '    backend: s3', '    bucket: pipes',
		'  vault:', '    url: https://vault.example.com',
		'  locker:', '    url: https://locker.example.com');
}

subtest 'the override sits beside the configuration' => sub {
	# Three rows, plus the restoration assertion run_genesis makes of its
	# own accord.
	plan tests => 4;

	put_file($h->a.'/.genesis/pipeline-overrides-concourse.yml',
		"jobs:\n- name: extra\n");
	my @names = Genesis::CI::Compiler->override_file_names(
		'concourse', ['pipeline.yml'], 'single');
	is_deeply \@names, ['.genesis/pipeline-overrides-concourse.yml'],
		'the single-file form is named for the provider alone';

	# Nothing looks under .genesis/ci/ any more.
	mkdir_or_fail($h->a.'/.genesis/ci');
	put_file($h->a.'/.genesis/ci/ci-overrides-concourse.yml',
		"jobs:\n- name: stale\n");
	my @offenders = grep {
		my $body = do {local (@ARGV, $/) = ($_); <>};
		$body =~ m{\.genesis/ci\b};
	} split /\n/, qx{find lib -name '*.pm'};
	is_deeply \@offenders, [], 'nothing under lib/ reads the old directory';

	# A usage error prints its own reason only outside test mode, where
	# command_usage renders the full description instead, so the variable
	# that puts Genesis in test mode is dropped for this one run and the
	# refusal says why it refused.
	my ($out, $err, $exit) = do {
		delete local $ENV{GENESIS_TESTING};
		run_genesis($h, 'pipeline-apply', '--platform', 'concourse');
	};
	like $err, qr/Unknown option.*platform/i, '--platform is refused as an unknown option';
};

subtest 'a provider that emits several files takes the per-file form' => sub {
	plan tests => 4;

	is_deeply [Genesis::CI::Compiler->override_file_names(
			'github-actions', ['deploy-qa.yml', 'deploy-prod.yml'], 'multiple')],
		['.genesis/pipeline-overrides-github-actions-deploy-qa.yml',
		 '.genesis/pipeline-overrides-github-actions-deploy-prod.yml'],
		'each emitted file gets its own override, named by its base name';

	is_deeply [Genesis::CI::Compiler->override_file_names(
			'github-actions', ['deploy-qa.yml', 'deploy-prod.yml'], 'single')],
		['.genesis/pipeline-overrides-github-actions.yml'],
		'the same provider set to single takes the single-file form';

	is_deeply [Genesis::CI::Compiler->override_file_names(
			'concourse', ['pipeline.yml'], 'single')],
		['.genesis/pipeline-overrides-concourse.yml'],
		'a provider emitting one file keeps that form';

	# A non-YAML output is passed through rather than merged.
	my $merged = Genesis::CI::Compiler->new(top => Genesis::Top->new($h->a, no_vault => 1))
		->_apply_provider_overrides({'run.sh' => "#!/bin/sh\necho hi\n"}, 'concourse');
	is $merged->{'run.sh'}, "#!/bin/sh\necho hi\n",
		'a non-YAML output passes through untouched';
};

subtest 'the capability gates the key and the key decides the layout' => sub {
	plan tests => 3;

	# The key is offered only where the capability is true, so with a real
	# provider that declares multi_file_output false there is no such key
	# to write and the schema refuses it by name as the configuration
	# loads, before any programmatic check runs.  The gate that names the
	# capability beside the key is reachable only through a fragment that
	# declares the key itself, and genesis_top-provider_capabilities.t
	# proves it there.
	throws_ok {load_with(automated_config('concourse',
		'target: ci', 'output_layout: multiple'))}
		qr/pipeline\.provider\.output_layout: unknown configuration key/s,
		'the key is refused where the capability is false';

	put_file('t/tmp/lib/Genesis/CI/Compiler/Providers/Many.pm', <<'MANY');
package Genesis::CI::Compiler::Providers::Many;
use parent 'Genesis::CI::Compiler::PipelineProvider';
sub provider_type {'many'}
sub provider_options_schema {return {}}
sub capabilities {
	return {deployment_locks => 1, cross_pipeline_events => 1,
	        optional_git_triggers => 1, scheduled_jobs => 1,
	        per_commit_runs => 1, multi_file_output => 1};
}
1;
MANY
	local @INC = ('t/tmp/lib', @INC);
	Genesis::CI::Compiler::PipelineProvider->register_provider('many', {
		class     => 'Genesis::CI::Compiler::Providers::Many',
		file      => 'Genesis/CI/Compiler/Providers/Many.pm',
		cli_class => 'Genesis::CI::Provider::Manual',
		cli_file  => 'Genesis/CI/Provider/Manual.pm',
	});

	for my $layout (qw/single multiple/) {
		lives_ok {load_with(automated_config('many', "output_layout: $layout"))}
			"$layout validates where the capability is true";
	}
};

done_testing;
