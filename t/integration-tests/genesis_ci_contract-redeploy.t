#!/usr/bin/env perl
# Proves T437: the pipeline `genesis pipeline-apply --dry-run` prints holds
# the redeploy job pulled forward from Stage 6 as a manual one (contract b3,
# 2026-10-28), with c11, d3, d4, e3, g1, g2 and g9.  Its triggers and its
# queue hand-back stay at Stage 6 (Q44).  Each row names the contract row it
# asserts.
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
my $ROOT     = $Harness::Contract::ROOT;
my $DN       = "$ENV_NAME-$Harness::Contract::TYPE";

sub lock_steps {
	my ($steps, $op) = @_;
	return map {"$_->{put}:$_->{params}{key}"}
		grep {($_->{params}{lock_op} // '') eq $op} grep {$_->{put}} @$steps;
}

subtest 'the redeploy job, manual' => sub {
	my $h = contract_harness(genesis => {bosh_env => 'mgmt'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my $rj = pipeline_job($p, "redeploy-$ENV_NAME");
	ok($rj, "b3: a redeploy-$ENV_NAME job")
		or return diag(join(', ', map {$_->{name}} @{$p->{jobs} || []}));
	is($rj->{serial}, 1, 'b3: serial');
	is_deeply($rj->{serial_groups}, [$DN], 'g9: in the deploy\'s serial group <dn>');

	my ($group) = grep {grep {$_ eq "deploy-$ENV_NAME"} @{$_->{jobs} || []}} @{$p->{groups} || []};
	ok($group && grep({$_ eq "redeploy-$ENV_NAME"} @{$group->{jobs}}),
		'b3: in the deployment group beside the deploy');

	my ($bget) = grep {($_->{get} // '') eq "$ENV_NAME-branch"} plan_steps($rj);
	ok($bget && !$bget->{trigger}, 'c11: it gets the branch, which never triggers it');

	my $task = task_step($rj) || {};
	my $run  = $task->{config}{run} || {};
	is_deeply($run->{args}, [$ENV_NAME, 'deploy', '--redeploy', '-SFy'],
		'e3: it runs <env> deploy --redeploy -SFy');
	is($run->{dir}, "$ENV_NAME-branch/$ROOT", 'e3: in the deployment root');
	is($run->{path}, '.genesis/bin/genesis', "e3: with the root's own genesis");
	is($task->{config}{image_resource}{source}{repository}, 'genesiscommunity/concourse',
		'e3: on the task image');
	is(($task->{config}{params} || {})->{GENESIS_PIPELINE_TASK}, 1, 'f1: as a pipeline task');

	my $plan = $rj->{plan}[0] || {};
	my @do   = plan_steps($plan->{do} || []);
	is_deeply([lock_steps(\@do, 'lock')],
		['mgmt-bosh-lock:dont-upgrade-bosh-on-me', "$DN-lock:i-need-to-deploy-myself"],
		"g1, g2: the director's lock, then its own");
	is_deeply([lock_steps([plan_steps($plan->{ensure} || {})], 'unlock')],
		["$DN-lock:i-need-to-deploy-myself", 'mgmt-bosh-lock:dont-upgrade-bosh-on-me'],
		'g1, g2: released in reverse');
	is_deeply([map {$_->{params}{locked_by}} grep {$_->{put}} @do], [$DN, $DN],
		'g1, g2: locked by <dn>');

	is(scalar(grep {($_->{put} // '') eq "${DN}_redeployed"} plan_steps($plan->{on_success} || {})), 1,
		'd3: it puts <dn>_redeployed on success (D127)');
	ok(!grep({($_->{put} // '') eq "${DN}_deployed"} plan_steps($rj)),
		'D127: and never <dn>_deployed, which only the deploy writes');
	ok(!grep({($_->{put} // '') =~ /run_propagate/} plan_steps($rj)),
		'd4: and never run_propagate');

	my %names = map {($_->{name} => 1)} @{$p->{resources} || []};
	ok(!grep({$names{$_}} "$ENV_NAME-changes", 'git', "$ENV_NAME-redeploy-cron"),
		'none of the retired mode\'s resources');
	ok(!grep({$_ eq 'ci-pipeline-deploy'} map {@{$_->{config}{run}{args} || []}} grep {$_->{task}} plan_steps($rj)),
		'and not its ci-pipeline-deploy');
};

# Proves T438: the request queue the redeploy runs on.
subtest 'the redeploy request queue' => sub {
	my $h = contract_harness();
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my $Q   = "redeploy_$DN";
	my $run = pipeline_resource($p, $Q) || {};
	my $ran = pipeline_resource($p, "${DN}_redeployed") || {};
	is($run->{type}, 'shuttle', 'a7: a shuttle resource redeploy_<dn> (D127)');
	is($run->{source}{path}, "$DN/redeploy", 'a7: on the path <dn>/redeploy');
	is($run->{source}{seed_version}, 1, 'a7: with seed_version');
	is_deeply({%{$run->{source} || {}}, path => undef}, {%{$ran->{source} || {}}, path => undef},
		'a7: on the same source as the events');

	my $rj   = pipeline_job($p, "redeploy-$ENV_NAME") || {};
	my $plan = $rj->{plan}[0] || {};
	my @triggers = grep {$_->{get} && $_->{trigger}} plan_steps($plan->{do} || []);
	is_deeply([map {$_->{get}} @triggers], [$Q], 'c7: the queue is its one trigger');

	# A hand-back names the queue by resource, since Concourse refuses a job
	# with two steps of one name.
	my %back = map {
		my $hook = $_;
		# YAML's true is a boolean object, so each param is read as 1 or 0.
		($hook => [map {my $p = $_->{params} || {}; +{map {($_ => $p->{$_} ? 1 : 0)} keys %$p}}
			grep {($_->{resource} // $_->{get} // '') eq $Q && !$_->{trigger}}
			grep {$_->{get}} plan_steps($plan->{$hook} || {})]);
	} qw/on_success on_failure on_error on_abort/;
	# Concourse refuses two gets of one name in a job (each names an
	# artifact); puts of one resource may repeat, as the lock puts do.
	my @names = map {$_->{get}} grep {$_->{get}} plan_steps($rj);
	my %seen;
	is_deeply([grep {$seen{$_}++ == 1} @names], [], 'no two gets in the job share a name');
	is_deeply($back{on_success}, [{return => 1}], 'd5: handed back on success with return');
	is_deeply($back{on_failure}, [{return => 1, fail => 1}], 'd5: and on failure with return and fail');
	is_deeply($back{on_error}, [{return => 1, fail => 1}], 'd5: and on error the same');
	ok(!grep({($_->{put} // '') eq $Q} map {plan_steps($_)} @{$p->{jobs} || []}),
		'd5: and nothing ever puts it');
	is(scalar(grep {my $j = $_; grep {($_->{resource} // $_->{get} // '') eq $Q} plan_steps($j)} @{$p->{jobs} || []}), 1,
		'a7: and only the redeploy job reads it');
};

done_testing;
