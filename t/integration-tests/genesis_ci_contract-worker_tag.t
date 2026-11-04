#!/usr/bin/env perl
# Proves T469's compile half (D139; contract b5): an environment's worker
# tag lands on the steps that reach its network and on nothing else.  The
# task of its deploy, redeploy and notify jobs carries the tag; no lock,
# shuttle, Slack or branch step, no resource, and no propagate step does,
# those reaching services beside Concourse.  A tag set in a file several
# environments share reaches each of them.
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

sub tagged_steps {
	my ($job) = @_;
	return grep {exists $_->{tags}} plan_steps($job);
}

sub job_steps_except_task {
	my ($job) = @_;
	return grep {!$_->{task}} plan_steps($job);
}

subtest "the tag lands on the environment's tasks alone" => sub {
	# Slack, so the notify job is emitted and its puts are among the steps.
	my $h = contract_harness(pipeline => {manual => 1, provider => {tag => 'net-a'}},
		config => {'pipeline.notifications.slack.webhook' => 'ci/slack:webhook'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	for my $name ("deploy-$ENV_NAME", "redeploy-$ENV_NAME", "notify-$ENV_NAME") {
		my $job = pipeline_job($p, $name);
		ok($job, "the pipeline has $name") or next;
		is_deeply(task_step($job)->{tags}, ['net-a'], "b5: $name\'s task carries the tag");
		my @other = grep {exists $_->{tags}} job_steps_except_task($job);
		ok(!@other, "b5: and no other step of $name does")
			or diag(explain([map {$_->{get} // $_->{put}} @other]));
	}
	ok(!tagged_steps(pipeline_job($p, 'propagate')), 'b5: propagate carries none');
	my @resources = grep {exists $_->{tags}} @{$p->{resources} || []};
	ok(!@resources, 'b5: and no resource does') or diag(explain([map {$_->{name}} @resources]));
};

subtest 'a list is emitted as the list' => sub {
	my $h = contract_harness(pipeline => {provider => {tag => ['net-a', 'dmz']}});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	is_deeply(task_step(pipeline_job($p, "deploy-$ENV_NAME"))->{tags}, ['net-a', 'dmz'],
		'b5: the deploy task carries both');
};

subtest 'a tag in a shared file reaches every environment beneath it' => sub {
	my $h = contract_harness(envs => ['site-qa', 'site-prod'],
		env_files => {site => "---\ngenesis:\n  pipeline:\n    provider:\n      tag: net-b\n"});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	is_deeply(task_step(pipeline_job($p, "deploy-$_"))->{tags}, ['net-b'],
		"D79: deploy-$_ carries the shared tag") for qw/site-qa site-prod/;
};

subtest 'with no tag nothing carries tags' => sub {
	my $h = contract_harness();
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	ok(!tagged_steps($_), "b5: $_->{name} carries none") for @{$p->{jobs} || []};
	ok(!(grep {exists $_->{tags}} @{$p->{resources} || []}), 'b5: and no resource does');
};

done_testing;
