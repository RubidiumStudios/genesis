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
# Test::Exit installs the hook that makes an exit catchable in a BEGIN
# block, and the exit it has to catch is the one Genesis::bail spends, so
# it comes before anything that compiles Genesis.
use Test::Exit;
use helper;
use Harness::Propagation;
use Test::More;
use Test::Exception;
use Test::Output;

use Genesis;
use Genesis::Exit qw/CONFIG/;
provide_rc();
use_ok 'Genesis::Top';
use_ok 'Genesis::CI::ProviderRegistry';
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

# Only this subtest enumerates the registry, and it does so twice: it
# compares known_providers with the three types written out, and
# automated_providers with the two of those that are not manual.  Both
# rows are one type short the moment a fourth is registered, so this
# subtest has to run before the one that registers zeppelin.
#
# The two subtests after it are not bound by that order.  The refusal
# subtest builds the list it expects out of the registry, as its own
# comment says, and the type-accessor subtest names concourse and manual
# only to construct providers with, which a fourth type leaves alone.
#
# Order matters at all because the registry is process-wide and
# register_provider has no counterpart that takes an entry out again, so
# a type registered anywhere above would still be there when this ran.
subtest 'the registry is consulted by both families and owned by neither' => sub {
	plan tests => 6;

	# The three the registry answers for every caller, asserted on the
	# module itself rather than through whatever happens to inherit it.
	is_deeply [Genesis::CI::ProviderRegistry->known_providers],
		[qw/concourse github-actions manual/],
		'the registry holds the three types';
	is Genesis::CI::ProviderRegistry->provider_info('concourse')->{cli_class},
		'Genesis::CI::Provider::Concourse',
		'an entry names the CLI class';
	is_deeply [Genesis::CI::ProviderRegistry->automated_providers],
		[qw/concourse github-actions/],
		'and the automated list is every type but manual';

	is Genesis::CI::ProviderRegistry->provider_class('concourse'),
		'Genesis::CI::Provider::Concourse',
		'resolving a provider class answers the CLI class';
	is Genesis::CI::ProviderRegistry->compiler_class('concourse'),
		'Genesis::CI::ProviderCompiler::Concourse',
		'resolving a compiler class answers the compiling class';

	# A provider that loads or calls a compiler is the inversion this rules
	# out.  A %INC check would answer whatever the rows above it happened to
	# load first, so the row reads the source instead, and no load order can
	# defeat that, because nothing in the provider family, and nothing in
	# the registry both families consult, loads a compiler module or calls
	# one.
	#
	# What the registry writes down is a different matter.  Its map says
	# which class compiles for which type, because being that map is the
	# whole of its job, and a class named in a hash is a value rather than
	# a dependency.  The dependency is a load or a call, so that is what
	# the row looks for.
	my @naming;
	for my $file ('lib/Genesis/CI/ProviderRegistry.pm',
	              'lib/Genesis/CI/Provider.pm',
	              glob('lib/Genesis/CI/Provider/*.pm')) {
		open my $fh, '<', $file or die "cannot read $file: $!\n";
		while (my $line = <$fh>) {
			push @naming, "$file:$."
				if $line =~ /\b(?:use|require)\s+Genesis::CI::(?:Compiler|ProviderCompiler)\b/
				|| $line =~ /Genesis::CI::(?:Compiler|ProviderCompiler)\b[\w:]*\s*->/;
		}
		close $fh;
	}
	is_deeply(\@naming, [],
		'nothing in the provider family or the registry loads or calls a compiler module')
		or diag(join("\n", map {"  $_"} @naming));
};

subtest 'the registry carries the refusal Genesis::CI kept' => sub {
	plan tests => 3;

	# b98d60f1 kept this refusal deliberately, because emitting a
	# pipeline and validating a block are different questions and a
	# provider may answer the second while having nothing to answer the
	# first with.  It outlives the file it was written in.
	throws_ok {Genesis::CI::ProviderRegistry->compiler_class('github-actions')}
		qr/knows\s+the\s+'github-actions'\s+provider\s+but\s+has\s+no\s+compiler/s,
		'a known type with no compiler class is told it has no compiler';

	throws_ok {Genesis::CI::ProviderRegistry->compiler_class('jenkins')}
		qr/Unknown\s+CI\s+provider\s+type\s+'jenkins'/s,
		'a type the registry does not hold is named in the refusal';

	# The list is built out of the registry rather than written out, so
	# the row proves the refusal carries the types the registry holds
	# and no others, wherever a type another row registers happens to
	# sort.  The separator tolerates a wrap, because the refusal is
	# wrapped to the terminal width before anything reads it.
	my $types = join(',\s+', map {quotemeta}
		Genesis::CI::ProviderRegistry->known_providers);
	throws_ok {Genesis::CI::ProviderRegistry->compiler_class('jenkins')}
		qr/Valid\s+types:\s+$types(?!,)/s,
		'and the refusal carries every type the registry holds';
};

subtest 'a provider carries the type it was registered under' => sub {
	plan tests => 3;

	# config answers a hash, and Perl randomises a hash's order once per
	# process, so a type read by indexing into that list is right for
	# manual, whose hash holds one pair, and a coin toss for anything
	# else.  The type is set where it is known, which is the constructor
	# the registry resolves for.
	is Genesis::CI::Provider->new(type => 'concourse', target => 'ci')->type,
		'concourse', 'a Concourse provider knows it is concourse';
	is Genesis::CI::Provider->new(type => 'manual')->type,
		'manual', 'and a manual one knows it is manual';
	is Genesis::CI::Provider->new()->type,
		'manual', 'and the default carries the type it defaulted to';
};

subtest 'the two spellings cannot drift' => sub {
	plan tests => 6;

	my @known = Genesis::CI::ProviderRegistry->known_providers;
	is_deeply [@known], [qw/concourse github-actions manual/],
		'the registry holds the three types';

	# The map is the registry's list, not a literal beside it.
	my $top    = load_with($h, enabled_pipeline());
	my $schema = $top->_repo_config_schema;
	is_deeply [sort keys %{$schema->{pipeline}{schema}{provider}{modules}}],
		[@known],
		'the map is the registry list';

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
	# the map the next load builds.  The registry is process-wide and
	# nothing takes an entry out of it again, so every row below this one
	# reads the registry for what it expects rather than naming the three
	# types the process started with.
	Genesis::CI::ProviderRegistry->register_provider('zeppelin',
		{cli_class => 'Genesis::CI::Provider::Manual',
		 cli_file  => 'Genesis/CI/Provider/Manual.pm'});

	my $after = [sort keys %{load_with($h, enabled_pipeline())
		->_repo_config_schema->{pipeline}{schema}{provider}{modules}}];
	ok scalar(grep {$_ eq 'zeppelin'} @$after),
		'a type registered here is in the map the next load built';
	is_deeply $after,
		[Genesis::CI::ProviderRegistry->known_providers],
		'and the map is still the whole registry and nothing else';
};

subtest 'one resolver answers for every caller' => sub {
	plan tests => 6;

	my $info = Genesis::CI::ProviderRegistry->provider_info('concourse');
	is $info->{class}, 'Genesis::CI::ProviderCompiler::Concourse',
		'the compiler class comes from the registry';
	is $info->{cli_class}, 'Genesis::CI::Provider::Concourse',
		'the CLI class comes from the same entry';

	is Genesis::CI::Provider->provider_class('manual'),
		'Genesis::CI::Provider::Manual',
		'manual resolves to its CLI class and has no compiler class';

	# The compiler's class resolution has two refusals rather than one, so a
	# type the registry holds is never reported as one it does not.
	throws_ok {
		Genesis::CI::ProviderRegistry->compiler_class('github-actions')
	} qr/knows\s+the\s+'github-actions'\s+provider\s+but\s+has\s+no\s+compiler/s,
		'a known type with no compiler class is told it has no compiler';

	# The list alone would be satisfied by a refusal that lost the type on
	# its way out, so the row reads the type it asked about as well.
	throws_ok {
		Genesis::CI::ProviderRegistry->compiler_class('jenkins')
	} qr/Unknown\s+CI\s+provider\s+type\s+'jenkins'/s,
		'a type the registry does not hold is named in the refusal';
	# The list is built out of the registry rather than written out, so the
	# row proves the refusal carries the types the registry holds and no
	# others, and holds wherever a type another row registers happens to
	# sort.  The separator tolerates a wrap, because the refusal is wrapped
	# to the terminal width before anything reads it, and the lookahead
	# rejects a list that runs on past the one the registry answers.
	my $types = join(',\s+', map {quotemeta}
		Genesis::CI::ProviderRegistry->known_providers);
	throws_ok {
		Genesis::CI::ProviderRegistry->compiler_class('jenkins')
	} qr/Valid\s+types:\s+$types(?!,)/s,
		'and the refusal carries every type the registry holds and no others';
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
	my @before = Genesis::CI::ProviderRegistry->known_providers;

	# Without a name the entry would land under the empty string, where
	# nothing could ever look it up again.
	throws_ok {
		Genesis::CI::ProviderRegistry->register_provider(undef, {
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
		Genesis::CI::ProviderRegistry->register_provider('concourse', {
			cli_class => 'Genesis::CI::Provider::Manual',
			cli_file  => 'Genesis/CI/Provider/Manual.pm',
		})
	} qr/concourse.*is\s+already\s+registered/s,
		'a name the registry already holds is refused';

	# Every type has a CLI-side class, so an entry with none resolves to
	# nothing and behaves like manual instead of saying it is broken.  The
	# compiler-side class is a different matter: manual has none by design.
	throws_ok {
		Genesis::CI::ProviderRegistry->register_provider('nocli', {
			class => 'Genesis::CI::ProviderCompiler::NoCli',
			file  => 'Genesis/CI/ProviderCompiler/NoCli.pm',
		})
	} qr/must\s+be\s+registered\s+with\s+a\s+cli_class/s,
		'an entry with no CLI class is refused';

	is_deeply [Genesis::CI::ProviderRegistry->known_providers],
		[@before],
		'and neither refusal left anything behind in the registry';
};

subtest 'a provider whose module will not load is a refusal an operator can act on' => sub {
	plan tests => 2;

	# The registry derives the file from the package name and requires it,
	# so a registration naming a package with no file behind it is a
	# repository asking for a provider this Genesis cannot load.  That is
	# something the operator can put right, so the refusal takes the
	# configuration code rather than a bare one, and it carries the sentence
	# the load raised without the frames standing behind it.
	#
	# It is registered here, after every row that reads the registry as it
	# stands, because a registration is for the life of the process.
	Genesis::CI::ProviderRegistry->register_provider('nowhere', {
		cli_class => 'Genesis::CI::Provider::Nowhere',
	});

	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my ($code, $said);
	$said = output_from {
		$code = exit_code {
			Genesis::CI::ProviderRegistry->provider_class('nowhere');
		};
	};

	is $code, CONFIG,
		'a provider module that will not load refuses at the configuration code';
	unlike $said, qr/\bat\s+\S+\s+line\s+\d+/,
		'and the refusal says what failed without the frames behind it';
};

done_testing;
