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

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

sub config_yaml {
	my ($body) = @_;
	return join("\n", '---', 'deployment_type: bosh', 'version: "3"',
		'creator_version: 3.2.0', $body, '');
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
	my $top    = load_with("pipeline:\n  enabled: true");
	my $schema = $top->_repo_config_schema;
	is_deeply $schema->{pipeline}{schema}{provider}{schema}{type}{values},
		[@known],
		'the enum is the registry list';

	throws_ok {load_with("pipeline:\n  enabled: true\n  provider:\n    type: gha")}
		qr/pipeline\.provider\.type: unknown value/,
		'gha is refused, because no registry entry spells it that way';

	lives_ok {
		load_with("pipeline:\n  enabled: true\n  provider:\n    type: github-actions")
	} 'github-actions validates, because the registry spells it that way';
};

subtest 'one resolver answers for every caller' => sub {
	plan tests => 3;

	my $info = Genesis::CI::Compiler::PipelineProvider->provider_info('concourse');
	is $info->{class}, 'Genesis::CI::Concourse',
		'the compiler class comes from the registry';
	is $info->{cli_class}, 'Genesis::CI::Provider::Concourse',
		'the CLI class comes from the same entry';

	is Genesis::CI::Provider->provider_class('manual'),
		'Genesis::CI::Provider::Manual',
		'manual resolves to its CLI class and has no compiler class';
};

subtest 'the provider type defaults to manual' => sub {
	plan tests => 3;

	my $top = load_with("pipeline:\n  enabled: true");
	is $top->config->get('pipeline.provider.type'), 'manual',
		'an absent provider block resolves to a manual pipeline';
	ok $top->config->get('pipeline.enabled'),
		'the gate stays true with no provider key';

	my $off = load_with("pipeline:\n  enabled: false");
	ok !$off->config->get('pipeline.enabled'),
		'a disabled section is still a disabled section';
};

done_testing;
