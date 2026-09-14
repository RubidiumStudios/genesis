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
use Test::More;
use Test::Output;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';

use_ok 'Genesis::CI::Compiler::AST';
use_ok 'Genesis::CI::Compiler::PipelineProvider';

# The provider classes load by file path rather than by package name,
# because the package a provider file declares is not its path.
eval {require 'Genesis/CI/Compiler/Providers/Concourse.pm'};  ## no critic
ok !$@, 'loaded the Concourse provider' or diag $@;

subtest 'a registry lookup answers a copy of the entry' => sub {
	plan tests => 2;

	# A caller that writes into what it was given must not be able to
	# rewrite the registry for the rest of the process, because the next
	# file in the same run would then resolve the real provider to
	# whatever the writer put there.
	my $info = Genesis::CI::Compiler::PipelineProvider->provider_info('concourse');
	is $info->{cli_class}, 'Genesis::CI::Provider::Concourse',
		'the entry answers the registered CLI class';

	$info->{cli_class} = 'Genesis::CI::Provider::Fixture';
	my $again = Genesis::CI::Compiler::PipelineProvider->provider_info('concourse');
	is $again->{cli_class}, 'Genesis::CI::Provider::Concourse',
		'writing into the answer leaves the registry as it was';
};

subtest 'the task block declares privileged beside image and version' => sub {
	plan tests => 2;

	# ASTBuilder and PipelineDescriptor both read
	# pipeline.provider.task.privileged, so the nested schema has to
	# declare it or the load refuses the key by name.
	my $schema = Genesis::CI::Concourse->provider_options_schema();
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

	my $flown = sub {
		my ($public) = @_;
		unlink $log;
		my $p = Genesis::CI::Concourse->new(
			ast => $ast, top => undef, provider_opts => {});
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

done_testing;
