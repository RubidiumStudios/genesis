#!perl
# Proves T36 and T38: the provider block declares the type that decides it
# and the block is checked against the fragment that type's provider
# declares, a key the fragment declares validates with its type, required
# flag and default, a key no fragment declares is refused by name, a
# provider class that omits its fragment fails at load, and the manual
# provider declares an empty fragment so a stray provider key beside it is
# refused with no exception.
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
use_ok 'Genesis::CI::ProviderCompiler';
use_ok 'Genesis::CI::Provider';
use_ok 'Genesis::CI::ProviderRegistry';

# The fragment this file compares the merged schema against.  The load
# path loads it on its own, but reading it here through a class the file
# never pulled in would report a merge that failed as a missing method.
require Genesis::CI::ProviderCompiler::Concourse;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

sub concourse {
	my (@lines) = @_;
	return automated_config('concourse', 'target: ci', @lines);
}

# Proves that the declaration and the check belong to one class, so the
# base-class default of D105 has something to validate against, and that
# the manual provider is in the map like any other.
subtest 'one class carries the fragment and the check' => sub {
	plan tests => 5;

	# Named here as well as at the top of this file, because the row below
	# compares the compiler class's answer with the CLI class's.
	require Genesis::CI::ProviderCompiler::Concourse;

	# The resolved code references are compared rather than asking whether
	# the class can the method at all.  The base declares the method as an
	# abstract one, so every subclass can it, and a class that declared
	# nothing whatsoever would satisfy a row that only asked that.
	for my $type (qw/concourse github-actions manual/) {
		my $class = Genesis::CI::Provider->provider_class($type);
		isnt $class->can('provider_options_schema'),
			Genesis::CI::Provider->can('provider_options_schema'),
			"the $type provider declares its own keys";
	}

	is_deeply Genesis::CI::Provider::Manual->provider_options_schema, {},
		'and the manual provider declares an empty fragment rather than none';

	# The compiler side reads the same declaration rather than a copy.
	is_deeply(Genesis::CI::ProviderCompiler::Concourse->provider_options_schema,
		Genesis::CI::Provider::Concourse->provider_options_schema,
		'the compiler class answers with what the CLI class declared');
};

subtest "the configured provider's fragment is what the block declares" => sub {
	plan tests => 5;

	my $top      = load_with($h, concourse());
	my $fragment = Genesis::CI::ProviderCompiler::Concourse->provider_options_schema;

	# The block names the module rather than listing keys, so a reader
	# asking about one of the block's keys is answered by the provider the
	# written type selects.  These are the readers that ask: the type
	# coercion of a write, and the unknown-key check of a removal.
	ok $top->config->schema_has('pipeline.provider.target'),
		'a key the fragment declares is one the schema answers for';
	is $top->config->_schema_for_key('pipeline.provider.team')->{default},
		$fragment->{team}{default},
		'with the default the fragment gave it';
	ok length($top->config->_schema_for_key('pipeline.provider.target')
			->{description}),
		'and its description, which genesis config renders as help';

	is $top->config->get('pipeline.provider.team'), $fragment->{team}{default},
		'the default resolves at load';

	# Validation only walks into a hash that is present, so a nested block
	# resolves its own defaults only because the block itself defaults to
	# an empty hash.
	is $top->config->get('pipeline.provider.task.image'),
		$fragment->{task}{schema}{image}{default},
		"and a nested block's defaults resolve with it";
};

subtest 'a key no fragment declares is refused by name' => sub {
	plan tests => 2;

	throws_ok {load_with($h, concourse('nonesuch: 1'))}
		qr/pipeline\.provider\.nonesuch: unknown configuration key/,
		'an undeclared provider key is refused by name';
	throws_ok {load_with($h, concourse('team: [a, b]'))}
		qr/pipeline\.provider\.team: expected a string/,
		"and a declared key's type is enforced";
};

subtest 'a provider that omits its fragment fails at load' => sub {
	plan tests => 1;

	# A provider whose CLI class declares no fragment, registered for this
	# test alone.  The omission has to be on the CLI side, because that is
	# where the declaration lives and where the base raises on its absence.
	put_file('t/tmp/lib/Genesis/CI/Provider/Mute.pm', <<'MUTECLI');
package Genesis::CI::Provider::Mute;
use base 'Genesis::CI::Provider';
1;
MUTECLI
	put_file('t/tmp/lib/Genesis/CI/Compiler/Providers/Mute.pm', <<'MUTE');
package Genesis::CI::Compiler::Providers::Mute;
use parent 'Genesis::CI::ProviderCompiler';
sub provider_type {'mute'}
1;
MUTE
	local @INC = ('t/tmp/lib', @INC);
	Genesis::CI::ProviderRegistry->register_provider('mute', {
		class     => 'Genesis::CI::Compiler::Providers::Mute',
		file      => 'Genesis/CI/Compiler/Providers/Mute.pm',
		cli_class => 'Genesis::CI::Provider::Mute',
		cli_file  => 'Genesis/CI/Provider/Mute.pm',
	});

	# The refusal is wrapped to the terminal on its way out, so every space
	# in it is read as a run: which of them the wrap falls on depends on
	# how deeply the raise is nested.
	throws_ok {load_with($h, "pipeline:\n  enabled: true\n  provider:\n    type: mute")}
		qr/must\s+implement\s+provider_options_schema/,
		'the omission is a bug at load and not a discovery at run time';
};

subtest 'the manual provider admits no provider key' => sub {
	plan tests => 5;

	for my $key (qw/target url team insecure public/) {
		throws_ok {load_with($h, join("\n", 'pipeline:', '  enabled: true',
			'  provider:', '    type: manual', "    $key: x"))}
			qr/pipeline\.provider\.$key: unknown configuration key/,
			"$key is refused beside a manual provider";
	}
};

subtest 'a required fragment key is refused by name when it is absent' => sub {
	plan tests => 2;

	# A provider whose fragment declares one key it cannot work without,
	# registered for this test alone.
	put_file('t/tmp/lib/Genesis/CI/Provider/Terse.pm', <<'TERSECLI');
package Genesis::CI::Provider::Terse;
use base 'Genesis::CI::Provider';
# The base's new is the factory's, and it refuses to build a subclass, so
# a CLI-side fixture the load path constructs brings its own.
sub new {my ($c, %cfg) = @_; bless {%cfg}, $c}
sub provider_options_schema {
	return {
		token => {
			type        => 'string',
			required    => 1,
			description => 'The one key this provider cannot run without'
		},
	};
}
# The capability declaration is mandatory beside the fragment, and this
# file is about the fragment, so the fixture claims every ability and none
# of what it writes is gated away.
sub capabilities {
	return {map {($_ => 1)} qw/cross_pipeline_events deployment_locks
		multi_file_output optional_git_triggers per_commit_runs
		scheduled_jobs/};
}
1;
TERSECLI
	put_file('t/tmp/lib/Genesis/CI/Compiler/Providers/Terse.pm', <<'TERSE');
package Genesis::CI::Compiler::Providers::Terse;
use parent 'Genesis::CI::ProviderCompiler';
sub provider_type {'terse'}
1;
TERSE
	local @INC = ('t/tmp/lib', @INC);
	Genesis::CI::ProviderRegistry->register_provider('terse', {
		class     => 'Genesis::CI::Compiler::Providers::Terse',
		file      => 'Genesis/CI/Compiler/Providers/Terse.pm',
		cli_class => 'Genesis::CI::Provider::Terse',
		cli_file  => 'Genesis/CI/Provider/Terse.pm',
	});

	throws_ok {load_with($h, automated_config('terse'))}
		qr/pipeline\.provider:\s+missing\s+required\s+key\s+token/s,
		"the fragment's required flag is enforced, and names the key";
	lives_ok {load_with($h, automated_config('terse', 'token: abc'))}
		'and the same configuration loads once the key is written';
};

# Proves that the base class default validates the block against the
# provider's own fragment, that a provider overriding it still gets that
# pass, and that the two are one call rather than two phases.
subtest 'the base default validates against the declaration' => sub {
	plan tests => 8;

	# A provider that writes no validation at all, so everything refused
	# below it is refused by the default the base gives every provider.
	put_file('t/tmp/lib/Genesis/CI/Provider/Plain.pm', <<'PLAIN');
package Genesis::CI::Provider::Plain;
use base 'Genesis::CI::Provider';
sub provider_options_schema {
	return {
		token => {type => 'string',  required => 1, description => 'Needed'},
		loud  => {type => 'boolean', default  => Genesis::Config::FALSE(), description => 'Optional'},
	};
}
# Plain claims nothing, which is the ordinary case these rows are about.
sub capabilities {
	return {map {($_ => 0)} qw/cross_pipeline_events deployment_locks
		multi_file_output optional_git_triggers per_commit_runs
		scheduled_jobs/};
}
1;
PLAIN
	# And one that has a rule a declaration cannot state, which it adds on
	# top of the pass it calls up for.
	put_file('t/tmp/lib/Genesis/CI/Provider/Pair.pm', <<'PAIR');
package Genesis::CI::Provider::Pair;
use base 'Genesis::CI::Provider';
sub provider_options_schema {
	return {
		target => {type => 'string', description => 'One of the pair'},
		url    => {type => 'string', description => 'The other of the pair'},
		# The key an ability offers is declared by the provider that
		# claims the ability, and this one claims every one of them.
		output_layout => {
			type        => 'enum',
			values      => [qw/single multiple/],
			default     => 'single',
			description => 'How many files the provider emits'
		},
	};
}
sub validate_config {
	my ($class, $config, $path, $discriminator) = @_;
	my @errors = $class->SUPER::validate_config($config, $path, $discriminator);
	push @errors, "$path: 'target' or 'url' is required for the Pair provider"
		unless $config->get("$path.target") || $config->get("$path.url");
	return @errors;
}
# Pair claims every ability, so a key an ability offers is declared in
# the fragment above and read back through the same walk as every other
# key of the block.
sub capabilities {
	return {map {($_ => 1)} qw/cross_pipeline_events deployment_locks
		multi_file_output optional_git_triggers per_commit_runs
		scheduled_jobs/};
}
1;
PAIR
	# The compiler half of each fixture, which the registry names for a
	# provider that can be compiled.  Both halves of what a provider
	# declares, the fragment and the capabilities, sit on the CLI class
	# above, so there is nothing for these two to say beyond their type.
	put_file('t/tmp/lib/Genesis/CI/Compiler/Providers/Plain.pm', <<'PLAINC');
package Genesis::CI::Compiler::Providers::Plain;
use parent 'Genesis::CI::ProviderCompiler';
sub provider_type {'plain'}
1;
PLAINC
	put_file('t/tmp/lib/Genesis/CI/Compiler/Providers/Pair.pm', <<'PAIRC');
package Genesis::CI::Compiler::Providers::Pair;
use parent 'Genesis::CI::ProviderCompiler';
sub provider_type {'pair'}
1;
PAIRC
	local @INC = ('t/tmp/lib', @INC);
	for my $type (qw/plain pair/) {
		(my $pkg = ucfirst $type) =~ s/\W//g;
		Genesis::CI::ProviderRegistry->register_provider($type, {
			class     => "Genesis::CI::Compiler::Providers::$pkg",
			file      => "Genesis/CI/Compiler/Providers/$pkg.pm",
			cli_class => "Genesis::CI::Provider::$pkg",
			cli_file  => "Genesis/CI/Provider/$pkg.pm",
		});
	}

	throws_ok {load_with($h, automated_config('plain'))}
		qr/pipeline\.provider: missing required key .*token/,
		"the fragment's required flag is enforced by the default alone";
	throws_ok {load_with($h, automated_config('plain', 'nonesuch: 1'))}
		qr/pipeline\.provider\.nonesuch: unknown configuration key/,
		'and so is an undeclared key, with no validation written anywhere';

	my $top = load_with($h, automated_config('plain', 'token: abc'));
	is $top->config->get('pipeline.provider.loud'), Genesis::Config::FALSE(),
		"and the fragment's default lands where every reader looks for it";

	# The refusal is wrapped to the terminal on its way out, and this one
	# is long enough to break, so the spaces in it are read as runs.
	throws_ok {load_with($h, automated_config('pair'))}
		qr/'target' or 'url' is required\s+for\s+the\s+Pair\s+provider/s,
		'a provider with a cross-field rule states it and is heard';
	throws_ok {load_with($h, automated_config('pair', 'nonesuch: 1'))}
		qr/pipeline\.provider\.nonesuch: unknown configuration key/,
		'and it still gets the generic pass it called up for';

	# A provider that can emit several files declares the layout key
	# itself, so the block admits what the operator writes there and fills
	# the fragment's default where nobody wrote anything.
	$top = load_with($h, automated_config('pair',
		'target: ci', 'output_layout: multiple'));
	is $top->config->get('pipeline.provider.output_layout'), 'multiple',
		'the layout key is admitted by the provider that declares it';
	$top = load_with($h, automated_config('pair', 'target: ci'));
	is $top->config->get('pipeline.provider.output_layout'), 'single',
		'and D67 fills its default where nobody wrote one';

	# The default asked for directly, rather than through the walk that
	# reaches it, because a class method is what D105 asks a provider for
	# and a row that only ever loads a configuration cannot tell the two
	# apart.  The configuration holds the block and nothing else.
	my $cfg = Genesis::Config->new();
	$cfg->set('pipeline.provider.type', 'plain');
	my @refusals = map {Genesis::Term::decolorize($_)}
		Genesis::CI::Provider::Plain->validate_config(
			$cfg, 'pipeline.provider', 'type');
	like join("\n", @refusals), qr/pipeline\.provider: missing required key .*token/,
		'and the default answers for the block when it is called outright';
};

# Both provider-load refusals interpolate what the failed require said, and
# under Carp::Always that is the message plus the frames behind it.
subtest 'a provider that will not load is refused without its stack' => sub {
	plan tests => 2;

	# The file is loaded by now, so marking its entry as one that failed is
	# what makes the next require of it fail the way a broken provider
	# would.  One probe rather than two: the class that owns the block is
	# the class that answers for the abilities as well, so the dispatch is
	# where a provider that will not load is met, and the capability gates
	# behind it ask a class the dispatch has already brought in.
	local $INC{'Genesis/CI/Provider/Concourse.pm'} = undef;
	my $refusal = '';
	eval {load_with($h, concourse()); 1} or $refusal = $@;
	(my $flat = Genesis::Term::decolorize($refusal)) =~ s/\s+/ /g;

	like $flat, qr/Failed to load CI provider 'concourse'/,
		'the dispatch names the provider whose file would not load';

	# Carp::Always appends bail's own frames to the refusal as well, and
	# those start at bail's raise site in Genesis.pm, so what bail was
	# handed is everything between the heading and that.  Reading the
	# whole refusal would find a file and a line either way.
	my ($said) = $flat =~
		m{provider 'concourse': (.*?)(?: at \S*Genesis\.pm line \d+|$)};
	$said //= '';
	$said =~ s/^\s+|\s+$//g;
	unlike $said, qr/ at \S+ line \d+/,
		'and it hands the message over with no location in it';
};

# A provider's own check runs inside the load, so what it does when it goes
# wrong is the load's problem rather than the operator's.
subtest 'a provider that goes wrong is still a configuration refusal' => sub {
	plan tests => 5;

	put_file('t/tmp/lib/Genesis/CI/Provider/Boom.pm', <<'BOOM');
package Genesis::CI::Provider::Boom;
sub new {my ($c, %cfg) = @_; bless {%cfg}, $c}
sub validate_config {die "the provider fell over\n"}
1;
BOOM
	# Quiet is the one of the pair whose load runs to the end, so it is
	# the one that reaches the capability gates and has to answer them.
	put_file('t/tmp/lib/Genesis/CI/Provider/Quiet.pm', <<'QUIET');
package Genesis::CI::Provider::Quiet;
sub new {my ($c, %cfg) = @_; bless {%cfg}, $c}
sub validate_config {return (undef)}
sub capabilities {
	return {map {($_ => 0)} qw/cross_pipeline_events deployment_locks
		multi_file_output optional_git_triggers per_commit_runs
		scheduled_jobs/};
}
1;
QUIET
	local @INC = ('t/tmp/lib', @INC);
	Genesis::CI::ProviderRegistry->register_provider('boom', {
		cli_class => 'Genesis::CI::Provider::Boom',
		cli_file  => 'Genesis/CI/Provider/Boom.pm',
	});
	Genesis::CI::ProviderRegistry->register_provider('quiet', {
		cli_class => 'Genesis::CI::Provider::Quiet',
		cli_file  => 'Genesis/CI/Provider/Quiet.pm',
	});

	my $refusal = '';
	eval {load_with($h, automated_config('boom')); 1} or $refusal = $@;
	like $refusal, qr/Configuration validation failed/,
		'a provider that dies is reported as the refusal it is';
	like $refusal, qr/pipeline\.provider: the provider fell over/,
		'and the operator is told what the provider said, under its key';
	unlike $refusal, qr/Provider::Boom::validate_config/,
		'without the frames Carp::Always folded in behind it';

	# Under D105 the provider's rules are not a phase of their own, so
	# what a provider says is gathered with every other error under the
	# one sentence a configuration refusal carries, and the wrapper that
	# announced the provider's half separately is gone.
	unlike $refusal, qr/Invalid configuration for the/,
		'and with no second heading of its own in front of it';

	lives_ok {load_with($h, automated_config('quiet'))}
		'a provider that answers with a bare undef reports no error at all';
};

done_testing;
