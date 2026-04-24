#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use Test::More;
use Test::Deep;

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';

use_ok 'Genesis::CI::Compiler::AST';
use_ok 'Genesis::CI::Compiler::PipelineDescriptor';

# =========================================================================
# Helpers
# =========================================================================

sub _ast_for {
	my (%o) = @_;

	my $env   = $o{env}   || 'sandbox';
	my $alias = $o{alias} || $env;

	my %integrations = (
		source_control => { provider => 'github', repository => 'org/repo' },
		vault          => { url => 'https://vault.example.com' },
	);

	my %config = (
		task     => { image => 'genesiscommunity/concourse', version => 'latest' },
		registry => {},
	);
	$config{task_library} = $o{task_library} if $o{task_library};
	$config{errands}      = $o{errands}      if $o{errands};

	my %node = (
		alias               => $alias,
		stage_name          => $env,
		genesis_env         => $env,
		auto                => $o{auto} // 0,
		type                => 'deployment',
		require_pr          => 0,
		manual              => 0,
		redeploy            => '',
		redeploy_cron_start => '',
		redeploy_cron_stop  => '',
		status_signal       => '',
		signal_prefix       => '',
		bosh_parent         => '',
		bosh_upgrade_lock   => 1,
	);

	return Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'test-pipeline', deployment_type => 'deployment' },
		branches     => { control => 'main' },
		integrations => \%integrations,
		targets      => {
			$env => {
				type       => 'bosh-director',
				connection => {
					url     => 'https://bosh.example.com:25555',
					ca_cert => 'fake-ca',
					auth    => { client_id => 'admin', client_secret => 'secret' },
				},
			},
		},
		workflows    => {
			default => {
				name  => 'default',
				type  => 'deployment',
				graph => {
					nodes => { $env => \%node },
					edges => $o{edges} || [],
				},
			},
		},
		configuration => \%config,
	);
}

sub _describe {
	my ($ast) = @_;
	Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast)->describe();
}

sub _find_resource {
	my ($pipeline, $name) = @_;
	my ($r) = grep { $_->{name} eq $name } @{$pipeline->{resources}};
	return $r;
}

sub _find_job {
	my ($pipeline, $name) = @_;
	my ($j) = grep { $_->{name} eq $name } @{$pipeline->{jobs}};
	return $j;
}

sub _deploy_gets {
	my ($pipeline, $job_name) = @_;
	my $job = _find_job($pipeline, $job_name) or return ();
	my $do  = ($job->{plan}[0] || {})->{do} || [];
	my ($parallel) = grep { ref $_ eq 'HASH' && $_->{in_parallel} } @$do;
	return $parallel ? @{$parallel->{in_parallel}} : ();
}

sub _errand_steps {
	my ($pipeline, $job_name) = @_;
	my $job = _find_job($pipeline, $job_name) or return ();
	my $do  = ($job->{plan}[0] || {})->{do} || [];
	return grep { ref $_ eq 'HASH' && ($_->{task} || '') =~ /-errand$/ } @$do;
}

sub _task_inputs {
	my ($pipeline, $job_name) = @_;
	my $job = _find_job($pipeline, $job_name) or return ();
	my $do  = ($job->{plan}[0] || {})->{do} || [];
	# Find the deploy task step (has 'task' key and 'config' with inputs)
	my ($deploy) = grep { ref $_ eq 'HASH' && $_->{task} && $_->{config} } @$do;
	return $deploy ? @{($deploy->{config} || {})->{inputs} || []} : ();
}

sub _task_params {
	my ($pipeline, $job_name) = @_;
	my $job = _find_job($pipeline, $job_name) or return ();
	my $do  = ($job->{plan}[0] || {})->{do} || [];
	my ($deploy) = grep { ref $_ eq 'HASH' && $_->{task} && $_->{config} } @$do;
	return $deploy ? %{($deploy->{config} || {})->{params} || {}} : ();
}

# =========================================================================
# 1. No task library: pipeline unchanged
# =========================================================================
subtest 'No task_library config: no tasks resource, no library input' => sub {
	my $ast = _ast_for();
	my $pl  = _describe($ast);

	ok(!_find_resource($pl, 'tasks'),
		'No tasks resource without task_library config');

	my @gets = _deploy_gets($pl, 'sandbox-deployment');
	ok(!grep({ ref $_ eq 'HASH' && ($_->{get} || '') eq 'tasks' } @gets),
		'No tasks get step in deploy job without task_library config');

	my @inputs = _task_inputs($pl, 'sandbox-deployment');
	ok(!grep({ ref $_ eq 'HASH' && ($_->{name} || '') eq 'tasks' } @inputs),
		'No tasks input in task config without task_library config');
};

# =========================================================================
# 2. Basic task library: resource declared, get step added, input added
# =========================================================================
subtest 'task_library configured: tasks resource emitted' => sub {
	my $ast = _ast_for(task_library => {
		uri    => 'https://github.com/org/pipeline-tasks.git',
		branch => 'main',
	});
	my $pl = _describe($ast);

	my $r = _find_resource($pl, 'tasks');
	ok($r, 'tasks git resource present');
	is($r->{type}, 'git',                                      'type is git');
	is($r->{source}{uri}, 'https://github.com/org/pipeline-tasks.git', 'uri correct');
	is($r->{source}{branch}, 'main',                           'branch correct');
	is($r->{icon}, 'source-repository',                        'icon set');
};

subtest 'task_library: deploy job fetches tasks resource' => sub {
	my $ast = _ast_for(task_library => {
		uri => 'https://github.com/org/pipeline-tasks.git',
	});
	my $pl   = _describe($ast);
	my @gets = _deploy_gets($pl, 'sandbox-deployment');

	my ($tl_get) = grep { ref $_ eq 'HASH' && ($_->{get} || '') eq 'tasks' } @gets;
	ok($tl_get,                       'tasks get step present in deploy job');
	ok(!$tl_get->{trigger},           'tasks get does not trigger');
};

subtest 'task_library: task config receives tasks input' => sub {
	my $ast    = _ast_for(task_library => {
		uri => 'https://github.com/org/pipeline-tasks.git',
	});
	my $pl     = _describe($ast);
	my @inputs = _task_inputs($pl, 'sandbox-deployment');

	my ($tl_in) = grep { ref $_ eq 'HASH' && ($_->{name} || '') eq 'tasks' } @inputs;
	ok($tl_in, 'tasks input present in task config');
};

# =========================================================================
# 3. Custom resource_name
# =========================================================================
subtest 'task_library: custom resource_name used throughout' => sub {
	my $ast = _ast_for(task_library => {
		uri           => 'https://github.com/org/tasks.git',
		resource_name => 'pipeline-tasks',
	});
	my $pl = _describe($ast);

	ok(_find_resource($pl, 'pipeline-tasks'), 'resource uses custom name');
	ok(!_find_resource($pl, 'tasks'),         'default name not created');

	my @gets = _deploy_gets($pl, 'sandbox-deployment');
	my ($tl_get) = grep { ref $_ eq 'HASH' && ($_->{get} || '') eq 'pipeline-tasks' } @gets;
	ok($tl_get, 'deploy job fetches pipeline-tasks');

	my @inputs = _task_inputs($pl, 'sandbox-deployment');
	my ($tl_in) = grep { ref $_ eq 'HASH' && ($_->{name} || '') eq 'pipeline-tasks' } @inputs;
	ok($tl_in, 'task config input uses pipeline-tasks');
};

# =========================================================================
# 4. Path resolution: GENESIS_TASK_LIBRARY_PATH param
# =========================================================================
subtest 'task_library without path: GENESIS_TASK_LIBRARY_PATH = resource_name' => sub {
	my $ast = _ast_for(task_library => {
		uri => 'https://github.com/org/tasks.git',
	});
	my $pl = _describe($ast);
	my %p  = _task_params($pl, 'sandbox-deployment');
	is($p{GENESIS_TASK_LIBRARY_PATH}, 'tasks',
		'GENESIS_TASK_LIBRARY_PATH is resource_name when no path set');
};

subtest 'task_library with path: GENESIS_TASK_LIBRARY_PATH = resource_name/path' => sub {
	my $ast = _ast_for(task_library => {
		uri  => 'https://github.com/org/tasks.git',
		path => 'tasks',
	});
	my $pl = _describe($ast);
	my %p  = _task_params($pl, 'sandbox-deployment');
	is($p{GENESIS_TASK_LIBRARY_PATH}, 'tasks/tasks',
		'GENESIS_TASK_LIBRARY_PATH includes subdirectory');
};

subtest 'task_library with custom resource_name and path' => sub {
	my $ast = _ast_for(task_library => {
		uri           => 'https://github.com/org/tasks.git',
		resource_name => 'lib',
		path          => 'ci/tasks',
	});
	my $pl = _describe($ast);
	my %p  = _task_params($pl, 'sandbox-deployment');
	is($p{GENESIS_TASK_LIBRARY_PATH}, 'lib/ci/tasks',
		'GENESIS_TASK_LIBRARY_PATH = resource_name/path');
};

# =========================================================================
# 5. Auth passthrough for private repos
# =========================================================================
subtest 'task_library: ssh-key auth passed to git resource source' => sub {
	my $ast = _ast_for(task_library => {
		uri  => 'git@github.com:org/tasks.git',
		auth => {
			type        => 'ssh-key',
			private_key => { secret_ref => 'task-library-key' },
		},
	});
	my $pl = _describe($ast);
	my $r  = _find_resource($pl, 'tasks');

	ok($r, 'tasks resource present');
	is($r->{source}{private_key}, '((task-library-key))',
		'private_key unwrapped from secret_ref');
	ok(!exists $r->{source}{username}, 'no username for ssh-key');
};

subtest 'task_library: token auth passed to git resource source' => sub {
	my $ast = _ast_for(task_library => {
		uri  => 'https://github.com/org/tasks.git',
		auth => {
			type     => 'token',
			password => { secret_ref => 'library-token' },
		},
	});
	my $pl = _describe($ast);
	my $r  = _find_resource($pl, 'tasks');

	ok($r, 'tasks resource present');
	is($r->{source}{username}, 'x-oauth-basic',      'default username for token');
	is($r->{source}{password}, '((library-token))',  'password unwrapped');
};

subtest 'task_library: token auth with explicit username' => sub {
	my $ast = _ast_for(task_library => {
		uri  => 'https://github.com/org/tasks.git',
		auth => {
			type     => 'token',
			username => 'my-bot',
			password => '((library-pass))',
		},
	});
	my $pl = _describe($ast);
	my $r  = _find_resource($pl, 'tasks');

	is($r->{source}{username}, 'my-bot',          'explicit username preserved');
	is($r->{source}{password}, '((library-pass))', 'password scalar preserved');
};

# =========================================================================
# 6. AC3 — Jobs reference library tasks by name (path resolution)
# =========================================================================
subtest 'No task_library: errand uses inline config' => sub {
	my $ast = _ast_for(errands => ['smoke-tests']);
	my $pl  = _describe($ast);
	my ($step) = _errand_steps($pl, 'sandbox-deployment');

	ok($step,                           'errand step present');
	ok(exists $step->{config},          'inline config used without task_library');
	ok(!exists $step->{file},           'no file reference without task_library');
};

subtest 'task_library: errand uses file reference resolved from library' => sub {
	my $ast = _ast_for(
		errands      => ['smoke-tests'],
		task_library => { uri => 'https://github.com/org/tasks.git' },
	);
	my $pl   = _describe($ast);
	my ($step) = _errand_steps($pl, 'sandbox-deployment');

	ok($step,                           'errand step present');
	is($step->{file}, 'tasks/smoke-tests.yml',
		'file reference is resource_name/errand-name.yml');
	ok(!exists $step->{config},         'no inline config when library configured');
};

subtest 'task_library with path: errand file includes subdirectory' => sub {
	my $ast = _ast_for(
		errands      => ['acceptance-tests'],
		task_library => { uri => 'https://github.com/org/tasks.git', path => 'tasks' },
	);
	my $pl   = _describe($ast);
	my ($step) = _errand_steps($pl, 'sandbox-deployment');

	is($step->{file}, 'tasks/tasks/acceptance-tests.yml',
		'file path is resource_name/path/errand-name.yml');
};

subtest 'task_library with custom resource_name: errand file uses resource_name' => sub {
	my $ast = _ast_for(
		errands      => ['validate'],
		task_library => {
			uri           => 'https://github.com/org/tasks.git',
			resource_name => 'pipeline-tasks',
			path          => 'errands',
		},
	);
	my $pl   = _describe($ast);
	my ($step) = _errand_steps($pl, 'sandbox-deployment');

	is($step->{file}, 'pipeline-tasks/errands/validate.yml',
		'file path uses custom resource_name and path');
};

subtest 'task_library: multiple errands each get their own file reference' => sub {
	my $ast = _ast_for(
		errands      => ['smoke-tests', 'acceptance-tests'],
		task_library => { uri => 'https://github.com/org/tasks.git', path => 'tasks' },
	);
	my $pl    = _describe($ast);
	my @steps = _errand_steps($pl, 'sandbox-deployment');

	is(scalar @steps, 2, 'two errand steps emitted');
	my %files = map { $_->{task} => $_->{file} } @steps;
	is($files{'smoke-tests-errand'},      'tasks/tasks/smoke-tests.yml');
	is($files{'acceptance-tests-errand'}, 'tasks/tasks/acceptance-tests.yml');
};

done_testing;
