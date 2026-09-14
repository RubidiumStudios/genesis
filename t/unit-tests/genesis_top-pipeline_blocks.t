#!perl
# Proves T22, T23, and T27: the locker, the shuttle and the vault are each
# required under an automated provider and tolerated as absent under
# manual, the shuttle backend refuses a directory, notifications are
# optional with a repository default the environment overrides, the
# provider-specific keys are validated per provider type, and the three
# keys the decisions removed are refused by name.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

# Everything an automated provider needs but the block under test.  The name
# says what it returns, which is a configuration block rather than a
# repository, so it does not collide with the harness's own automated.
#
# The repository is named rather than derived because copy A is cloned from
# a bare repository at a filesystem path, whose URL carries no GitHub
# owner/repo pair, and the derivation's own refusal belongs to the
# source-control rows rather than to these.
sub automated_pipeline_block {
	my (%opts) = @_;
	my @lines = ('pipeline:', '  enabled: true',
		'  provider:', '    type: concourse', '    target: ci');
	push @lines, @{$opts{provider_extra}} if $opts{provider_extra};
	push @lines, '  source_control:',
		'    repository: team/bosh',
		'    auth:', '      vault: secret/ci/git',
		'    identity:', '      name: Genesis', '      email: ci@example.com';
	push @lines, '  shuttle:', '    backend: s3', '    bucket: pipes'
		unless $opts{shuttle};
	push @lines, '  vault:', '    url: https://vault.example.com'
		unless $opts{vault};
	push @lines, '  locker:', '    url: https://locker.example.com'
		unless $opts{locker};
	return join("\n", @lines);
}

# An assert helper: write one environment file with a nested genesis
# block, because the harness's own writer renders a scalar or a flat list
# and would leave a reference's address behind for anything deeper.
sub write_nested_env {
	my ($name, @lines) = @_;
	commit_on_control($h, files => {"$name.yml" => join("\n",
		'---', 'kit:', '  name:    dev', '  version: latest',
		'genesis:', "  env: $name", '  pipeline:', @lines, '')});
}

subtest 'three blocks are required under an automation' => sub {
	plan tests => 4;

	lives_ok {load_with($h, automated_pipeline_block())} 'the complete section validates';
	for my $block (qw/shuttle vault locker/) {
		throws_ok {load_with($h, automated_pipeline_block($block => 1))}
			qr/pipeline: missing required key $block/,
			"$block is required under an automated provider";
	}
};

subtest 'and every one of them is optional under manual' => sub {
	plan tests => 1;

	lives_ok {load_with($h, join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: manual',
		'  source_control:', '    repository: team/bosh'))}
		'a manual pipeline needs none of the three';
};

subtest 'the shuttle backend refuses a directory' => sub {
	plan tests => 3;

	lives_ok {load_with($h, automated_pipeline_block())} 's3 validates';
	throws_ok {load_with($h, automated_pipeline_block() =~ s/backend: s3/backend: file/r)}
		qr/pipeline\.shuttle\.backend: unknown value/,
		'file is refused, because a directory cannot trigger across pipelines';
	lives_ok {load_with($h, automated_pipeline_block() =~ s/backend: s3/backend: gcs/r)}
		'gcs validates';
};

subtest 'notifications are optional and overridable per environment' => sub {
	plan tests => 4;

	lives_ok {load_with($h, automated_pipeline_block())}
		'the whole block may be left out';

	my $top = load_with($h, join("\n", automated_pipeline_block(),
		'  notifications:', '    slack: ci-alerts'));
	is $top->config->get('pipeline.notifications.style'), 'default',
		'the style resolves to the repository default';

	write_nested_env('qa', '    notifications:', '      style: verbose');
	$top = load_with($h, join("\n", automated_pipeline_block(),
		'  notifications:', '    style: compact'));
	is $top->config->get('pipeline.notifications.style'), 'compact',
		'a written style is the repository default';
	is $top->_merged_env_params('qa')->{genesis}{pipeline}{notifications}{style},
		'verbose',
		'and an environment may override it without changing that default';
};

subtest 'the provider-specific keys are validated per provider type' => sub {
	plan tests => 4;

	lives_ok {load_with($h, automated_pipeline_block(provider_extra => [
		'    public: true', '    tagged: true',
		'    task:', '      image: genesiscommunity/concourse',
		'      version: latest']))}
		'the four Concourse keys validate under Concourse';
	throws_ok {load_with($h, automated_pipeline_block() =~ s/target: ci/target: ci\n    public: maybe/r)}
		qr/pipeline\.provider\.public: expected a boolean/,
		'and their types are enforced';
	throws_ok {load_with($h, join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: manual', '    tagged: true',
		'  source_control:', '    repository: team/bosh'))}
		qr/pipeline\.provider\.tagged: unknown configuration key/,
		'and they exist for Concourse alone';

	my $top = load_with($h, automated_pipeline_block());
	is $top->config->get('pipeline.provider.task.image'),
		'genesiscommunity/concourse',
		'the task image has the default the fragment gave it';
};

subtest 'the removed keys are refused by name' => sub {
	plan tests => 3;

	write_nested_env('qa', '    locks:', '      bosh_upgrade: x');
	throws_ok {load_with($h, automated_pipeline_block())}
		qr/genesis\.pipeline\.locks: unknown configuration key/,
		'the configurable lock is gone, the two locks being mandatory';

	for my $gone (qw/status_signal signal_prefix/) {
		write_nested_env('qa', "    $gone: x");
		throws_ok {load_with($h, automated_pipeline_block())}
			qr/genesis\.pipeline\.$gone: unknown configuration key/,
			"$gone went with the multi-file layout";
	}
};

done_testing;
