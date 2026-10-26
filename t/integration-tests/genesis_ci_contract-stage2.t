#!/usr/bin/env perl
# Proves T413: the pipeline `genesis pipeline-apply --dry-run` prints holds the
# plumbing contract's Stage 2 Pull rows that need no shuttle, the control
# resource and the one propagate job.  c5, the job's _ran triggers, lands with
# a8's shuttle resource in 4 Pull.  Each row names the contract row it asserts.
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

subtest 'Stage 2 rows over a default doomsday root' => sub {
	my $h = contract_harness();
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my $cb = pipeline_resource($p, 'control-branch') || {};
	my $br = branch_resource($p) || {};
	is($cb->{type}, 'git', 'a5: a control-branch git resource');
	is($cb->{source}{branch}, 'control', 'a5: on the control branch');
	is($cb->{source}{uri}, $br->{source}{uri}, "a5: with the branch resource's uri");
	is($cb->{source}{private_key}, $br->{source}{private_key}, 'a5: and its credential');
	ok(!pipeline_resource($p, 'run_propagate'), 'a6: no run_propagate');

	my @prop = grep {$_->{name} eq 'propagate'} @{$p->{jobs} || []};
	is(scalar(@prop), 1, 'b2: one propagate job')
		or diag(join(', ', map {$_->{name}} @{$p->{jobs} || []}));
	my $jb = $prop[0];
	is($jb && $jb->{serial}, 1, 'b2: serial');
	my @groups = @{$p->{groups} || []};
	is_deeply([map {$_->{name}} grep {grep {$_ eq 'propagate'} @{$_->{jobs}}} @groups], ['propagation'],
		'b2: in the propagation group alone');
	is_deeply(@groups ? $groups[-1] : {}, {name => 'propagation', jobs => ['propagate']},
		'b2: which holds it alone, after the deployments');

	my @gets = grep {$_->{get}} plan_steps($jb);
	my ($cget) = grep {$_->{get} eq 'control-branch'} @gets;
	is($cget && $cget->{trigger}, 1, 'c4: it triggers on control-branch');
	ok(!grep({$_->{get} eq ($br->{name} // '?')} @gets), "c6: and gets no environment's branch");

	ok(!grep({($_->{put} // '') =~ /^run_/} map {plan_steps($_)} grep {$_->{name} =~ /^deploy-/} @{$p->{jobs} || []}),
		'd1: no deploy job puts a queue');

	my $task = task_step($jb) || {};
	my $run  = $task->{config}{run} || {};
	my %env  = %{$task->{config}{params} || {}};
	is_deeply($run->{args}, ['propagate'], 'e4, e5: genesis propagate, with no argument, --force or -y');
	is($run->{dir}, "control-branch/$ROOT", 'e6: in the root inside the control input');
	is($run->{path}, '.genesis/bin/genesis', "e7: running the root's own genesis");
	is_deeply([map {$_->{name}} @{$task->{config}{inputs} || []}], ['control-branch'],
		'e10: control its only input');

	my %deploy = %{(task_step(pipeline_job($p, "deploy-$ENV_NAME")) || {})->{config}{params} || {}};
	is($env{GENESIS_PIPELINE_TASK}, 1, 'f1: GENESIS_PIPELINE_TASK is set');
	is($env{GIT_PRIVATE_KEY}, $deploy{GIT_PRIVATE_KEY}, "f3: the deploy's git credential");
	is_deeply([@env{qw/GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL/}], [@deploy{qw/GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL/}],
		"f4: the deploy's commit identity");
	is($env{VAULT_ADDR}, $deploy{VAULT_ADDR}, "f5: the deploy's vault");

	ok(!grep({($_->{put} // '') =~ /-lock$/} plan_steps($jb)), 'g7: it holds no lock');
};

done_testing;
