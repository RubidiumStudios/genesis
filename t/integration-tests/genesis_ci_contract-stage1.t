#!/usr/bin/env perl
# Proves T412: the pipeline `genesis pipeline-apply --dry-run` prints holds the
# plumbing contract's Stage 1 rows, the environment's branch resource and its
# deploy job.  Each row names the contract row it asserts (design/
# plumbing-contract.md), so a contract row with no assertion here is visible.
# The repository is Harness::Contract's: a doomsday-type root in a doomsday/
# subdirectory of its clone, with one environment, qa.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Harness::Contract;

use Test::More;

use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $ENV_NAME = $Harness::Contract::ENV_NAME;
my $TYPE     = $Harness::Contract::TYPE;
my $ROOT     = $Harness::Contract::ROOT;

sub deploy_job {my ($p) = @_; pipeline_job($p, "deploy-$ENV_NAME")}

subtest 'Stage 1 rows over a default doomsday root' => sub {
	my $h = contract_harness();
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my $br   = branch_resource($p) || {};
	my $jb   = deploy_job($p);
	my $task = task_step($jb) || {};
	my %env  = %{$task->{config}{params} || {}};
	my $run  = $task->{config}{run} || {};

	is($br->{source}{branch}, "$ENV_NAME/$TYPE", 'a1: the branch resource watches <env>/<type>');
	ok(length($br->{source}{uri} // ''), 'a2: it has a uri');
	like($br->{source}{private_key} // '', qr/^\(\(secret\/ci\/git:private_key\)\)$/,
		'a3: its ssh credential is a reference to the declared component');
	ok(!exists $br->{source}{ignore_paths}, 'a4: it filters no paths');

	ok($jb, "b1: the deploy job is named deploy-$ENV_NAME")
		or diag(join(', ', map {$_->{name}} @{$p->{jobs} || []}));
	is($jb && $jb->{serial}, 1, 'b1: and is serial');

	my @gets = grep {$_->{get}} plan_steps($jb);
	my ($bget) = grep {$_->{get} eq ($br->{name} // '')} @gets;
	is($bget && $bget->{trigger}, 1, 'c1: it triggers on its branch, manual being unset');
	ok($bget && !exists $bget->{passed}, 'c2: with no passed constraint');
	is(scalar(grep {$_->{trigger} && $_ != ($bget // {})} @gets), 0, 'c3: and on nothing else');

	my @git = map {$_->{name}} grep {($_->{type} // '') eq 'git'} @{$p->{resources} || []};
	is(scalar(grep {my $put = $_->{put}; $put && grep {$_ eq $put} @git} plan_steps($jb)), 0,
		'd7: the deploy job puts to no git resource');

	is_deeply($run->{args}, [$ENV_NAME, 'deploy', '-SFy'], 'e1: the task runs <env> deploy -SFy');
	ok(!grep({$_ eq '--recreate'} @{$run->{args} || []}), 'e2: with no --recreate');
	is($run->{dir}, ($br->{name} // '?')."/$ROOT", 'e6: in the deployment root, through run.dir');
	is($run->{path}, '.genesis/bin/genesis', "e7: running the root's own genesis");
	is($task->{config}{image_resource}{source}{repository}, 'genesiscommunity/concourse',
		'e8: on the default task image');

	is($env{GENESIS_PIPELINE_TASK}, 1, 'f1: GENESIS_PIPELINE_TASK is set');
	ok(!exists $env{GENESIS_HONOR_ENV}, 'f2: GENESIS_HONOR_ENV is not');
	like($env{GIT_PRIVATE_KEY} // '', qr/^\(\(secret\/ci\/git:private_key\)\)$/, 'f3: the git credential is a reference');
	is_deeply([@env{qw/GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL/}], ['Genesis CI', 'ci@genesis.example.com'],
		'f4: the commit identity is the configured one');
	ok(!exists $env{VAULT_ROLE_ID} && !exists $env{VAULT_AUTH_TOKEN},
		'f5: no vault credential where pipeline.vault declares no auth');
	ok(!exists $env{CURRENT_ENV} && !exists $env{GIT_BRANCH}, 'f7: no CURRENT_ENV or GIT_BRANCH');
	is($env{CI_NO_REDACT}, 0, 'f9: CI_NO_REDACT is 0 by default');
};

subtest 'Stage 1 rows the configuration changes' => sub {
	my $h = contract_harness(
		config   => {
			'pipeline.recreate_on_deploy' => 'always',
			'pipeline.unredacted'         => 'true',
			'pipeline.provider.task.image'   => 'example/task',
			'pipeline.provider.task.version' => '1.2',
			'pipeline.vault.auth.type'    => 'token',
			'pipeline.vault.auth.path'    => 'secret/ci/vault',
		},
		pipeline => {manual => 'true'},
	);
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my $br   = branch_resource($p) || {};
	my $jb   = deploy_job($p);
	my $task = task_step($jb) || {};
	my %env  = %{$task->{config}{params} || {}};
	my ($bget) = grep {$_->{get} && $_->{get} eq ($br->{name} // '')} plan_steps($jb);

	is($bget && $bget->{trigger}, 0, 'c1: manual turns the branch trigger off');
	ok(!grep({$_ eq '--recreate'} @{$task->{config}{run}{args} || []}),
		'e2: no --recreate under recreate_on_deploy always, the deploy reading the key itself');
	is_deeply($task->{config}{image_resource}{source}, {repository => 'example/task', tag => '1.2'},
		'e8: the configured task image');
	is($env{VAULT_AUTH_TOKEN}, '((secret/ci/vault:token))', 'f5: token auth gives VAULT_AUTH_TOKEN');
	ok(!exists $env{VAULT_TOKEN} && !exists $env{VAULT_ROLE_ID} && !exists $env{VAULT_SECRET_ID},
		'f5: and no other vault credential');
	is($env{CI_NO_REDACT}, 1, 'f9: pipeline.unredacted sets CI_NO_REDACT');
};

subtest 'e7: a root with no embedded genesis is refused at compile' => sub {
	my $h = contract_harness(no_binary => 1);
	my ($out, $err, $exit) = run_genesis($h, {dir => $ROOT}, 'pipeline-apply', '--dry-run', '--skip-vault');
	is($exit, Genesis::Exit::CONFIG, 'the dry apply refuses at CONFIG');
	like(unfolded($err), qr/\.genesis\/bin\/genesis.*genesis embed/, 'naming the file and genesis embed');
};

done_testing;
