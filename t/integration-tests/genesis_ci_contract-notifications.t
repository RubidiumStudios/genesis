#!/usr/bin/env perl
# Proves T420: the pipeline `genesis pipeline-apply --dry-run` prints notifies
# as D122 restores the legacy pipeline's notifications, a manual environment's
# notify job and every deploy's Slack messages.  Each row names the contract
# row it asserts.
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
my $TYPE     = $Harness::Contract::TYPE;
my $DN       = "$ENV_NAME-$TYPE";
my $NOTIFY   = "notify-$ENV_NAME";
my $DEPLOY   = "deploy-$ENV_NAME";
my $BRANCH   = "$ENV_NAME-branch";

my %SLACK = (
	'pipeline.notifications.slack.webhook' => 'ci/slack:webhook',
	'pipeline.notifications.slack.channel' => '#deploys',
);

sub slack_puts {
	my ($node) = @_;
	return grep {($_->{put} // '') eq 'slack'} plan_steps($node || {});
}
sub deploy_plan {(pipeline_job($_[0], $DEPLOY) || {})->{plan}[0] || {}}
sub branch_get  {
	my ($job) = @_;
	return (grep {($_->{get} // '') eq $BRANCH} plan_steps($job))[0] || {};
}

# What fly validate-pipeline refuses: a step naming no resource, a passed
# naming no job or a job that does not read that resource, an unknown type.
sub pipeline_faults {
	my ($p) = @_;
	my %res   = map {($_->{name} => $_)} @{$p->{resources} || []};
	my %types = map {($_->{name} => 1)} @{$p->{resource_types} || []},
		map {{name => $_}} qw/git registry-image time s3/;
	my %reads;
	for my $job (@{$p->{jobs} || []}) {
		$reads{$job->{name}}{$_->{get}} = 1 for grep {$_->{get}} plan_steps($job);
	}
	my @faults;
	push @faults, "resource $_->{name} has unknown type $_->{type}"
		for grep {!$types{$_->{type}}} values %res;
	for my $job (@{$p->{jobs} || []}) {
		for my $step (plan_steps($job)) {
			my $r = $step->{get} // $step->{put} // next;
			push @faults, "$job->{name} names no resource $r" unless $res{$r};
			for my $up (@{$step->{passed} || []}) {
				push @faults, "$job->{name}: passed $up is no job reading $r"
					unless $reads{$up} && $reads{$up}{$r};
			}
		}
	}
	return @faults;
}

subtest 'T420 rows for a manual environment under the default style' => sub {
	my $h = contract_harness(config => {%SLACK,
		'pipeline.notifications.slack.mentions_on_failure' => ['@oncall'],
	}, pipeline => {manual => 'true'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	is_deeply([pipeline_faults($p)], [], 'fly would accept it');

	my $slack = pipeline_resource($p, 'slack') || {};
	is($slack->{type}, 'slack-notification', 'a19: a slack resource');
	is_deeply($slack->{source}, {url => '((ci/slack.webhook))'},
		"a19: on the webhook, in Concourse's dot form");
	my ($type) = grep {$_->{name} eq 'slack-notification'} @{$p->{resource_types} || []};
	is($type && $type->{source}{repository}, 'cfcommunity/slack-notification-resource',
		'a19: and its type');

	my $nj = pipeline_job($p, $NOTIFY);
	ok($nj, "b8: $NOTIFY") or return;
	ok($nj->{serial}, 'b8: serial');

	my @gets = grep {$_->{get}} plan_steps($nj);
	is_deeply([map {$_->{get}} @gets], [$BRANCH], 'c13: it gets the branch alone');
	is($gets[0] && $gets[0]{trigger}, 1, 'c13: and triggers on it');

	my $task = task_step($nj) || {};
	my $dtask = task_step(pipeline_job($p, $DEPLOY)) || {};
	is_deeply($task->{config}{run}{args}, [$ENV_NAME, 'deploy', '--dry-run'],
		"e12: it runs the deploy's dry run");
	is_deeply([@{$task->{config}{run} || {}}{qw/dir path/}], [@{$dtask->{config}{run} || {}}{qw/dir path/}],
		"e12: from the deploy's directory and binary");
	is_deeply($task->{config}{image_resource}, $dtask->{config}{image_resource}, "e12: on its image");
	is_deeply($task->{config}{params}, $dtask->{config}{params}, 'e12: with its params');
	is_deeply($task->{config}{inputs}, [{name => $BRANCH}], 'e12: reading the branch');

	my @put = slack_puts($nj->{plan});
	is(scalar(@put), 1, 'd9: its plan puts to slack once');
	is($put[0] && $put[0]{params}{text},
		"$TYPE: Changes are staged to be deployed to $DN, see $NOTIFY job for change summary, ".
		"then schedule and run a deploy via Concourse", 'd9: the staged text');
	is($put[0] && $put[0]{params}{channel}, '#deploys', 'd9: on the channel');
	my @plan = @{$nj->{plan} || []};
	ok(@plan && grep({($_->{put} // '') eq 'slack'} plan_steps($plan[-1])), 'd9: after its task');

	my $bget = branch_get(pipeline_job($p, $DEPLOY));
	is_deeply($bget->{passed}, [$NOTIFY], 'c2: inline, the deploy takes what was announced');
	is($bget->{trigger}, 0, 'c1: and still waits for the button');

	my $dp = deploy_plan($p);
	my ($ok)   = slack_puts($dp->{on_success});
	my ($fail) = slack_puts($dp->{on_failure});
	is($ok && $ok->{params}{text}, "$TYPE: Concourse successfully deployed $DN", 'd10: success text');
	is($fail && $fail->{params}{text}, "\@oncall: $TYPE: Concourse deployment to $DN failed",
		'd10: failure text, with the mentions');
	my ($err)   = slack_puts($dp->{on_error});
	my ($abort) = slack_puts($dp->{on_abort});
	is($err && $err->{params}{text}, "\@oncall: $TYPE: Concourse deployment to $DN errored",
		'd10: errored text, with the mentions');
	is($abort && $abort->{params}{text}, "$TYPE: Concourse deployment to $DN was aborted",
		'd10: aborted text, without them');

	my $could_not = "\@oncall: $TYPE: Could not determine the changes staged for $DN, see $NOTIFY job";
	for my $outcome (qw/on_failure on_error/) {
		my ($np) = slack_puts($nj->{$outcome});
		is($np && $np->{params}{text}, $could_not, "d9: the notify job $outcome says so, with the mentions");
	}
	ok(grep({($_->{put} // '') eq "${DN}_ran"} plan_steps($dp->{on_success})),
		'd2: the _ran put stays on success');
	ok(!grep({($_->{put} // '') =~ /_ran$/} map {plan_steps($dp->{$_})} qw/on_failure on_abort on_error/),
		'd6: and on no other outcome');
};

subtest 'T420: parallel and grouped leave the deploy ungated' => sub {
	for my $style (qw/parallel grouped/) {
		my $h = contract_harness(config => {%SLACK, 'pipeline.notifications.style' => $style},
			pipeline => {manual => 'true'});
		my ($p, $why) = dry_pipeline($h);
		unless (ok($p, "$style: the dry apply prints a pipeline")) {diag($why); next}
		is_deeply([pipeline_faults($p)], [], "$style: fly would accept it");
		ok(pipeline_job($p, $NOTIFY), "$style: b8 the notify job");
		ok(!branch_get(pipeline_job($p, $DEPLOY))->{passed}, "$style: c2 no passed on the deploy");
		my ($ng) = grep {$_->{name} eq 'notifications'} @{$p->{groups} || []};
		if ($style eq 'grouped') {
			is_deeply($ng && $ng->{jobs}, [$NOTIFY], 'grouped: b8 notify jobs in a notifications group');
			ok(!grep({$_->{name} ne 'notifications' && grep {$_ eq $NOTIFY} @{$_->{jobs}}} @{$p->{groups} || []}),
				'grouped: and in no other');
		} else {
			ok(!$ng, 'parallel: no notifications group');
		}
	}
};

subtest 'T420: an automatic environment gets the deploy messages alone' => sub {
	my $h = contract_harness(config => {%SLACK});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	is_deeply([pipeline_faults($p)], [], 'fly would accept it');
	ok(!grep({$_->{name} =~ /^notify-/} @{$p->{jobs} || []}), 'b8: no notify job');
	my $dp = deploy_plan($p);
	is(scalar(slack_puts($dp->{on_success})), 1, 'd10: success put');
	is(scalar(slack_puts($dp->{on_failure})), 1, 'd10: failure put');
	ok(!branch_get(pipeline_job($p, $DEPLOY))->{passed}, 'c2: no passed');
};

subtest 'T420: an app webhook needs no channel, name or icon' => sub {
	my $h = contract_harness(config => {'pipeline.notifications.slack.webhook' => 'slack:webhook'},
		pipeline => {manual => 'true'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'a webhook alone loads and compiles') or return diag($why);
	my @puts = map {slack_puts($_)} @{$p->{jobs} || []};
	ok(scalar(@puts), 'and the jobs put to slack');
	is_deeply([sort map {keys %{$_->{params} || {}}} @puts], [('text') x @puts],
		'each put carrying its text alone');
};

subtest 'T420: no Slack, no notifications' => sub {
	my $h = contract_harness(pipeline => {manual => 'true'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	ok(!pipeline_resource($p, 'slack'), 'a19: no slack resource');
	ok(!grep({$_->{name} eq 'slack-notification'} @{$p->{resource_types} || []}), 'a19: nor its type');
	ok(!grep({$_->{name} =~ /^notify-/} @{$p->{jobs} || []}), 'b8: no notify job');
	ok(!grep({slack_puts($_)} @{$p->{jobs} || []}), 'd10: no slack put');
	ok(!branch_get(pipeline_job($p, $DEPLOY))->{passed}, 'c2: no passed');
};

done_testing;
