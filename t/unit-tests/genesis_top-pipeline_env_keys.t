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

subtest 'a mapping written where a list belongs is refused' => sub {
	plan tests => 1;

	# The key declares envsplit, so without a check on the block as it was
	# written the validator splits the mapping as though it came from the
	# environment and leaves the address of a reference behind.
	#
	# The row rewrites an environment file, and the rows below load the same
	# repository, so what was there is put back.
	my $env_file = slurp($h->a.'/qa.yml');
	throws_ok {
		commit_on_control($h, files => {'qa.yml' => join("\n",
			'---', 'kit:', '  name:    dev', '  version: latest',
			'genesis:', '  env: qa', '  pipeline:',
			'    track_dependencies:', '      cf: prod', '')});
		Genesis::Top->new($h->a, no_vault => 1)->config;
	} qr/genesis\.pipeline\.track_dependencies: expected a list of strings/,
		'the mapping is refused by name rather than stringified';
	commit_on_control($h, files => {'qa.yml' => $env_file});
};

subtest 'a refusal with no bullets in it is still a refusal' => sub {
	plan tests => 1;

	# Every refusal the validator raises today is bulleted, so the fallback
	# is provoked by making it fail some other way entirely.
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	no warnings qw/redefine once/;
	local *Genesis::Config::validate = sub {die "the validator fell over\n"};
	throws_ok {$top->_validate_env_pipeline_block('qa', {manual => 1})}
		qr/the validator fell over/,
		'a failure it cannot pick apart is reported rather than swallowed';
};

subtest 'an environment file that will not parse is refused' => sub {
	plan tests => 1;

	throws_ok {
		commit_on_control($h, files => {'broken.yml' =>
			"genesis:\n  pipeline:\n    manual: [unclosed\n"});
		Genesis::Top->new($h->a, no_vault => 1)->config;
	} qr/An environment file could not be read as YAML.*broken\.yml/s,
		'a file nobody can read is a key nobody can see';

	# Out again, because the rows below load the same repository.
	commit_on_control($h, files => {'broken.yml' => undef});
};

subtest 'the read is merged and never leaf-only' => sub {
	plan tests => 2;

	# Two tokens, so the environment has a site file above it, and the key
	# is written only there.  A leaf-only read finds it absent and answers
	# wrongly with no error at all, which is what D79 is about.
	my $g = make_harness(envs => [], pipeline => 1, vault => 0);
	write_env_file($g, 'us', site => 'us', pipeline => {manual => 'sometimes'});
	write_env_file($g, 'us-east');

	my $top = Genesis::Top->new($g->a, no_vault => 1);
	is $top->_merged_env_params('us-east')->{genesis}{pipeline}{manual},
		'sometimes', 'the leaf reads a key only its site file declares';
	throws_ok {$top->_validate_env_pipeline_block('us-east',
			$top->_merged_env_params('us-east')->{genesis}{pipeline})}
		qr/environment us-east.*genesis\.pipeline\.manual: expected a boolean/s,
		'and the refusal names the leaf that never wrote the key';
};

subtest 'the reader promotes a bare string the way the validator does' => sub {
	plan tests => 1;

	my $env = bless {name => 'qa'}, 'Genesis::Env';
	no warnings qw/redefine once/;
	local *Genesis::Env::lookup = sub {'ops/one.yml'};

	pushd $h->a;
	my @paths = $env->track_additional_files;
	popd;

	is_deeply \@paths, ['ops/one.yml'],
		'one path declared as a string still joins the propagation set';
};

# The refusal an operator reads is built out of the one the declarative
# validator raised, so what survives that rewrite is worth its own rows.
subtest 'a caught refusal is folded into readable bullets' => sub {
	plan tests => 3;

	my $mark = Genesis::Term::decolorize(Genesis::Term::csprintf(
		Genesis::Term::bullet('', inline => 1, indent => 0)));
	my $caught = join('',
		"Configuration validation failed:\n",
		"${mark}pipeline.require_pr: expected a boolean, got pipeline\n",
		"${mark}pipeline.manual: expected a boolean",
		" at lib/Genesis/Config.pm line 412.\n",
		"\tGenesis::Config::validate called at lib/Genesis/Top.pm line 27\n");

	my @errors = Genesis::Top::_first_errors($caught);

	is scalar(@errors), 2, 'one error comes back per bullet';
	is $errors[0],
		'genesis.pipeline.require_pr: expected a boolean, got pipeline',
		'only the key the line opens with is requalified';
	is $errors[1], 'genesis.pipeline.manual: expected a boolean',
		'and a file and line trailing the error is cut away with its trace';
};

subtest 'a caught message is cut at the location that ends it' => sub {
	plan tests => 6;

	# The one cut, which _first_errors makes to each bullet and which the
	# provider refusals make to whatever they caught.
	is Genesis::Top::_without_backtrace(
		"Can't locate Nope.pm in \@INC (\@INC entries checked: lib)"
		." at lib/Genesis/Top.pm line 2128.\n"
		."\tGenesis::Top::_provider_options_schema() called at x line 9\n"),
		"Can't locate Nope.pm in \@INC (\@INC entries checked: lib)",
		'the message stands without the line it was raised on';

	is Genesis::Top::_without_backtrace("the provider fell over\n"),
		'the provider fell over',
		'a message with nothing behind it is left as it is';

	is Genesis::Top::_without_backtrace("one\ntwo\n"), 'one two',
		'and what is left is folded onto a line';

	is Genesis::Top::_without_backtrace(undef), '',
		'an undefined text answers an empty string';

	# A provider pointing an operator at a file and a line of their own is
	# an ordinary thing for a validator to do, and the cut is for the
	# location that ends a message rather than for every one in it.
	is Genesis::Top::_without_backtrace(
		"target is required; see the setting at config.yml line 12"
		." and fix it\n"),
		'target is required; see the setting at config.yml line 12'
		.' and fix it',
		'a location the message goes on talking past is left alone';

	is Genesis::Top::_without_backtrace(
		"target is required; see the setting at config.yml line 12"
		." and fix it\n at lib/Genesis/CI/Provider/Pair.pm line 7.\n"
		."\tGenesis::CI::Provider::Pair::validate_config() called at x line 3\n"),
		'target is required; see the setting at config.yml line 12'
		.' and fix it',
		'and the trailing location behind it goes with its frames';
};

# The rows above hand the cut a caught text nobody wrapped, and the caught
# text a refusal really carries has been through Genesis's own wrap, which
# indents every line it folds and every frame behind them.
subtest 'a wrapped refusal is cut at any terminal width' => sub {
	plan tests => 3;

	my $mark = Genesis::Term::decolorize(Genesis::Term::csprintf(
		Genesis::Term::bullet('', inline => 1, indent => 0)));
	my $raw = join('',
		"Configuration validation failed:\n",
		"${mark}pipeline.require_pr: expected a boolean, got pipeline\n",
		"${mark}pipeline.manual: expected a boolean",
		" at lib/Genesis/Config.pm line 412.\n",
		"\tGenesis::Config::validate called at lib/Genesis/Top.pm line 27\n");

	# Eighty is the ordinary terminal, sixty folds the bullets, and
	# forty-four is narrow enough to break the location across a line.
	for my $width (80, 60, 44) {
		my @errors = Genesis::Top::_first_errors(
			Genesis::Term::wrap($raw, $width, '[FATAL] '));
		is_deeply \@errors, [
			'genesis.pipeline.require_pr: expected a boolean, got pipeline',
			'genesis.pipeline.manual: expected a boolean',
		], "the bullets come back with no location and no frame at $width";
	}
};

subtest 'a refusal with no bullets carries only its first line' => sub {
	plan tests => 2;

	# A row above this one leaves qa carrying a block the schema refuses, so
	# the load is given a block it accepts before the validator is replaced.
	my $top = load_env_with({manual => 'false', require_pr => 'false'});

	no warnings qw/redefine once/;
	local *Genesis::Config::validate = sub {
		die "the validator gave up\nand said a great deal more\nbesides\n";
	};

	my $refusal = '';
	eval {$top->_validate_env_pipeline_block('qa', {manual => 'false'}); 1}
		or $refusal = $@;

	like $refusal, qr/the validator gave up/,
		'the first line stands in where there is no bullet to read';
	unlike $refusal, qr/besides/,
		'and the rest of the caught text does not travel with it';
};

done_testing;
