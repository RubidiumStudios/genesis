#!perl
# Proves T503: pipeline.source_control.identity is optional, and a pipeline
# task given no name or email commits as Concourse Bot <concourse@pipeline>,
# which is what a v2 pipeline committed as (D172).
#
# The block and both of its keys were required under an automated provider.
# The emitter already fell back to those two values wherever one was
# missing, so the requirement refused a configuration the compile could
# have completed.
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
use_ok 'Genesis::CI::Compiler::Parser';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

# An automated pipeline whose source_control carries the identity lines
# given, or none.
sub config_with {
	my (@identity) = @_;
	return join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: concourse',
		'    url: https://ci.example.com', '    team: main',
		'  source_control:', '    repository: team/bosh',
		'    auth:', '      type: ssh', '      path: secret/ci/git',
		@identity,
		automation_block_lines());
}

my %DEFAULT = (name => 'Concourse Bot', email => 'concourse@pipeline');

subtest 'a pipeline with no identity loads, and commits as v2 did' => sub {
	plan tests => 3;
	my $top;
	lives_ok {$top = load_with($h, config_with())} 'it loads under an automated provider';
	is_deeply($top ? $top->pipeline_identity : undef, \%DEFAULT,
		'the identity is Concourse Bot <concourse@pipeline>');
	my $parsed = $top ? Genesis::CI::Compiler::Parser->new(top => $top)->parse : {};
	is_deeply($parsed->{integrations}{source_control}{commit_author}, \%DEFAULT,
		'and that is the committer the compiler is handed');
};

subtest 'each half defaults alone' => sub {
	plan tests => 2;
	is_deeply(load_with($h, config_with('    identity:', '      name: Genesis CI'))->pipeline_identity,
		{name => 'Genesis CI', email => 'concourse@pipeline'},
		'a name with no email takes the default email');
	is_deeply(load_with($h, config_with('    identity:', '      email: ci@example.com'))->pipeline_identity,
		{name => 'Concourse Bot', email => 'ci@example.com'},
		'and an email with no name the default name');
};

subtest 'an identity that is written is the one used' => sub {
	plan tests => 1;
	is_deeply(load_with($h, config_with('    identity:',
			'      name: Genesis CI', '      email: ci@example.com'))->pipeline_identity,
		{name => 'Genesis CI', email => 'ci@example.com'},
		'both as written');
};

done_testing;
