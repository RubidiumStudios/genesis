#!perl
# Proves T13, T14, and T310: the override file sits beside .genesis/config
# and is named for the configured provider, nothing looks in .genesis/ci/,
# --platform is refused as an unknown option, a provider that emits
# several files takes the per-file form under output_layout: multiple, a
# non-YAML output passes through untouched, and output_layout is refused
# where multi_file_output is false.  It also proves what the override
# name does with a directory, what the run says about the naming form it
# is not reading, how often one merge announces itself, and what a merge
# spruce refuses exits with.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
# Test::Exit installs the hook that makes an exit catchable in a BEGIN
# block, and the exit it has to catch is the one Genesis::bail spends, so
# it comes before anything that compiles Genesis.
use Test::Exit;
use helper;
use Harness::Propagation;
use Test::More;
use Test::Exception;
use Test::Output;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Exit qw/CONFIG/;
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

# The merge rows want a deployment root of their own, because an override
# one row writes must not be there for the next, and the harness's copy A
# is shared by every row in the file.  A configuration is all these rows
# need beside the override.
sub override_top {
	my $tmp = tempdir(CLEANUP => 1);
	put_file("$tmp/.genesis/config", join("\n",
		'---', 'deployment_type: bosh', 'version: "3"',
		'creator_version: 3.2.0', ''));
	return ($tmp, Genesis::Top->new($tmp, no_vault => 1));
}

sub write_override {
	my ($tmp, $body) = @_;
	put_file("$tmp/.genesis/pipeline-overrides-concourse.yml", $body);
}

# spruce merges the override over the generated output, so the two rows
# that watch a merge happen have nothing to watch without it.
sub have_spruce {
	chomp(my $spruce = `which spruce 2>/dev/null`);
	return $spruce && -x $spruce;
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

subtest 'the name of a multi-file override keeps its directory' => sub {
	plan tests => 4;

	# Two outputs that share a base name but sit in different directories
	# must not collapse onto one override file, so the directory travels
	# into the name with its separators flattened.
	my @names = Genesis::CI::Compiler->override_file_names(
		'concourse', ['qa/deploy.yml', 'prod/deploy.yml'], 'multiple');

	is scalar(@names), 2, 'one override name per emitted file';
	isnt $names[0], $names[1],
		'outputs in different directories get different override files';
	is_deeply [sort @names], [
		'.genesis/pipeline-overrides-concourse-prod-deploy.yml',
		'.genesis/pipeline-overrides-concourse-qa-deploy.yml',
	], 'the directory survives in the name with its separator flattened';

	is_deeply [
		Genesis::CI::Compiler->override_file_names(
			'concourse', ['pipeline.yml'], 'multiple')
	], ['.genesis/pipeline-overrides-concourse-pipeline.yml'],
		'an output with no directory keeps its plain base name';
};

subtest 'the other naming form is named, not passed over in silence' => sub {
	plan tests => 3;

	my ($tmp, $top) = override_top();

	# The layout in force is single, so the run reads
	# pipeline-overrides-concourse.yml.  An operator who wrote the
	# multi-file form's file gets told it is being passed over rather
	# than losing the merge with nothing said.
	put_file("$tmp/.genesis/pipeline-overrides-concourse-pipeline.yml",
		"---\nshould_not: appear\n");

	my $compiler = Genesis::CI::Compiler->new(top => $top);
	my $output = {'pipeline.yml' => "---\njobs: []\n"};

	my ($result, $out, $err);
	($out, $err) = output_from {
		$result = $compiler->_apply_provider_overrides($output, 'concourse');
	};

	is_deeply $result, $output, "the other form's file is not merged";
	like "$out$err", qr/pipeline-overrides-concourse-pipeline\.yml/,
		'the file that is being passed over is named';
	like "$out$err", qr/ignor/i,
		'the notice says the file is being ignored';
};

subtest 'one override over several files announces itself once' => sub {
	plan skip_all => 'spruce not in PATH' unless have_spruce();
	plan tests => 3;

	my ($tmp, $top) = override_top();
	write_override($tmp, "---\nextra_key: injected_by_override\n");

	my $compiler = Genesis::CI::Compiler->new(top => $top);
	my $output = {
		'one.yml' => "---\nbase_key: one\n",
		'two.yml' => "---\nbase_key: two\n",
	};

	my ($result, $out, $err);
	($out, $err) = output_from {
		$result = $compiler->_apply_provider_overrides($output, 'concourse');
	};

	like $result->{'one.yml'}, qr/extra_key:\s*injected_by_override/,
		'the first file is merged';
	like $result->{'two.yml'}, qr/extra_key:\s*injected_by_override/,
		'the second file is merged';

	my $applied = () = ("$out$err" =~ /Applying /g);
	is $applied, 1,
		'the single form announces its one merge once, not once per file';
};

subtest 'a merge spruce refuses exits at the configuration code' => sub {
	plan skip_all => 'spruce not in PATH' unless have_spruce();
	plan tests => 1;

	my ($tmp, $top) = override_top();
	write_override($tmp, "---\nbroken: [unclosed\n");

	my $compiler = Genesis::CI::Compiler->new(top => $top);
	my $output = {'pipeline.yml' => "---\nbase_key: base_value\n"};

	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my $code;
	output_from {
		$code = exit_code {
			$compiler->_apply_provider_overrides($output, 'concourse');
		};
	};

	is $code, CONFIG,
		'an override spruce cannot merge is a configuration refusal';
};

done_testing;
