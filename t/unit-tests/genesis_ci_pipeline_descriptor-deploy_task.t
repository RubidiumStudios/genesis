#!perl
#
# Stage 1 of the branch-based pipeline emitter: a deploy job is one task
# that runs the plain Genesis CLI against an env branch.  No cache, no
# commit-back, no shim command.
#
use strict;
use warnings;

use lib 'lib';
use lib 't';
use Test::More;
use Test::Deep;

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';
$ENV{NOCOLOR}         = 1;

use_ok 'Genesis::CI::Compiler::AST';
use_ok 'Genesis::CI::Compiler::PipelineDescriptor';

my $UPSTREAM = 'acme-vsphere-west-1-mgmt';
my $ENV_NAME = 'acme-vsphere-west-1-lab';

# =========================================================================
# Helpers
# =========================================================================

sub _node {
	my (%o) = @_;
	return {
		alias               => $o{env},
		stage_name          => $o{env},
		genesis_env         => $o{env},
		branch              => "$o{env}/bosh",
		auto                => $o{auto} // 1,
		type                => 'bosh',
		require_pr          => 0,
		manual              => $o{manual} // 0,
		redeploy            => '',
		redeploy_cron_start => '',
		redeploy_cron_stop  => '',
		status_signal       => '',
		signal_prefix       => '',
		bosh_parent         => $o{bosh_parent} // '',
		# Stage 1 is lock-free; Stage 3 restores this to 1 and adds the
		# locker integration the descriptor then requires.
		bosh_upgrade_lock   => 0,
	};
}

sub _ast {
	my (%o) = @_;

	return Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'bosh', deployment_type => 'bosh' },
		branches     => { control => 'control' },
		integrations => {
			source_control => {
				provider   => 'github',
				repository => 'acme/bosh',
				($o{root} ? (root => $o{root}) : ()),
			},
			vault => { url => 'https://vault.example.com' },
		},
		targets   => {},
		workflows => {
			default => {
				name  => 'default',
				type  => 'bosh',
				graph => {
					nodes => {
						$UPSTREAM => _node(env => $UPSTREAM, manual => 1, auto => 0),
						$ENV_NAME => _node(env => $ENV_NAME, bosh_parent => $UPSTREAM),
					},
					edges => [{ from => $UPSTREAM, to => $ENV_NAME }],
				},
			},
		},
		configuration => {
			task     => { image => 'genesiscommunity/concourse', version => 'latest' },
			registry => {},
		},
	);
}

sub _describe {
	Genesis::CI::Compiler::PipelineDescriptor->new(ast => $_[0])->describe();
}

sub _job {
	my ($pipeline, $name) = @_;
	my ($j) = grep { $_->{name} eq $name } @{$pipeline->{jobs}};
	return $j;
}

sub _resource {
	my ($pipeline, $name) = @_;
	my ($r) = grep { $_->{name} eq $name } @{$pipeline->{resources}};
	return $r;
}

sub _plan_steps {
	my ($pipeline, $job_name) = @_;
	my $job = _job($pipeline, $job_name) or return ();
	return @{ ($job->{plan}[0] || {})->{do} || [] };
}

sub _deploy_step {
	my ($pipeline, $job_name) = @_;
	my ($step) = grep { ref $_ eq 'HASH' && ($_->{task} || '') eq 'bosh-deploy' }
		_plan_steps($pipeline, $job_name);
	return $step;
}

# =========================================================================
# Deploy task invokes the plain Genesis CLI
# =========================================================================

subtest "deploy task runs the root's own genesis <env> deploy -SFy" => sub {
	plan tests => 4;

	my $step = _deploy_step(_describe(_ast()), "deploy-$ENV_NAME");
	ok $step, 'deploy job has a bosh-deploy task';

	is $step->{config}{run}{path}, '.genesis/bin/genesis',
		'task runs the embedded genesis (contract e7)';
	is $step->{config}{run}{dir}, "$ENV_NAME-branch",
		'from the branch input, the root being the clone top (contract e6)';
	is_deeply $step->{config}{run}{args}, [$ENV_NAME, 'deploy', '-SFy'],
		'task invokes the env-first deploy form';
};

subtest 'a source_control root moves the working directory, not the path' => sub {
	plan tests => 2;

	my $step = _deploy_step(_describe(_ast(root => 'bosh')), "deploy-$ENV_NAME");
	is $step->{config}{run}{dir}, "$ENV_NAME-branch/bosh", 'run.dir is the root in the input';
	is $step->{config}{run}{path}, '.genesis/bin/genesis', 'run.path stays relative to it';
};

# =========================================================================
# Task params
# =========================================================================

subtest 'shim-era task params are gone' => sub {
	# GENESIS_HONOR_ENV is deliberately NOT in this list: it has live
	# consumers outside the retired shim.  See the subtest below.
	# BOSH_NON_INTERACTIVE is dropped because Genesis::Env sets it itself,
	# and PREVIOUS_ENV because its only readers resolve .genesis/cached
	# paths, which the branch model removes.  CURRENT_ENV and GIT_BRANCH
	# have no reader in the plain CLI (contract f7).
	my @retired = qw(
		WORKING_DIR OUT_DIR CACHE_DIR PREVIOUS_ENV
		GIT_GENESIS_ROOT BOSH_NON_INTERACTIVE
		CURRENT_ENV GIT_BRANCH
	);
	plan tests => scalar @retired;

	my $params = _deploy_step(_describe(_ast(root => 'bosh')), "deploy-$ENV_NAME")
		->{config}{params};

	ok !exists $params->{$_}, "$_ is no longer passed to the deploy task"
		for @retired;
};

subtest 'params the plain CLI still consumes are kept' => sub {
	plan tests => 2;

	my $params = _deploy_step(_describe(_ast()), "deploy-$ENV_NAME")
		->{config}{params};

	is $params->{VAULT_ADDR}, 'https://vault.example.com',
		'VAULT_ADDR survives for attach auto-provision';
	ok exists $params->{CI_NO_REDACT},          'CI_NO_REDACT survives';
};

subtest 'GENESIS_HONOR_ENV is not emitted, GENESIS_PIPELINE_TASK replacing it (T410)' => sub {
	plan tests => 1;

	# D27 replaced it with GENESIS_PIPELINE_TASK, and its last consumer,
	# Service::BOSH keeping HTTPS_PROXY, now reads that too, so a proxied
	# network's pipeline still reaches its director (service_bosh-base.t).
	my $params = _deploy_step(_describe(_ast()), "deploy-$ENV_NAME")
		->{config}{params};

	ok !exists $params->{GENESIS_HONOR_ENV},
		'GENESIS_HONOR_ENV is no longer passed to the deploy task';
};

subtest 'an errand task says it is the pipeline too (T410)' => sub {
	plan tests => 2;

	# D27: the emitter sets GENESIS_PIPELINE_TASK in every task.
	my $ast = _ast();
	my $params = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast)
		->_errand_config($ast, $ENV_NAME, 'smoke-tests', 'git', 'git')->{params};
	is $params->{GENESIS_PIPELINE_TASK}, 1, 'GENESIS_PIPELINE_TASK is set';
	ok !exists $params->{GENESIS_HONOR_ENV}, 'and GENESIS_HONOR_ENV is not';
};

subtest 'the task says it is the pipeline running, not an operator' => sub {
	plan tests => 1;

	# Every pre-flight gate a pipeline's own job has to pass reads
	# GENESIS_PIPELINE_TASK: the provider gate lets the job deploy what it
	# refuses at a terminal, and the disowned-pipeline refusal tells a job
	# from an operator mid-teardown.  Nothing else in the product sets it,
	# so without it here every deploy job of a compiled pipeline refuses at
	# NOPERM, telling the pipeline that the pipeline owns the deploy.
	#
	# It is set in the task configuration every genesis task shares, so the
	# notification job's show-changes task carries it as well.  This AST
	# emits no such job, which is why only the deploy task is read.
	my $params = _deploy_step(_describe(_ast()), "deploy-$ENV_NAME")
		->{config}{params};

	ok $params->{GENESIS_PIPELINE_TASK},
		'GENESIS_PIPELINE_TASK is passed to the deploy task';
};

# =========================================================================
# Cache and commit-back are gone
# =========================================================================

subtest 'deploy task does not commit the repo back' => sub {
	plan tests => 1;

	my $step = _deploy_step(_describe(_ast()), "deploy-$ENV_NAME");
	ok !exists $step->{ensure},
		'no ensure/put git -- exodus carries deploy state now';
};

subtest 'no cache task is emitted' => sub {
	plan tests => 1;

	my @cache = grep { ref $_ eq 'HASH' && ($_->{task} || '') eq 'generate-cache' }
		_plan_steps(_describe(_ast()), "deploy-$ENV_NAME");
	is scalar(@cache), 0, 'generate-cache task is gone';
};

subtest 'no cache resource is emitted' => sub {
	plan tests => 2;

	my $pipeline = _describe(_ast());
	ok !_resource($pipeline, "$ENV_NAME-cache"),
		'downstream env has no cache resource';
	ok !_resource($pipeline, "$UPSTREAM-cache"),
		'upstream env has no cache resource';
};

# =========================================================================
# Env-branch git resource
# =========================================================================

subtest 'each env watches its own branch, not filtered control paths' => sub {
	plan tests => 4;

	my $pipeline = _describe(_ast());
	my $res = _resource($pipeline, "$ENV_NAME-branch");

	ok $res, "$ENV_NAME-branch resource is emitted";
	is $res->{type}, 'git', 'it is a git resource';
	is $res->{source}{branch}, "$ENV_NAME/bosh", "it watches the branch the node's builder named";
	ok !exists $res->{source}{paths},
		'no path filtering -- the branch itself is the trigger';
};

subtest 'the env branch filters no paths' => sub {
	plan tests => 2;

	# No emitted deploy writes the branch it triggers on (contract a4, d7),
	# so there is no feedback loop for a filter to break.
	my $res = _resource(_describe(_ast()), "$ENV_NAME-branch");
	ok !exists $res->{source}{ignore_paths}, 'the env branch ignores no paths';

	my $rooted = _resource(_describe(_ast(root => 'bosh')), "$ENV_NAME-branch");
	ok !exists $rooted->{source}{ignore_paths}, 'nor under a source_control root';
};

subtest 'the old path-filtered changes resource is gone' => sub {
	plan tests => 1;

	my $pipeline = _describe(_ast());
	ok !_resource($pipeline, "$ENV_NAME-changes"),
		'<env>-changes resource is replaced by the env branch resource';
};

subtest 'the control branch is not a stage 1 deploy input' => sub {
	plan tests => 3;

	# The shared control-branch resource existed to supply the checkout the
	# shim binary ran from.  With genesis resolved from PATH and repo content
	# coming from the env branch, nothing in a stage 1 deploy job consumes it,
	# so it is not emitted until stage 2 needs it for propagation.
	my $pipeline = _describe(_ast());

	ok !_resource($pipeline, 'git'),
		'the bare git resource is gone';
	ok !_resource($pipeline, 'control-branch'),
		'control-branch is deferred to stage 2, not carried unused';

	my ($parallel) = grep { ref $_ eq 'HASH' && $_->{in_parallel} }
		_plan_steps($pipeline, "deploy-$ENV_NAME");
	my @gets = map { $_->{get} // () } @{ $parallel->{in_parallel} || [] };
	is_deeply [sort @gets], ["$ENV_NAME-branch"],
		'the deploy job gets exactly one resource: its own branch';
};

done_testing;
