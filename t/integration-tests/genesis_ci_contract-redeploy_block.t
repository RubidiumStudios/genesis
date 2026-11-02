#!/usr/bin/env perl
# Proves T464 (D136; contract b9): the pipeline.redeploy block.  By default
# every environment has its redeploy job, queue and event, beside its deploy,
# as before the block existed.  enabled: false emits none of the three for any
# environment, and an environment's redeploy_cron beside it is refused at load
# naming both keys.  style: grouped lists every redeploy job in one redeploys
# group, out of the deployment group, after it and before propagation.
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
my $DN       = "$ENV_NAME-$Harness::Contract::TYPE";

sub group_named {
	my ($p, $name) = @_;
	return (grep {$_->{name} eq $name} @{$p->{groups} || []})[0];
}

subtest 'by default the redeploy stands beside its deploy' => sub {
	my $h = contract_harness();
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	ok(pipeline_job($p, "redeploy-$ENV_NAME"), 'b3: the redeploy job');
	ok(pipeline_resource($p, "redeploy_$DN"), 'a7: its queue');
	ok(pipeline_resource($p, "${DN}_redeployed"), 'a8: its event');
	ok(!group_named($p, 'redeploys'), 'b9: and no redeploys group');
	ok((grep {grep {$_ eq "redeploy-$ENV_NAME"} @{$_->{jobs}}} @{$p->{groups} || []}),
		'b9: the job sits in the deployment group');
};

subtest 'enabled: false emits no redeploy at all' => sub {
	my $h = contract_harness(config => {'pipeline.redeploy.enabled' => 'false'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	ok(!pipeline_job($p, "redeploy-$ENV_NAME"), 'b9: no redeploy job');
	ok(!pipeline_resource($p, "redeploy_$DN"), 'b9: no queue');
	ok(!pipeline_resource($p, "${DN}_redeployed"), 'b9: no event');
	ok(!(grep {grep {/^redeploy-/} @{$_->{jobs}}} @{$p->{groups} || []}),
		'b9: and no group names one');
	ok(pipeline_job($p, "deploy-$ENV_NAME"), 'the deploy is still there');
};

subtest 'a redeploy_cron beside enabled: false is refused' => sub {
	my $h = contract_harness(config => {'pipeline.redeploy.enabled' => 'false'},
		pipeline => {redeploy_cron => '0 3 * * *'});
	my ($p, $why) = dry_pipeline($h);
	ok(!$p, 'the dry apply refuses') or return;
	like($why, qr/^exit 78\b/, 'at CONFIG');
	like($why, qr/genesis\.pipeline\.redeploy_cron/, 'naming the environment\'s key');
	like($why, qr/pipeline\.redeploy\.enabled/, 'and the repository\'s');
};

subtest 'style: grouped lists the redeploys apart' => sub {
	my $h = contract_harness(config => {'pipeline.redeploy.style' => 'grouped'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	my $group = group_named($p, 'redeploys');
	is_deeply($group && $group->{jobs}, ["redeploy-$ENV_NAME"], 'b9: one redeploys group');
	ok(!(grep {$_->{name} ne 'redeploys' && grep {/^redeploy-/} @{$_->{jobs}}} @{$p->{groups} || []}),
		'b9: and no other group names a redeploy');
	my @names = map {$_->{name}} @{$p->{groups} || []};
	my ($r) = grep {$names[$_] eq 'redeploys'} 0..$#names;
	my ($g) = grep {$names[$_] eq 'propagation'} 0..$#names;
	ok(defined $r && defined $g && $r == $g - 1 && $r > 0,
		'b9: after the deployment group and before propagation') or diag(explain(\@names));
};

subtest 'an unknown style is refused' => sub {
	my $h = contract_harness(config => {'pipeline.redeploy.style' => 'apart'});
	my ($p, $why) = dry_pipeline($h);
	ok(!$p, 'the dry apply refuses') or return;
	like($why, qr/pipeline\.redeploy\.style/, 'naming the key');
};

done_testing;
