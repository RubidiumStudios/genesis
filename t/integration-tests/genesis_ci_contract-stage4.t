#!/usr/bin/env perl
# Proves T415: the pipeline `genesis pipeline-apply --dry-run` prints holds the
# plumbing contract's Stage 4 Pull rows, each deployment's _ran event on the
# shuttle, which its deploy writes and the propagate job triggers on.  Each
# row names the contract row it asserts.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Harness::Contract;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $ENV_NAME = $Harness::Contract::ENV_NAME;
my $DN       = "$ENV_NAME-$Harness::Contract::TYPE";
my $RAN      = "${DN}_ran";

sub ran_puts {
	my ($node) = @_;
	return grep {($_->{put} // '') eq $RAN} plan_steps($node || {});
}

subtest 'Stage 4 rows over the default shuttle' => sub {
	my $h = contract_harness();
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my $ran = pipeline_resource($p, $RAN) || {};
	is($ran->{type}, 'shuttle', 'a8: a shuttle resource <dn>_ran');
	is($ran->{source}{path}, "$DN/ran", 'a8: on the path <dn>/ran');
	is($ran->{source}{seed_version}, 1, 'a8: with seed_version');
	is($ran->{source}{bucket}, 'pipes', "a9: in the configured bucket");
	ok(!grep({exists $ran->{source}{$_}} qw/backend prefix json_key image image_tag auth/),
		'a9: and none of the keys the resource ignores');

	my ($type) = grep {$_->{name} eq 'shuttle'} @{$p->{resource_types} || []};
	is_deeply($type && $type->{source}, {repository => 'klaue/shuttle-resource', tag => 'latest'},
		'a18: the shuttle type on the default image');

	my ($get) = grep {($_->{get} // '') eq $RAN} plan_steps(pipeline_job($p, 'propagate'));
	is($get && $get->{trigger}, 1, 'c5: propagate triggers on each _ran');

	my $plan = (pipeline_job($p, "deploy-$ENV_NAME") || {})->{plan}[0] || {};
	my @put = ran_puts($plan->{on_success});
	is(scalar(@put), 1, 'd2: the deploy puts its _ran on success');
	ok(@put && !exists $put[0]{params}, 'd2: with no params');
	my $gp = @put ? $put[0]{get_params} || {} : {};
	ok($gp->{skip} && keys(%$gp) == 1, 'd2: and get_params skip');
	is(scalar(map {ran_puts($plan->{$_})} qw/on_failure on_abort on_error ensure do/), 0,
		'd6: and on no other outcome');
};

subtest 'a9: the configured shuttle source' => sub {
	my $h = contract_harness(config => {
		'pipeline.shuttle.region'   => 'us-west-2',
		'pipeline.shuttle.endpoint' => 'https://minio.example.com',
		'pipeline.shuttle.auth'     => 'secret/ci/shuttle',
		'pipeline.shuttle.image'    => 'example/shuttle',
		'pipeline.shuttle.image_tag' => 'v2',
	});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my $src = (pipeline_resource($p, $RAN) || {})->{source} || {};
	is_deeply([@$src{qw/region endpoint/}], ['us-west-2', 'https://minio.example.com'],
		'the region and endpoint as written');
	is($src->{access_key_id}, '((secret/ci/shuttle:access_key_id))', 'the key id as a reference');
	is($src->{secret_access_key}, '((secret/ci/shuttle:secret_access_key))', 'and the secret');

	my ($type) = grep {$_->{name} eq 'shuttle'} @{$p->{resource_types} || []};
	is_deeply($type && $type->{source}, {repository => 'example/shuttle', tag => 'v2'},
		'a18: the configured image');
};

done_testing;
