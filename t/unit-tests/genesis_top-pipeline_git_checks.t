#!perl
# Proves T473's load half (D143): pipeline.provider.git is the Concourse
# provider's, so the manual provider refuses it as any provider key, and its
# keys are declared under Concourse.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 1, vault => 0);
my @GIT = ('git:', '  webhooks: true', '  check_every: 1h', '  control_check_every: 1m');

subtest 'declared under Concourse' => sub {
	plan tests => 2;
	lives_ok {load_with($h, automated_config('concourse', 'url: https://ci.example.com', 'team: main', @GIT))}
		'the three keys validate';
	throws_ok {load_with($h, automated_config('concourse', 'url: https://ci.example.com', 'team: main',
		'git:', '  webhook: true'))}
		qr/pipeline\.provider\.git\.webhook: unknown configuration key/,
		'and a misspelt one is refused by name';
};

subtest 'refused under the manual provider' => sub {
	plan tests => 1;
	throws_ok {load_with($h, join("\n", 'pipeline:', '  enabled: true', '  provider:', '    type: manual',
		map {"    $_"} @GIT))}
		qr/pipeline\.provider\.git: unknown configuration key/,
		'as any provider key is';
};

done_testing;
