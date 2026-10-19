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
		'  provider:', '    type: concourse',
		'    url: https://ci.example.com', '    team: main');
	push @lines, @{$opts{provider_extra}} if $opts{provider_extra};
	push @lines, '  source_control:',
		'    repository: team/bosh',
		'    auth:', '      type: ssh', '      path: secret/ci/git',
		'    identity:', '      name: Genesis', '      email: ci@example.com'
		unless $opts{source_control};
	push @lines, automation_block_lines(
		without => [grep {$opts{$_}} qw/shuttle vault locker/]);
	return join("\n", @lines);
}

# A state builder: write one environment file with a nested genesis block.
# The harness's own write_env_file renders a scalar or a flat list and would
# leave a reference's address behind for anything deeper, which is the gap
# this works around, and it should render a nested hash under
# genesis.pipeline.* to any depth.  Once it does, this goes.
#
# Called with no lines it writes the environment back to saying nothing
# about the pipeline, which is the state the harness built it in, so a
# subtest that starts here is not reading what another subtest wrote.
#
# Each write carries a count of its own beside the environment, because a
# reset to what the file already holds gives the commit no delta otherwise.
my $writes = 0;

sub write_nested_env {
	my ($name, @lines) = @_;
	commit_on_control($h, files => {
		"$name.yml" => join("\n",
			'---', 'kit:', '  name:    dev', '  version: latest',
			'genesis:', "  env: $name",
			(@lines ? ('  pipeline:', @lines) : ()), ''),
		'.env-count' => sprintf("%d\n", ++$writes),
	});
}

# source_control joined the three under T385: its auth and identity were
# required only once the block was there, so a pipeline without it loaded.
subtest 'four blocks are required under an automation' => sub {
	plan tests => 5;

	write_nested_env('qa');

	lives_ok {load_with($h, automated_pipeline_block())} 'the complete section validates';
	for my $block (qw/shuttle vault locker source_control/) {
		throws_ok {load_with($h, automated_pipeline_block($block => 1))}
			qr/pipeline: missing required key $block/,
			"$block is required under an automated provider";
	}
};

subtest 'and every one of them is optional under manual' => sub {
	plan tests => 2;

	write_nested_env('qa');

	lives_ok {load_with($h, join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: manual',
		'  source_control:', '    repository: team/bosh'))}
		'a manual pipeline needs none of the three';
	lives_ok {load_with($h, join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: manual'))}
		'nor a source_control block, its keys derived from the clone';
};

subtest 'the shuttle backend refuses a directory' => sub {
	plan tests => 3;

	write_nested_env('qa');

	lives_ok {load_with($h, automated_pipeline_block())} 's3 validates';
	throws_ok {load_with($h, automated_pipeline_block() =~ s/backend: s3/backend: file/r)}
		qr/pipeline\.shuttle\.backend: unknown value/,
		'file is refused, because a directory cannot trigger across pipelines';
	throws_ok {load_with($h, automated_pipeline_block() =~ s/backend: s3/backend: gcs/r)}
		qr/pipeline\.shuttle\.backend: unknown value: gcs/,
		'gcs is refused, s3 being the one backend';
};

subtest 'notifications are optional and overridable per environment' => sub {
	plan tests => 4;

	write_nested_env('qa');

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

	write_nested_env('qa');

	lives_ok {load_with($h, automated_pipeline_block(provider_extra => [
		'    public: true', '    tagged: true',
		'    task:', '      image: genesiscommunity/concourse',
		'      version: latest']))}
		'the four Concourse keys validate under Concourse';
	throws_ok {load_with($h, automated_pipeline_block() =~ s/team: main/team: main\n    public: maybe/r)}
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

subtest 'the removed keys are refused by name, with what replaced them' => sub {
	# T404: each was refused as an unknown key, which said nothing of what to
	# write instead; a retired key is now refused as no longer read, naming
	# its replacement.
	my @retired = (
		[['    locks:', '      bosh_upgrade: x'], 'locks', qr/mandatory.*pipeline\.locker/],
		[['    status_signal: x'],       'status_signal',       qr/pipeline\.shuttle/],
		[['    signal_prefix: x'],       'signal_prefix',       qr/pipeline\.shuttle/],
		[['    redeploy: x'],            'redeploy',            qr/redeploy_cron/],
		[['    redeploy_cron_start: x'], 'redeploy_cron_start', qr/redeploy_cron/],
		[['    redeploy_cron_stop: x'],  'redeploy_cron_stop',  qr/redeploy_cron/],
		[['    required_files: [x]'],    'required_files',      qr/genesis\.pipeline\.track_additional_files/],
	);
	plan tests => 2 * @retired + 1;

	# And a key nobody declared is not offered a retired one in its list.
	write_nested_env('qa', '    bogus: x');
	my $listed = '';
	eval {load_with($h, automated_pipeline_block()); 1}
		or $listed = Genesis::Term::decolorize("$@") =~ s/\s+/ /gr;
	unlike($listed, qr/expected one of[^.]*\b(?:locks|required_files|status_signal)\b/,
		'an unknown key is offered no retired key among those expected');

	for my $case (@retired) {
		my ($lines, $key, $replacement) = @$case;
		write_nested_env('qa', @$lines);
		my $said = '';
		eval {load_with($h, automated_pipeline_block()); 1}
			or $said = Genesis::Term::decolorize("$@") =~ s/\s+/ /gr;
		like($said, qr/genesis\.pipeline\.$key: is no longer read/, "$key is refused as retired");
		like($said, $replacement, 'naming what replaced it');
	}
	write_nested_env('qa');
};

subtest "the rc builds' ci block is refused, naming pipeline" => sub {
	plan tests => 2;

	# T404: the block an rc build wrote was refused as an unknown key.
	write_nested_env('qa');
	my $said = '';
	eval {load_with($h, automated_pipeline_block() . "\nci:\n  enabled: true"); 1}
		or $said = Genesis::Term::decolorize("$@") =~ s/\s+/ /gr;
	like($said, qr/\bci: is no longer read/, 'ci is refused as retired');
	like($said, qr/\bpipeline\b.*genesis config --unset ci/, 'naming pipeline, and the command that removes it');
};

# T388: an empty name loaded and reached the compiler, which refused it under
# a key v3 does not have, 'pipeline.metadata.name'.
subtest 'an empty pipeline name is refused at load' => sub {
	plan tests => 3;

	write_nested_env('qa');

	throws_ok {load_with($h, automated_pipeline_block() . "\n  name: ''")}
		qr/pipeline\.name.*must not be empty.*deployment_type/s,
		'an empty name is refused by name, with the default it would leave out';
	lives_ok {load_with($h, automated_pipeline_block() . "\n  name: my-bosh")}
		'a name passes';
	lives_ok {load_with($h, automated_pipeline_block())}
		'and no name at all takes the deployment_type';
};

# T389: the override file was read only by the compile's spruce merge, so a
# file that is no YAML map was found after the pipeline was built.
subtest 'an override file that is no YAML map is refused at load' => sub {
	plan tests => 5;

	write_nested_env('qa');
	my $file = $h->a . '/.genesis/pipeline-overrides-concourse.yml';

	helper::put_file($file, "---\njobs: [unclosed\n");
	throws_ok {load_with($h, automated_pipeline_block())}
		qr/pipeline-overrides-concourse\.yml.*not valid YAML/s,
		'a file that does not parse is refused, naming it';

	helper::put_file($file, "---\n- a\n- b\n");
	throws_ok {load_with($h, automated_pipeline_block())}
		qr/pipeline-overrides-concourse\.yml.*must be a map/s,
		'a file that is not a map is refused, naming it';

	helper::put_file($h->a . '/.genesis/pipeline-overrides-concourse-pipeline.yml', "--- 42\n");
	helper::put_file($file, "---\njobs: []\n");
	throws_ok {load_with($h, automated_pipeline_block())}
		qr/pipeline-overrides-concourse-pipeline\.yml.*must be a map/s,
		'and so is a per-file override under the multi-file form';
	unlink $h->a . '/.genesis/pipeline-overrides-concourse-pipeline.yml';

	lives_ok {load_with($h, automated_pipeline_block())}
		'a map passes';

	helper::put_file($h->a . '/.genesis/pipeline-overrides-github-actions.yml', "- x\n");
	lives_ok {load_with($h, automated_pipeline_block())}
		'and another provider\'s override is not this pipeline\'s to judge';
	unlink $file, $h->a . '/.genesis/pipeline-overrides-github-actions.yml';
};

done_testing;
