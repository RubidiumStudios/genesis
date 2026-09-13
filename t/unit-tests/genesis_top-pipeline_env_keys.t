#!perl
# Proves T20, T21, T24, T26, T29, and T32: the per-environment keys are
# declared and read from the merged environment, the manual gate and the
# redeploy cron take their settled forms, the tracked-files key is renamed
# with its path semantics unchanged, the dependency source is a list with
# no opt-out, the BOSH-config key is per environment only, and a declared
# dependency cycle is accepted at load because the apply refuses it.
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
use_ok 'Genesis::Env';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 1, vault => 0);

# An assert helper: put a genesis.pipeline block on one environment and
# load, returning the Top or dying with what the load said.
sub load_env_with {
	my ($pipeline, %opts) = @_;
	write_env_file($h, $opts{env} // 'qa', pipeline => $pipeline);
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	$top->config;
	return $top;
}

subtest 'the manual gate is a declared boolean' => sub {
	plan tests => 3;

	lives_ok {load_env_with({manual => 1})} 'a boolean validates';
	throws_ok {load_env_with({manual => 'sometimes'})}
		qr/genesis\.pipeline\.manual: expected a boolean/,
		'a non-boolean is refused by name';

	my $top = load_env_with({});
	is $top->_merged_env_params('qa')->{genesis}{pipeline}{manual}, undef,
		'an absent key leaves the deploy job auto-triggering';
};

subtest 'the redeploy keys are declared in their settled form' => sub {
	plan tests => 5;

	lives_ok {load_env_with({redeploy_cron => '0 3 * * *'})}
		'a crontab string validates';
	lives_ok {load_env_with({redeploy_cron => ['0 3 * * *', '0 15 * * *']})}
		'a list of them validates';

	for my $gone (qw/redeploy redeploy_cron_start redeploy_cron_stop/) {
		throws_ok {load_env_with({$gone => '0 3 * * *'})}
			qr/genesis\.pipeline\.$gone: unknown configuration key/,
			"$gone is refused by name";
	}
};

subtest 'the tracked-files key is renamed and behaves as before' => sub {
	plan tests => 5;

	throws_ok {load_env_with({required_files => ['ops/<env>.yml']})}
		qr/genesis\.pipeline\.required_files: unknown configuration key/,
		'the old name is refused by name';
	lives_ok {load_env_with({track_additional_files => ['ops/<env>.yml']})}
		'the new name is declared in its place';

	# A glob answers with the files that are there, so the row lays the
	# ones it expects down first.
	helper::put_file($h->a.'/ops/notes.md', "notes\n");

	# The path semantics are the ones the old name had.
	my @resolved = Genesis::Env->_resolve_track_additional_files(
		['ops/<env>.yml', 'ops/*.md'], 'qa', $h->a);
	is_deeply [grep {m{^ops/qa\.yml$}} @resolved], ['ops/qa.yml'],
		'<env> substitutes the environment name and not the slug';
	ok scalar(grep {m{^ops/.*\.md$}} @resolved),
		'a glob expands as it did';

	throws_ok {Genesis::Env->_resolve_track_additional_files(
			['../outside.yml'], 'qa', $h->a)}
		qr/escapes the deployment root/,
		'a parent-relative path is still refused';
};

subtest 'the dependency source is a list and has no opt-out' => sub {
	plan tests => 4;

	lives_ok {load_env_with({track_dependencies => ['vault', 'prod/cf']})}
		'types here and <env>/<type> elsewhere both validate';
	throws_ok {load_env_with({track_dependencies => ['prod/cf/extra']})}
		qr/genesis\.pipeline\.track_dependencies.*not a deployment type/s,
		'a malformed entry is refused by name';
	# The harness's writer renders a list entry with sprintf, which would
	# write a reference's address into the file as a string, so the row
	# that needs a nested entry writes the environment file itself.
	throws_ok {
		commit_on_control($h, files => {'qa.yml' => join("\n",
			'---', 'kit:', '  name:    dev', '  version: latest',
			'genesis:', '  env: qa', '  pipeline:',
			'    track_dependencies:', '      - cf: prod', '')});
		Genesis::Top->new($h->a, no_vault => 1)->config;
	} qr/genesis\.pipeline\.track_dependencies/,
		'an entry that is not a string is refused by name';
	throws_ok {load_env_with({skip_dependencies => 1})}
		qr/genesis\.pipeline\.skip_dependencies: unknown configuration key/,
		'there is no key offering to opt out';
};

subtest 'the BOSH-config key is per environment only' => sub {
	plan tests => 2;

	lives_ok {load_env_with({track_bosh_configs => ['cloud', 'runtime']})}
		'the per-environment placement is declared';

	# The row rewrites the repository's own configuration, and the rows
	# below load the same repository, so what was there is put back.
	my $config = slurp($h->a.'/.genesis/config');
	throws_ok {
		commit_on_control($h, files => {'.genesis/config' => join("\n",
			'---', 'deployment_type: bosh', 'version: "3"',
			'creator_version: 3.2.0', 'pipeline:', '  enabled: true',
			'  track_bosh_configs: true', '')});
		Genesis::Top->new($h->a, no_vault => 1)->config;
	} qr/pipeline\.track_bosh_configs: unknown configuration key/,
		'the repository-wide fallback went with the multi-file layout';
	commit_on_control($h, files => {'.genesis/config' => $config});
};

subtest 'a declared dependency cycle is accepted at load' => sub {
	plan tests => 1;

	write_env_file($h, 'qa',  pipeline => {track_dependencies => ['prod/bosh']});
	write_env_file($h, 'prod', pipeline => {track_dependencies => ['qa/bosh']});
	lives_ok {Genesis::Top->new($h->a, no_vault => 1)->config}
		'the load accepts it, because the cycle needs the rendered manifest';
};

done_testing;
