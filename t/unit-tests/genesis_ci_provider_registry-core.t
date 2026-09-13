#!perl
# Proves T43 and T16: the provider enum is built from the one registry, so
# the schema and the lookups cannot spell a provider two ways, and the
# provider type defaults to manual, so enabling the section with no
# provider key is a manual pipeline rather than no pipeline.
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
use_ok 'Genesis::CI::Compiler::PipelineProvider';
use_ok 'Genesis::CI::Provider';
use_ok 'Genesis::CI::Compiler';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

sub config_yaml {
	my ($body) = @_;
	return join("\n", '---', 'deployment_type: bosh', 'version: "3"',
		'creator_version: 3.2.0', $body, '');
}

# The harness clones copy A from a bare repository at a filesystem path, so
# the origin URL carries no GitHub owner/repo pair for the source-control
# block to derive one from, and a row that enables a pipeline names the
# repository itself.
sub enabled_pipeline {
	my (@extra) = @_;
	return join("\n", 'pipeline:', '  enabled: true', @extra,
		'  source_control:', '    repository: genesis/bosh-deployments');
}

sub load_with {
	my ($body) = @_;
	commit_on_control($h, files => {'.genesis/config' => config_yaml($body)});
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	$top->config;
	return $top;
}

subtest 'the two spellings cannot drift' => sub {
	plan tests => 4;

	my @known = Genesis::CI::Compiler::PipelineProvider->known_providers;
	is_deeply [@known], [qw/concourse github-actions manual/],
		'the registry holds the three types';

	# The schema's enum is the registry's list, not a literal beside it.
	my $top    = load_with(enabled_pipeline());
	my $schema = $top->_repo_config_schema;
	is_deeply $schema->{pipeline}{schema}{provider}{schema}{type}{values},
		[@known],
		'the enum is the registry list';

	throws_ok {load_with("pipeline:\n  enabled: true\n  provider:\n    type: gha")}
		qr/pipeline\.provider\.type: unknown value/,
		'gha is refused, because no registry entry spells it that way';

	# An automated provider has to clone and commit unattended, so the row
	# that names one carries the credential and the committer identity the
	# source-control block requires of it.
	lives_ok {
		load_with(join("\n",
			enabled_pipeline('  provider:', '    type: github-actions'),
			'    auth:', '      vault: secret/ci/git',
			'    identity:', '      name: Genesis', '      email: ci@example.com'))
	} 'github-actions validates, because the registry spells it that way';
};

subtest 'one resolver answers for every caller' => sub {
	plan tests => 5;

	my $info = Genesis::CI::Compiler::PipelineProvider->provider_info('concourse');
	is $info->{class}, 'Genesis::CI::Concourse',
		'the compiler class comes from the registry';
	is $info->{cli_class}, 'Genesis::CI::Provider::Concourse',
		'the CLI class comes from the same entry';

	is Genesis::CI::Provider->provider_class('manual'),
		'Genesis::CI::Provider::Manual',
		'manual resolves to its CLI class and has no compiler class';

	# The compiler's class resolution has two refusals rather than one, so a
	# type the registry holds is never reported as one it does not.
	throws_ok {
		Genesis::CI::Compiler->_resolve_provider_class('github-actions')
	} qr/knows\s+the\s+'github-actions'\s+provider\s+but\s+has\s+no\s+compiler/s,
		'a known type with no compiler class is told it has no compiler';

	throws_ok {
		Genesis::CI::Compiler->_resolve_provider_class('jenkins')
	} qr/Valid\s+types:\s+concourse,\s+github-actions,\s+manual/s,
		'a type the registry does not hold gets the valid-types list';
};

subtest 'the provider type defaults to manual' => sub {
	plan tests => 3;

	my $top = load_with(enabled_pipeline());
	is $top->config->get('pipeline.provider.type'), 'manual',
		'an absent provider block resolves to a manual pipeline';
	ok $top->config->get('pipeline.enabled'),
		'the gate stays true with no provider key';

	my $off = load_with("pipeline:\n  enabled: false");
	ok !$off->config->get('pipeline.enabled'),
		'a disabled section is still a disabled section';
};

done_testing;
