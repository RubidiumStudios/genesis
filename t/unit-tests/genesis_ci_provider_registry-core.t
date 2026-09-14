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

# The harness clones copy A from a bare repository at a filesystem path, so
# the origin URL carries no GitHub owner/repo pair for the source-control
# block to derive one from, and a row that enables a pipeline names the
# repository itself.
sub enabled_pipeline {
	my (@extra) = @_;
	return join("\n", 'pipeline:', '  enabled: true', @extra,
		'  source_control:', '    repository: genesis/bosh-deployments');
}

subtest 'the two spellings cannot drift' => sub {
	plan tests => 6;

	my @known = Genesis::CI::Compiler::PipelineProvider->known_providers;
	is_deeply [@known], [qw/concourse github-actions manual/],
		'the registry holds the three types';

	# The schema's enum is the registry's list, not a literal beside it.
	my $top    = load_with($h, enabled_pipeline());
	my $schema = $top->_repo_config_schema;
	is_deeply $schema->{pipeline}{schema}{provider}{schema}{type}{values},
		[@known],
		'the enum is the registry list';

	throws_ok {load_with($h, "pipeline:\n  enabled: true\n  provider:\n    type: gha")}
		qr/pipeline\.provider\.type: unknown value/,
		'gha is refused, because no registry entry spells it that way';

	# An automated provider has to clone and commit unattended, so the row
	# that names one carries the credential and the committer identity the
	# source-control block requires of it, and the three blocks the work
	# cannot be done without either.
	lives_ok {
		load_with($h, join("\n",
			enabled_pipeline('  provider:', '    type: github-actions'),
			'    auth:', '      vault: secret/ci/git',
			'    identity:', '      name: Genesis', '      email: ci@example.com',
			automation_block_lines()))
	} 'github-actions validates, because the registry spells it that way';

	# Two lists that agree today agree by construction only if one is built
	# out of the other, so the row puts a type into the registry and reads
	# the enum the next load builds.  The name sorts after every registered
	# type, so the rows below that read the valid-types list in order are
	# left as they were.
	Genesis::CI::Compiler::PipelineProvider->register_provider('zeppelin',
		{cli_class => 'Genesis::CI::Provider::Manual'});

	my $after = load_with($h, enabled_pipeline())->_repo_config_schema
		->{pipeline}{schema}{provider}{schema}{type}{values};
	ok scalar(grep {$_ eq 'zeppelin'} @$after),
		'a type registered here is in the enum the next load built';
	is_deeply $after,
		[Genesis::CI::Compiler::PipelineProvider->known_providers],
		'and the enum is still the whole registry and nothing else';
};

subtest 'one resolver answers for every caller' => sub {
	plan tests => 6;

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

	# The list alone would be satisfied by a refusal that lost the type on
	# its way out, so the row reads the type it asked about as well.
	throws_ok {
		Genesis::CI::Compiler->_resolve_provider_class('jenkins')
	} qr/Unknown\s+CI\s+provider\s+type\s+'jenkins'/s,
		'a type the registry does not hold is named in the refusal';
	throws_ok {
		Genesis::CI::Compiler->_resolve_provider_class('jenkins')
	} qr/Valid\s+types:\s+concourse,\s+github-actions,\s+manual/s,
		'and the refusal carries the types it does hold';
};

subtest 'the provider type defaults to manual' => sub {
	plan tests => 3;

	my $top = load_with($h, enabled_pipeline());
	is $top->config->get('pipeline.provider.type'), 'manual',
		'an absent provider block resolves to a manual pipeline';
	ok $top->config->get('pipeline.enabled'),
		'the gate stays true with no provider key';

	my $off = load_with($h, "pipeline:\n  enabled: false");
	ok !$off->config->get('pipeline.enabled'),
		'a disabled section is still a disabled section';
};

subtest 'the registry refuses a bad entry rather than taking it' => sub {
	plan tests => 4;

	# Read before the two refusals rather than written out, because the row
	# below is about what a refusal leaves behind and not about which types
	# happen to be registered by the time it runs.
	my @before = Genesis::CI::Compiler::PipelineProvider->known_providers;

	# Without a name the entry would land under the empty string, where
	# nothing could ever look it up again.
	throws_ok {
		Genesis::CI::Compiler::PipelineProvider->register_provider(undef, {
			cli_class => 'Genesis::CI::Provider::Manual',
			cli_file  => 'Genesis/CI/Provider/Manual.pm',
		})
	} qr/must\s+be\s+registered\s+under\s+a\s+name/s,
		'an entry with no name is refused';

	# A name already registered is refused rather than replaced.  Replacing
	# the concourse entry for the rest of the process would leave the enum
	# saying one thing and the class lookup doing another, which is exactly
	# the drift the one registry exists to prevent.
	throws_ok {
		Genesis::CI::Compiler::PipelineProvider->register_provider('concourse', {
			cli_class => 'Genesis::CI::Provider::Manual',
			cli_file  => 'Genesis/CI/Provider/Manual.pm',
		})
	} qr/concourse.*is\s+already\s+registered/s,
		'a name the registry already holds is refused';

	# Every type has a CLI-side class, so an entry with none resolves to
	# nothing and behaves like manual instead of saying it is broken.  The
	# compiler-side class is a different matter: manual has none by design.
	throws_ok {
		Genesis::CI::Compiler::PipelineProvider->register_provider('nocli', {
			class => 'Genesis::CI::Compiler::Providers::NoCli',
			file  => 'Genesis/CI/Compiler/Providers/NoCli.pm',
		})
	} qr/must\s+be\s+registered\s+with\s+a\s+cli_class/s,
		'an entry with no CLI class is refused';

	is_deeply [Genesis::CI::Compiler::PipelineProvider->known_providers],
		[@before],
		'and neither refusal left anything behind in the registry';
};

done_testing;
