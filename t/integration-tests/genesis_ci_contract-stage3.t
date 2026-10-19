#!/usr/bin/env perl
# Proves T414: the pipeline `genesis pipeline-apply --dry-run` prints holds the
# plumbing contract's Stage 3 Pull rows, the deploy locks.  They are the
# legacy pipeline's two locks applied to the new structure: each environment
# is asked, from control, its deployment name, its director, and whether it is
# create-env.  Each row names the contract row it asserts.
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

sub lock_steps {
	my ($steps, $op) = @_;
	return map {"$_->{put}:$_->{params}{key}"}
		grep {($_->{params}{lock_op} // '') eq $op} grep {$_->{put}} @$steps;
}

subtest 'Stage 3 rows for an environment its own director deploys' => sub {
	my $h = contract_harness(genesis => {bosh_env => 'mgmt'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my $own = pipeline_resource($p, "$DN-lock") || {};
	my $dir = pipeline_resource($p, 'mgmt-bosh-lock') || {};
	is($own->{type}, 'locker', 'a10: a locker resource for its own pool');
	is($own->{source}{lock_name}, $DN, 'a10: on the pool <dn>');
	is($dir->{source}{lock_name}, 'mgmt-bosh', "a11: and one on its director's pool");
	ok(!exists $dir->{source}{bosh_lock} && !exists $own->{source}{bosh_lock}, 'a11: never bosh_lock');
	is($own->{source}{skip_ssl_validation}, 0, 'a13: skip_ssl_validation false by default');
	is(scalar(grep {($_->{type} // '') eq 'locker'} @{$p->{resources} || []}), 2,
		'g8: one resource per pool, and no other');

	my $jb   = pipeline_job($p, "deploy-$ENV_NAME") || {};
	my $plan = $jb->{plan}[0] || {};
	my @do   = plan_steps($plan->{do} || []);
	is_deeply([lock_steps(\@do, 'lock')],
		['mgmt-bosh-lock:dont-upgrade-bosh-on-me', "$DN-lock:i-need-to-deploy-myself"],
		"g1, g2, g4: the director's lock, then its own");
	ok(@do >= 2 && !grep({$_->{get}} @do[0, 1]), 'g5: both before any get');
	is_deeply([lock_steps([plan_steps($plan->{ensure} || {})], 'unlock')],
		["$DN-lock:i-need-to-deploy-myself", 'mgmt-bosh-lock:dont-upgrade-bosh-on-me'],
		'g5: released in reverse in its ensure');
	is_deeply([map {$_->{params}{locked_by}} grep {$_->{put}} @do], [$DN, $DN], 'g1, g2: locked by <dn>');
	is_deeply($jb->{serial_groups}, [$DN], 'g9: serial_groups [<dn>]');
};

subtest 'a11: a create-env environment takes no director lock' => sub {
	my $h = contract_harness(genesis => {use_create_env => 'true'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	is_deeply([sort map {$_->{name}} grep {($_->{type} // '') eq 'locker'} @{$p->{resources} || []}],
		["$DN-lock"], 'its own pool alone');
	my @do = plan_steps((pipeline_job($p, "deploy-$ENV_NAME") || {})->{plan}[0]{do} || []);
	is_deeply([lock_steps(\@do, 'lock')], ["$DN-lock:i-need-to-deploy-myself"], 'and only its own lock');
};

subtest "g2, g8: a director's pool is its own deploy's and its children's director lock" => sub {
	my $h = contract_harness(type => 'bosh', envs => ['mgmt', 'lab'], env_genesis => {
		mgmt => {use_create_env => 'true'},
		lab  => {bosh_env => 'mgmt'},
	});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	is_deeply([sort map {$_->{name}} grep {($_->{type} // '') eq 'locker'} @{$p->{resources} || []}],
		['lab-bosh-lock', 'mgmt-bosh-lock'], 'one resource per pool, mgmt-bosh shared');
	my $locks = sub {
		my ($env) = @_;
		lock_steps([plan_steps((pipeline_job($p, "deploy-$env") || {})->{plan}[0]{do} || [])], 'lock');
	};
	is_deeply([$locks->('mgmt')], ['mgmt-bosh-lock:i-need-to-deploy-myself'],
		"the director's deploy holds its own pool, being create-env");
	is_deeply([$locks->('lab')],
		['mgmt-bosh-lock:dont-upgrade-bosh-on-me', 'lab-bosh-lock:i-need-to-deploy-myself'],
		"and lab holds that pool as its director's, then its own");
};

done_testing;
