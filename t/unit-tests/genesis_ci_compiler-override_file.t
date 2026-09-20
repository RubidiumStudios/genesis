#!perl
# Proves T13, T14, and T310: the override file sits beside .genesis/config
# and is named for the configured provider, nothing reads .genesis/ci/,
# --platform is refused as an unknown option, a provider that emits
# several files takes the per-file form under output_layout: multiple, a
# non-YAML output passes through untouched, and output_layout is refused
# under a provider that declares no such key.  It also proves what the
# override name does with a directory, what the run says about the naming
# form it is not reading, how often one merge announces itself, and what a
# merge spruce refuses exits with.
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
use_ok 'Genesis::CI::ProviderCompiler';
use_ok 'Genesis::CI::ProviderRegistry';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], provider => 'manual');

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
	# Four rows, plus the restoration assertion run_genesis makes of its
	# own accord.
	plan tests => 5;

	put_file($h->a.'/.genesis/pipeline-overrides-concourse.yml',
		"jobs:\n- name: extra\n");
	my @names = Genesis::CI::Compiler->override_file_names(
		'concourse', ['pipeline.yml'], 'single');
	is_deeply \@names, ['.genesis/pipeline-overrides-concourse.yml'],
		'the single-file form is named for the provider alone';

	# Nothing reads configuration out of .genesis/ci/ any more.  One file
	# under lib/ still names the directory, which is the compile gate in
	# Genesis::Commands::Pipelines, and it names it only to tell an
	# operator that a leftover directory is being ignored.  Saying a
	# directory is not read is not reading it, so that file is allowed
	# the mention, while every other module is held to silence.
	#
	# What the gate is allowed is a shape and not a token.  A comment is
	# prose about the directory, the notice is a message to the operator,
	# and a bare `if -d` asks the filesystem a question whose answer goes
	# nowhere.  A line that binds the name to anything is refused however
	# it is guarded, because binding it is what restoring it as a
	# configuration source looks like.
	mkdir_or_fail($h->a.'/.genesis/ci');
	put_file($h->a.'/.genesis/ci/ci-overrides-concourse.yml',
		"jobs:\n- name: stale\n");
	my $gate = 'lib/Genesis/Commands/Pipelines.pm';
	my @offenders = grep {
		$_ ne $gate && do {
			my $body = do {local (@ARGV, $/) = ($_); <>};
			$body =~ m{\.genesis/ci\b};
		};
	} split /\n/, qx{find lib -name '*.pm'};
	is_deeply \@offenders, [], 'no module reads the old directory';

	my $gate_body = do {local (@ARGV, $/) = ($gate); <>};
	my @named = grep {m{\.genesis/ci\b}} split /\n/, $gate_body;
	my $binds = qr{=[^>~=]|=$};
	my @loose;
	for my $line (@named) {
		next if $line =~ m{^\s*#};
		next if $line =~ m{\binfo\(}                    && $line !~ $binds;
		next if $line =~ m{^\s*(?:\)\s*)?if\s+-d\s} && $line !~ $binds;
		push @loose, $line;
	}
	is_deeply \@loose, [],
		'and the gate names it only to say so, never to read it';

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

subtest 'the provider offers the key and the key decides the layout' => sub {
	plan tests => 3;

	# The key is declared by the provider that can emit several files, so
	# with a real provider that declares multi_file_output false there is
	# no such key to write and the schema refuses it by name as the
	# configuration loads, before any programmatic check runs.
	throws_ok {load_with($h, automated_config('concourse',
		'target: ci', 'output_layout: multiple'))}
		qr/pipeline\.provider\.output_layout: unknown configuration key/s,
		'the key is refused where the provider declares no such key';

	put_file('t/tmp/lib/Genesis/CI/Provider/Many.pm', <<'MANYCLI');
package Genesis::CI::Provider::Many;
use base 'Genesis::CI::Provider';
# The base's new is the factory's, and it refuses to build a subclass, so
# a CLI-side fixture the load path constructs brings its own.
sub new {my ($c, %cfg) = @_; bless {%cfg}, $c}
# The block this provider is checked against is the fragment declared
# here, so a key the operator may write under an ability this provider
# claims is declared here too, or the check refuses what the schema
# offered.
sub provider_options_schema {
	return {
		output_layout => {
			type        => 'enum',
			values      => [qw/single multiple/],
			default     => 'single',
			description => 'Whether the override file is named per emitted file'
		},
	};
}
# The ability that makes the key worth declaring sits on this class too,
# because one class answers for both halves of a provider.
sub capabilities {
	return {deployment_locks => 1, cross_pipeline_events => 1,
	        optional_git_triggers => 1, scheduled_jobs => 1,
	        per_commit_runs => 1, multi_file_output => 1};
}
1;
MANYCLI
	put_file('t/tmp/lib/Genesis/CI/ProviderCompiler/Many.pm', <<'MANY');
package Genesis::CI::ProviderCompiler::Many;
use parent 'Genesis::CI::ProviderCompiler';
sub provider_type {'many'}
1;
MANY
	local @INC = ('t/tmp/lib', @INC);
	Genesis::CI::ProviderRegistry->register_provider('many', {
		class     => 'Genesis::CI::ProviderCompiler::Many',
		file      => 'Genesis/CI/ProviderCompiler/Many.pm',
		cli_class => 'Genesis::CI::Provider::Many',
		cli_file  => 'Genesis/CI/Provider/Many.pm',
	});

	for my $layout (qw/single multiple/) {
		lives_ok {load_with($h, automated_config('many', "output_layout: $layout"))}
			"$layout validates where the provider declares the key";
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

subtest 'an emitted file in a subdirectory still merges' => sub {
	plan skip_all => 'spruce not in PATH' unless have_spruce();
	plan tests => 1;

	# The override name flattens an emitted file's separators to dashes so
	# that it stays one path segment beside the configuration.  The
	# temporary file the merge is based on is named from the same string,
	# and a name carrying its separators wants a directory under the work
	# directory that nothing creates.  Concourse emits one file at the top
	# level, so the first provider to emit a tree is what meets this.
	my ($tmp, $top) = override_top();
	write_override($tmp, "---\nextra_key: injected_by_override\n");

	my $compiler = Genesis::CI::Compiler->new(top => $top);
	my $output   = {'jobs/deploy.yml' => "---\nbase_key: base_value\n"};

	my $result;
	output_from {
		$result = $compiler->_apply_provider_overrides($output, 'concourse');
	};

	like $result->{'jobs/deploy.yml'}, qr/extra_key:\s*injected_by_override/,
		'a file emitted under a directory is merged like any other';
};

done_testing;
