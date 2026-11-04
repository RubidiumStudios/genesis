#!/usr/bin/env perl
# Proves T470 (D140; contract b7): group_commits: false asks for a deploy of
# each commit in turn, which the compiler does not emit, so it is refused at
# load rather than accepted and silently meaning true.  true, or the key
# absent, prints a pipeline whose deploy takes the tip, no get carrying a
# version.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Harness::Contract;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $ENV_NAME = $Harness::Contract::ENV_NAME;

subtest 'false is refused at load' => sub {
	my ($p, $why) = dry_pipeline(contract_harness(config => {'pipeline.provider.group_commits' => 'false'}));
	ok(!$p, 'the dry apply refuses') or return;
	like($why, qr/^exit 78\b/, 'at CONFIG');
	like($why, qr/pipeline\.provider\.group_commits/, 'naming the key');
	like($why, qr/only .?true.? is supported/, 'and saying only true is supported');
};

for my $case (['true', {'pipeline.provider.group_commits' => 'true'}], ['absent', {}]) {
	my ($label, $config) = @$case;
	subtest "$label loads, and the deploy takes the tip" => sub {
		my ($p, $why) = dry_pipeline(contract_harness(config => $config));
		ok($p, 'the dry apply prints a pipeline') or return diag($why);
		my @gets = grep {$_->{get}} plan_steps(pipeline_job($p, "deploy-$ENV_NAME"));
		ok(@gets, 'the deploy has gets');
		ok(!exists $_->{version}, "b7: the get of $_->{get} carries no version") for @gets;
	};
}

done_testing;
