#!/usr/bin/env perl
# Proves T415 and T441: the pipeline `genesis pipeline-apply --dry-run` prints
# holds the plumbing contract's Stage 4 Pull rows, each deployment's events on
# the shuttle named for what wrote them (D127), _deployed, which its deploy
# writes and the propagate job triggers on, and _redeployed, which only its
# redeploy writes and propagate never reads.  Each row names the contract row
# it asserts.
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
my $RAN      = "${DN}_deployed";
my $REDONE   = "${DN}_redeployed";

sub ran_puts {
	my ($node, $ran) = @_;
	return grep {($_->{put} // '') eq ($ran // $RAN)} plan_steps($node || {});
}
sub ran_puts_of {
	my ($p, $env, $ran) = @_;
	return ran_puts(((pipeline_job($p, "deploy-$env") || {})->{plan}[0] || {})->{on_success}, $ran);
}

subtest 'Stage 4 rows over the default shuttle' => sub {
	my $h = contract_harness();
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my $ran = pipeline_resource($p, $RAN) || {};
	is($ran->{type}, 'shuttle', 'a8: a shuttle resource <dn>_deployed');
	is($ran->{source}{path}, "$DN/deployed", 'a8: on the path <dn>/deployed');
	is($ran->{source}{seed_version}, 1, 'a8: with seed_version');
	my $redone = pipeline_resource($p, $REDONE) || {};
	is($redone->{source}{path}, "$DN/redeployed", 'a8: and <dn>_redeployed on <dn>/redeployed');
	is_deeply({%{$redone->{source} || {}}, path => undef}, {%{$ran->{source} || {}}, path => undef},
		'a8: on the same source');
	ok(!grep({$_->{name} =~ /_ran$|^run_|^deploy_/} @{$p->{resources} || []}),
		'D127: no _ran, run_ or deploy_ resource');
	is($ran->{source}{bucket}, 'pipes', "a9: in the configured bucket");
	ok(!grep({exists $ran->{source}{$_}} qw/backend prefix json_key image image_tag auth/),
		'a9: and none of the keys the resource ignores');
	ok(!$ran->{source}{tls_skip_verify}, 'a9: and verifies TLS by default');

	my ($type) = grep {$_->{name} eq 'shuttle'} @{$p->{resource_types} || []};
	is_deeply($type && $type->{source}, {repository => 'klaue/shuttle-resource', tag => 'latest'},
		'a18: the shuttle type on the default image');

	ok(!grep({($_->{get} // '') =~ /_(?:re)?deployed$/} plan_steps(pipeline_job($p, 'propagate'))),
		"c5: propagate gets no event, qa being a tail");

	my $plan = (pipeline_job($p, "deploy-$ENV_NAME") || {})->{plan}[0] || {};
	my @put = ran_puts($plan->{on_success});
	is(scalar(@put), 1, 'd2: the deploy puts its _deployed on success');
	ok(!grep({($_->{put} // '') eq $REDONE} plan_steps($plan)), 'd2: and never _redeployed');
	ok(@put && !exists $put[0]{params}, 'd2: with no params');
	my $gp = @put ? $put[0]{get_params} || {} : {};
	ok($gp->{skip} && keys(%$gp) == 1, 'd2: and get_params skip');
	is(scalar(map {ran_puts($plan->{$_})} qw/on_failure on_abort on_error ensure do/), 0,
		'd6: and on no other outcome');
};

subtest 'c5: propagate triggers on the _deployed of a deployment with a successor' => sub {
	my $h = contract_harness(envs => [$ENV_NAME, 'prod'], chained => 1);
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my $tail = "prod-$Harness::Contract::TYPE\_deployed";
	my %get = map {($_->{get} => $_)} grep {$_->{get}} plan_steps(pipeline_job($p, 'propagate'));
	is($get{$RAN} && $get{$RAN}{trigger}, 1, "qa's, which prod follows");
	ok(!$get{$tail}, "and not prod's, the tail");
	ok(!grep({/_redeployed$/} keys %get), 'D127: and never a _redeployed, a redeploy delivering nothing');
	ok(pipeline_resource($p, $tail), "whose _deployed is still emitted (a8)");

	# T442: a deploy reads its predecessor's event for the layout alone.
	my @prod = grep {($_->{get} // '') =~ /_(?:re)?deployed$/} plan_steps(pipeline_job($p, 'deploy-prod'));
	is_deeply([map {$_->{get}} @prod], [$RAN], "c14: deploy-prod gets qa's _deployed");
	ok(@prod && !$prod[0]{trigger}, 'c14: without triggering on it');
	ok(!grep({($_->{get} // '') =~ /_(?:re)?deployed$/} plan_steps(pipeline_job($p, "deploy-$ENV_NAME"))),
		'c14: and qa, which follows nothing, gets no event');
	is(scalar(ran_puts_of($p, 'prod', $tail)), 1, 'and put on its success (d2)');
};

subtest 'a9: the configured shuttle source' => sub {
	my $h = contract_harness(config => {
		'pipeline.shuttle.region'   => 'us-west-2',
		'pipeline.shuttle.endpoint' => 'https://minio.example.com',
		'pipeline.shuttle.auth'     => 'secret/ci/shuttle',
		'pipeline.shuttle.image'    => 'example/shuttle',
		'pipeline.shuttle.image_tag' => 'v2',
		'pipeline.shuttle.tls_skip_verify' => 'true',
	});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my $src = (pipeline_resource($p, $RAN) || {})->{source} || {};
	is_deeply([@$src{qw/region endpoint/}], ['us-west-2', 'https://minio.example.com'],
		'the region and endpoint as written');
	is($src->{access_key_id}, '((secret/ci/shuttle.access_key_id))', 'the key id as a reference');
	is($src->{secret_access_key}, '((secret/ci/shuttle.secret_access_key))', 'and the secret');
	ok($src->{tls_skip_verify}, 'tls_skip_verify as configured, for a store whose certificate cannot be verified');

	my ($type) = grep {$_->{name} eq 'shuttle'} @{$p->{resource_types} || []};
	is_deeply($type && $type->{source}, {repository => 'example/shuttle', tag => 'v2'},
		'a18: the configured image');
};

done_testing;
