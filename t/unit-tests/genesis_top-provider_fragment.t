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
# committer identity are required beside it.
sub concourse {
	my (@lines) = @_;
	return join("\n", 'pipeline:', '  enabled: true',
		'  source_control:',
		'    repository: genesis/bosh-deployments',
		'    auth:',
		'      type: ssh',
		'      vault: secret/ci/git',
		'    identity:',
		'      name: Genesis CI',
		'      email: ci@genesis.example.com',
		'  provider:', '    type: concourse', '    target: ci',
		map {"    $_"} @lines);
}

subtest "the configured provider's fragment is merged at load" => sub {
	plan tests => 4;

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

done_testing;
