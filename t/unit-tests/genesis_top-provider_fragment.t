#!perl
# Proves T36 and T38: the generic pipeline schema merges the configured
# provider's fragment at load, a key the fragment declares validates with
# its type, required flag and default, a key no fragment declares is
# refused by name, a provider class that omits its fragment fails at load,
# and the manual provider declares no fragment so a stray provider key
# beside it is refused with no exception.
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

# The fragment this file compares the merged schema against.  The load
# path loads it on its own, but reading it here through a class the file
# never pulled in would report a merge that failed as a missing method.
require Genesis::CI::Compiler::Providers::Concourse;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

sub load_with {
	my ($body) = @_;
	commit_on_control($h, files => {'.genesis/config' => join("\n",
		'---', 'deployment_type: bosh', 'version: "3"',
		'creator_version: 3.2.0', $body, '')});
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	$top->config;
	return $top;
}

# The harness clones copy A from a bare repository at a filesystem path, so
# the source-control block names the repository rather than deriving it,
# and an automated provider is the case where the clone credential and the
# committer identity are required beside it.  Every row that names a
# provider other than manual goes through here, so a row adds provider
# lines rather than a whole configuration of its own.
sub automated_config {
	my ($type, @lines) = @_;
	return join("\n", 'pipeline:', '  enabled: true',
		'  source_control:',
		'    repository: genesis/bosh-deployments',
		'    auth:',
		'      type: ssh',
		'      vault: secret/ci/git',
		'    identity:',
		'      name: Genesis CI',
		'      email: ci@genesis.example.com',
		'  provider:', "    type: $type",
		(map {"    $_"} @lines),
		# The shuttle, the vault, and the locker are required of an
		# automation for the same reason the credential is, so every row
		# that names one carries them too.
		'  shuttle:', '    backend: s3', '    bucket: pipes',
		'  vault:', '    url: https://vault.example.com',
		'  locker:', '    url: https://locker.example.com');
}

sub concourse {
	my (@lines) = @_;
	return automated_config('concourse', 'target: ci', @lines);
}

subtest "the configured provider's fragment is merged at load" => sub {
	plan tests => 5;

	my $top      = load_with(concourse());
	my $provider = $top->_repo_config_schema->{pipeline}{schema}{provider}{schema};
	my $fragment = Genesis::CI::Concourse->provider_options_schema;

	ok exists $provider->{target},
		"a key the fragment declares is in the merged schema";
	is $provider->{team}{default}, $fragment->{team}{default},
		'with the default the fragment gave it';
	ok length($provider->{target}{description}),
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

	throws_ok {load_with(concourse('nonesuch: 1'))}
		qr/pipeline\.provider\.nonesuch: unknown configuration key/,
		'an undeclared provider key is refused by name';
	throws_ok {load_with(concourse('team: [a, b]'))}
		qr/pipeline\.provider\.team: expected a string/,
		"and a declared key's type is enforced";
};

subtest 'a provider that omits its fragment fails at load' => sub {
	plan tests => 1;

	# A provider class with no fragment, registered for this test alone.
	put_file('t/tmp/lib/Genesis/CI/Compiler/Providers/Mute.pm', <<'MUTE');
package Genesis::CI::Compiler::Providers::Mute;
use parent 'Genesis::CI::Compiler::PipelineProvider';
sub provider_type {'mute'}
1;
MUTE
	local @INC = ('t/tmp/lib', @INC);
	Genesis::CI::Compiler::PipelineProvider->register_provider('mute', {
		class     => 'Genesis::CI::Compiler::Providers::Mute',
		file      => 'Genesis/CI/Compiler/Providers/Mute.pm',
		cli_class => 'Genesis::CI::Provider::Manual',
		cli_file  => 'Genesis/CI/Provider/Manual.pm',
	});

	throws_ok {load_with("pipeline:\n  enabled: true\n  provider:\n    type: mute")}
		qr/must implement\s+provider_options_schema/,
		'the omission is a bug at load and not a discovery at run time';
};

subtest 'the manual provider admits no provider key' => sub {
	plan tests => 5;

	for my $key (qw/target url team insecure public/) {
		throws_ok {load_with(join("\n", 'pipeline:', '  enabled: true',
			'  provider:', '    type: manual', "    $key: x"))}
			qr/pipeline\.provider\.$key: unknown configuration key/,
			"$key is refused beside a manual provider";
	}
};

subtest 'a required fragment key is refused by name when it is absent' => sub {
	plan tests => 2;

	# A provider class whose fragment declares one key it cannot work
	# without, registered for this test alone.
	put_file('t/tmp/lib/Genesis/CI/Compiler/Providers/Terse.pm', <<'TERSE');
package Genesis::CI::Compiler::Providers::Terse;
use parent 'Genesis::CI::Compiler::PipelineProvider';
sub provider_type {'terse'}
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
TERSE
	local @INC = ('t/tmp/lib', @INC);
	Genesis::CI::Compiler::PipelineProvider->register_provider('terse', {
		class     => 'Genesis::CI::Compiler::Providers::Terse',
		file      => 'Genesis/CI/Compiler/Providers/Terse.pm',
		cli_class => 'Genesis::CI::Provider::Manual',
		cli_file  => 'Genesis/CI/Provider/Manual.pm',
	});

	throws_ok {load_with(automated_config('terse'))}
		qr/pipeline\.provider:\s+missing\s+required\s+key\s+token/s,
		"the fragment's required flag is enforced, and names the key";
	lives_ok {load_with(automated_config('terse', 'token: abc'))}
		'and the same configuration loads once the key is written';
};

# Proves T37: the provider's programmatic check runs after the generic
# validation, returns error strings rather than bailing, and makes no
# network call.
subtest 'the programmatic check is narrow and runs second' => sub {
	plan tests => 4;

	# A CLI-side provider class whose validate_config states the one rule
	# a declaration cannot: target or url, but not neither.
	put_file('t/tmp/lib/Genesis/CI/Provider/Pair.pm', <<'PAIR');
package Genesis::CI::Provider::Pair;
our @CALLS;
sub new {my ($c, %cfg) = @_; bless {%cfg}, $c}
sub validate_config {
	my ($self) = @_;
	push @CALLS, {%$self};
	return ("'target' or 'url' is required for the Pair provider")
		unless $self->{target} || $self->{url};
	return ();
}
1;
PAIR
	put_file('t/tmp/lib/Genesis/CI/Compiler/Providers/Pair.pm', <<'PAIRC');
package Genesis::CI::Compiler::Providers::Pair;
use parent 'Genesis::CI::Compiler::PipelineProvider';
sub provider_type {'pair'}
sub provider_options_schema {
	return {
		target => {type => 'string', description => 'One of the pair'},
		url    => {type => 'string', description => 'The other of the pair'},
	};
}
sub capabilities {
	return {map {($_ => 1)} qw/cross_pipeline_events deployment_locks
		multi_file_output optional_git_triggers per_commit_runs
		scheduled_jobs/};
}
1;
PAIRC
	local @INC = ('t/tmp/lib', @INC);
	Genesis::CI::Compiler::PipelineProvider->register_provider('pair', {
		class     => 'Genesis::CI::Compiler::Providers::Pair',
		file      => 'Genesis/CI/Compiler/Providers/Pair.pm',
		cli_class => 'Genesis::CI::Provider::Pair',
		cli_file  => 'Genesis/CI/Provider/Pair.pm',
	});

	throws_ok {load_with(automated_config('pair'))}
		qr/'target' or 'url' is required for the Pair provider/,
		'the programmatic rule is raised at load';
	lives_ok {load_with(automated_config('pair', 'url: https://ci'))}
		'and one of the pair satisfies it';

	# It runs second, so the generic refusal wins and the check is never
	# reached with an undeclared key in hand.
	{
		local @Genesis::CI::Provider::Pair::CALLS = ();
		throws_ok {load_with(automated_config('pair', 'nonesuch: 1'))}
			qr/pipeline\.provider\.nonesuch: unknown configuration key/,
			'the generic validation refuses first';
		is scalar(@Genesis::CI::Provider::Pair::CALLS), 0,
			'so the programmatic check never ran';
	}
};

done_testing;
