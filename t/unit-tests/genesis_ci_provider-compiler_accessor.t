#!perl
# Proves T343: a provider owns its compiler, the compiler holds the
# provider rather than a copy of its settings, and a provider with
# nothing to emit answers with nothing rather than leaving an abstract
# method unimplemented.
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
use Genesis::CI::Provider;
use Genesis::CI::Compiler;
use Genesis::CI::Compiler::AST;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# An assertion helper, beside the test that uses it.  Every row wants an
# AST that is only well formed enough to be held, because none of them
# asks the compiler to emit anything.
sub bare_ast {
	return Genesis::CI::Compiler::AST->new(
		metadata     => {name => 'test', version => '2.0', source => 'modern'},
		branches     => {control => 'main', target_prefix => 'target/'},
		integrations => {source_control => {provider => 'github',
		                                    repository => 'org/repo'}},
		targets      => {},
		workflows    => {},
	);
}

subtest 'a Concourse provider hands out its own compiler' => sub {
	plan tests => 3;

	my $ast      = bare_ast();
	my $provider = Genesis::CI::Provider->new(type => 'concourse', target => 'ci');
	my $compiler = $provider->compiler(ast => $ast);

	isa_ok $compiler, 'Genesis::CI::ProviderCompiler::Concourse',
		'the compiler is the one the registry names for this type';
	isa_ok $compiler, 'Genesis::CI::ProviderCompiler',
		'and it is a compiler rather than a kind of provider';
	is $compiler->ast, $ast, 'it was built over the AST it was given';
};

subtest 'the compiler holds the provider rather than a copy of it' => sub {
	plan tests => 4;

	my $provider = Genesis::CI::Provider->new(type => 'concourse', target => 'ci');
	my $compiler = $provider->compiler(ast => bare_ast());

	is $compiler->provider, $provider,
		'the compiler answers with the provider object itself';
	is $compiler->provider->team, 'main',
		'and reads the team through it';

	# The declaration comes through the held provider now, rather than
	# through a forwarder that resolved the CLI class all over again.
	ok exists $compiler->provider_options_defaults->{team},
		'the options chain reads the declaration through that provider';

	# The assertion the whole row exists for.  A copy taken at
	# construction passes every check above and drifts from here on, and
	# that drift is what let two classes each carry a DEFAULT_TEAM.
	$provider->team('platform');
	is $compiler->provider->team, 'platform',
		'a change on the provider is visible without the compiler being rebuilt';
};

subtest 'a provider with nothing to emit answers with nothing' => sub {
	plan tests => 3;

	my $manual = Genesis::CI::Provider->new(type => 'manual');
	is $manual->compiler(ast => bare_ast()), undef,
		'manual has no compiler and says so';

	# github-actions is the same shape for a different reason.  Its
	# compiler class was removed in March 2026 and arrives back with the
	# provider itself, so until then it answers as manual does.
	my $gha = Genesis::CI::Provider->new(type => 'github-actions',
		repo => 'org/repo');
	is $gha->compiler(ast => bare_ast()), undef,
		'a provider whose compiler has not landed answers the same way';

	# A caller that needs one rather than merely asking for one gets the
	# refusal Genesis::CI kept, through the registry that carries it.
	throws_ok {$gha->compiler(ast => bare_ast(), required => 1)}
		qr/knows\s+the\s+'github-actions'\s+provider\s+but\s+has\s+no\s+compiler/s,
		'and a caller that requires one is told why there is none';
};

subtest 'the compile hands back the provider beside its compiler' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], provider => 'concourse', vault => 0);
	my $top = load_with($h,
		automated_config('concourse', 'target: ci', 'team: platform'));

	my $result = Genesis::CI::Compiler->new(top => $top)
		->compile(provider => 'concourse');

	isa_ok $result->{provider}, 'Genesis::CI::Provider::Concourse',
		"the result's provider";
	isa_ok $result->{compiler}, 'Genesis::CI::ProviderCompiler::Concourse',
		"the result's compiler";

	# The assertion the row exists for.  A compile that built the
	# provider and then resolved the compiler class itself returns both
	# objects and passes every check above, with the two unrelated.
	is $result->{compiler}->provider, $result->{provider},
		'and the compiler holds the provider the result carries';

	# The provider is built out of the block the operator wrote, not out
	# of defaults, which is what lets a repository declare a floor for
	# the prerequisites check to enforce.
	is $result->{provider}->team, 'platform',
		'the provider reads the configured block';
};

done_testing;
