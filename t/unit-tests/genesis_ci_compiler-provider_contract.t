#!perl
# The three things a compiler asks a CI provider for.  A registry lookup
# answers an entry a caller may write into without reaching the registry
# itself, the provider declares the keys an operator may write under
# pipeline.provider, and the options a deploy resolves fall back through
# the legacy configuration where the provider declares no key of its own.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use Genesis;
use Test::More;
use Test::Output;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';

use_ok 'Genesis::CI::Compiler::AST';
use_ok 'Genesis::CI::ProviderCompiler';
use_ok 'Genesis::CI::ProviderRegistry';

# The Concourse compiler loads by the name it declares, because the
# package it declares and the path it sits at agree now.
use_ok 'Genesis::CI::ProviderCompiler::Concourse';
use_ok 'Genesis::CI::Compiler';

subtest 'a registry lookup answers a copy of the entry' => sub {
	plan tests => 2;

	# A caller that writes into what it was given must not be able to
	# rewrite the registry for the rest of the process, because the next
	# file in the same run would then resolve the real provider to
	# whatever the writer put there.
	my $info = Genesis::CI::ProviderRegistry->provider_info('concourse');
	is $info->{cli_class}, 'Genesis::CI::Provider::Concourse',
		'the entry answers the registered CLI class';

	$info->{cli_class} = 'Genesis::CI::Provider::Fixture';
	my $again = Genesis::CI::ProviderRegistry->provider_info('concourse');
	is $again->{cli_class}, 'Genesis::CI::Provider::Concourse',
		'writing into the answer leaves the registry as it was';
};

subtest 'a registration keeps a copy of what it was handed' => sub {
	plan tests => 2;

	# The same guard from the other side.  A caller that goes on writing
	# into the hash it registered would rewrite the registry just as surely
	# as one writing into an answer, and the entry it rewrote would be the
	# one every later lookup reads.
	my %entry = (cli_class => 'Genesis::CI::Provider::Concourse');
	Genesis::CI::ProviderRegistry->register_provider('fixture-copy', \%entry);

	$entry{cli_class} = 'Genesis::CI::Provider::Rewritten';
	is Genesis::CI::ProviderRegistry->provider_info('fixture-copy')->{cli_class},
		'Genesis::CI::Provider::Concourse',
		'writing into the registered hash leaves the registry as it was';

	# Registered under its own name, so the real entries are untouched by
	# it and every row after this one still sees them.
	is Genesis::CI::ProviderRegistry->provider_info('concourse')->{cli_class},
		'Genesis::CI::Provider::Concourse',
		'and the real concourse entry still answers its own CLI class';

	# The registry is fixed at compile time and has no way to take an entry
	# out again, so the fixture stays for the rest of this process.  Nothing
	# in this file enumerates providers, and a row that came to count them
	# would have to know it is here.
};

subtest 'the task block declares privileged beside image and version' => sub {
	plan tests => 2;

	# ASTBuilder and PipelineDescriptor both read
	# pipeline.provider.task.privileged, so the nested schema has to
	# declare it or the load refuses the key by name.
	#
	# Asked of the provider that declares it, since the compiler side no
	# longer answers for a declaration it does not own.
	require Genesis::CI::Provider;
	my $schema = Genesis::CI::Provider->provider_class('concourse')
		->provider_options_schema();
	ok exists $schema->{task}{schema}{privileged},
		'privileged is declared in the nested task schema';
	is $schema->{task}{schema}{privileged}{type}, 'array',
		'and it is an array, which is the shape both readers expect';
};

subtest 'pipeline.public still decides the visibility' => sub {
	plan tests => 2;

	# provider_option('expose') answers undef, because the schema spells
	# the key public rather than expose, so the legacy pipeline.public
	# fallback below it is the one that decides.  A fake fly on the PATH
	# records the subcommand it was handed, which keeps the row off the
	# network and off any real Concourse.
	my $dir = tempdir(CLEANUP => 1);
	mkpath("$dir/bin");
	my $log = "$dir/fly.log";
	open my $fly, '>', "$dir/bin/fly" or die $!;
	print $fly "#!/bin/sh\necho \"\$@\" >> \"$log\"\nexit 0\n";
	close $fly;
	chmod 0755, "$dir/bin/fly";

	my $ast = Genesis::CI::Compiler::AST->new(
		metadata     => {name => 'test', version => '2.0', source => 'modern'},
		branches     => {control => 'main', target_prefix => 'target/'},
		integrations => {
			source_control => {provider => 'github', repository => 'org/repo'},
		},
		targets      => {},
		workflows    => {},
	);

	# Built through the provider, because the compiler reads the team and
	# the declared keys off the provider it holds and a compiler built
	# with none has nothing to read them from.
	require Genesis::CI::Provider;

	my $flown = sub {
		my ($public) = @_;
		unlink $log;
		my $provider = Genesis::CI::Provider->new(
			type => 'concourse', target => 'ci');
		my $p = $provider->compiler(ast => $ast);
		$p->{config} = {
			pipeline => {
				name => 'test',
				(defined $public ? (public => $public) : ()),
			},
		};
		local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
		output_from {$p->deploy(target => 'ci', yes => 1)};
		return -f $log ? do {local (@ARGV, $/) = ($log); <>} : '';
	};

	like $flown->(1), qr/expose-pipeline/,
		'pipeline.public exposes the pipeline when nothing above it says otherwise';
	like $flown->(undef), qr/hide-pipeline/,
		'and the built-in default hides it';
};

subtest 'the provider block is not checked a second time' => sub {
	plan tests => 3;

	require Genesis::CI::Compiler::Validator;
	ok !Genesis::CI::Compiler::Validator->can('_validate_provider_section'),
		'the validator keeps no copy of the provider check';

	# D28 validated the block at load, so what reaches the compiler has
	# already met the provider's own rules and cannot fail them here.  The
	# base used to read the CLI class's declaration through a forwarder of
	# its own, and under D108 a compiler asks the provider it holds, so no
	# file of the compiler family itself names the declaration.  The sweep
	# reads that family and not the provider compilers under it, where
	# Concourse reads the declaration through the provider it holds, which
	# is what a compiler is meant to do.
	#
	# Comment lines are skipped, because the base says in prose where the
	# forwarder went and why, and saying so is not reading anything.
	my @swept = glob('lib/Genesis/CI/Compiler/*.pm lib/Genesis/CI/ProviderCompiler.pm');

	# The sweep is satisfied by an empty answer, and a glob that matches
	# nothing gives that answer, so a family that moved out from under
	# this row would read as a clean sweep rather than as a broken one.
	# What the sweep read is asserted first, so that never happens
	# quietly.
	ok scalar(@swept), 'the sweep read the compiler side at all';

	my @found = grep {
		grep {!m/^\s*#/ && m/provider_options_schema/}
			split(/\n/, slurp($_) // '')
	} @swept;
	is_deeply [@found], [],
		'and no file on the compiler side reads the fragment';
};

subtest 'the compile normalizes through the provider its own compiler' => sub {
	plan tests => 2;

	# A deploy normalizes through the compiler it holds, so the Concourse
	# remap of the CLI's pause onto the schema's pause_after_set applies
	# there.  A compile that asked the base instead would leave the CLI
	# spelling standing, and the two paths would answer differently about
	# the same flag an operator wrote once.
	my $cli = {'ci-pause' => 1, 'ci-target' => 'prod'};

	my $deploy = Genesis::CI::ProviderRegistry->compiler_class('concourse')
		->normalize_provider_opts($cli);
	my $compile = Genesis::CI::Compiler->_normalized_provider_opts(
		'concourse', $cli);

	is_deeply $compile, $deploy,
		'the compile and the deploy normalize a flag the same way';
	is $compile->{pause_after_set}, 1,
		"and the provider's own remap is what both of them ran";
};

done_testing;
