#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use File::Temp qw/tempdir/;
use Test::More;
use Test::Deep;

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';

use_ok 'Genesis::CI::Compiler::AST';
use_ok 'Genesis::CI::Compiler::ASTBuilder';
use_ok 'Genesis::CI::Compiler::PipelineDescriptor';

# =========================================================================
# Helpers
# =========================================================================

sub _write {
	my ($path, $content) = @_;
	open my $fh, '>', $path or die "Cannot write $path: $!";
	print $fh $content;
	close $fh;
}

# Minimal AST with one env and configurable node attributes.
sub _ast_for {
	my (%opts) = @_;

	my $env        = $opts{env}        || 'sandbox';
	my $alias      = $opts{alias}      || $env;
	my $redeploy   = $opts{redeploy}   || '';
	my $cron_start = $opts{cron_start} || '';
	my $cron_stop  = $opts{cron_stop}  || '';
	my $with_locker = $opts{with_locker} // 1;
	my $create_env  = $opts{create_env} // 0;

	my $target_type = $create_env ? 'bosh-create-env' : 'bosh-director';
	my %target = (type => $target_type);
	unless ($create_env) {
		$target{connection} = {
			url       => 'https://bosh.example.com:25555',
			ca_cert   => 'fake-ca',
			auth      => { client_id => 'admin', client_secret => 'secret' },
		};
	}

	my %integrations = (
		source_control => { provider => 'github', repository => 'org/repo' },
		vault          => { url => 'https://vault.example.com' },
	);
	if ($with_locker) {
		$integrations{locker} = {
			url      => 'https://locker.example.com',
			username => 'locker-user',
			password => 'locker-pass',
		};
	}

	return Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'test-pipeline', deployment_type => 'deployment' },
		branches     => { control => 'main' },
		integrations => \%integrations,
		targets      => { $env => \%target },
		workflows    => {
			default => {
				name  => 'default',
				type  => 'deployment',
				graph => {
					nodes => {
						$env => {
							alias               => $alias,
							stage_name          => $env,
							genesis_env         => $env,
							auto                => 0,
							type                => 'deployment',
							require_pr          => 0,
							manual              => 0,
							redeploy            => $redeploy,
							redeploy_cron_start => $cron_start,
							redeploy_cron_stop  => $cron_stop,
						},
					},
					edges => [],
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
	my ($ast) = @_;
	my $d = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);
	return $d->describe();
}

# =========================================================================
# 1. ASTBuilder reads redeploy attributes from env files
# =========================================================================
subtest 'ASTBuilder reads redeploy config from env files' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	_write("$tmp/sandbox.yml", <<'YAML');
---
genesis:
  env: sandbox
  pipeline:
    redeploy: manual
YAML
	_write("$tmp/staging.yml", <<'YAML');
---
genesis:
  env: staging
  pipeline:
    prior_env: sandbox
    redeploy: cron
    redeploy_cron_start: "04:00"
    redeploy_cron_stop:  "05:00"
YAML
	_write("$tmp/prod.yml", <<'YAML');
---
genesis:
  env: prod
  pipeline:
    prior_env: staging
YAML

	my $builder = Genesis::CI::Compiler::ASTBuilder->new(env_dir => $tmp);
	my $parsed  = {
		_source_format => 'multi-file',
		env_dir        => $tmp,
		pipeline       => {},
		targets        => {},
		integrations   => {},
		scripts        => {},
		provider_config => {},
	};
	my $ast = $builder->build($parsed, {});
	my $nodes = $ast->workflows->{default}{graph}{nodes};

	is $nodes->{sandbox}{redeploy},            'manual', 'sandbox: redeploy=manual';
	is $nodes->{sandbox}{redeploy_cron_start}, '',       'sandbox: no cron_start';

	is $nodes->{staging}{redeploy},            'cron',   'staging: redeploy=cron';
	is $nodes->{staging}{redeploy_cron_start}, '04:00',  'staging: cron_start=04:00';
	is $nodes->{staging}{redeploy_cron_stop},  '05:00',  'staging: cron_stop=05:00';

	is $nodes->{prod}{redeploy}, '', 'prod: no redeploy';
};

# =========================================================================
# 2. redeploy: true / truthy shorthand normalises to 'manual'
# =========================================================================
subtest 'ASTBuilder normalises truthy redeploy value to "manual"' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	_write("$tmp/sandbox.yml", <<'YAML');
---
genesis:
  env: sandbox
  pipeline:
    redeploy: true
YAML

	my $builder = Genesis::CI::Compiler::ASTBuilder->new(env_dir => $tmp);
	my $parsed  = {
		_source_format => 'multi-file',
		env_dir        => $tmp,
		pipeline       => {},
		targets        => {},
		integrations   => {},
		scripts        => {},
		provider_config => {},
	};
	my $ast = $builder->build($parsed, {});
	my $nodes = $ast->workflows->{default}{graph}{nodes};

	is $nodes->{sandbox}{redeploy}, 'manual',
		'truthy redeploy normalised to "manual"';
};

# =========================================================================
# 3. No redeploy configured → no redeploy job or group emitted
# =========================================================================
subtest 'No redeploy config: no redeploy job or group emitted' => sub {
	my $ast      = _ast_for(env => 'sandbox', redeploy => '');
	my $pipeline = _describe($ast);

	my @redeploy_jobs = grep { $_->{name} =~ /^redeploy-/ } @{$pipeline->{jobs}};
	is scalar @redeploy_jobs, 0, 'no redeploy jobs emitted';

	my @redeploy_groups = grep { $_->{name} eq 'redeploy' } @{$pipeline->{groups}};
	is scalar @redeploy_groups, 0, 'no redeploy group emitted';
};

# =========================================================================
# 4. Manual trigger mode
# =========================================================================
subtest 'Manual trigger: redeploy job emitted with no auto-trigger resource' => sub {
	my $ast      = _ast_for(env => 'sandbox', redeploy => 'manual', with_locker => 0);
	my $pipeline = _describe($ast);

	# Job is present
	my ($job) = grep { $_->{name} eq 'redeploy-sandbox' } @{$pipeline->{jobs}};
	ok $job, 'redeploy-sandbox job emitted';
	is $job->{serial}, 1, 'job is serial';

	# No cron time resource
	my @cron_res = grep { ($_->{name} || '') =~ /redeploy-cron/ } @{$pipeline->{resources}};
	is scalar @cron_res, 0, 'no cron time resource for manual mode';

	# All gets in plan have trigger=false
	my $plan_step = $job->{plan}[0];
	my $do = $plan_step->{do} || $plan_step;
	my ($parallel) = grep { ref $_ eq 'HASH' && exists $_->{in_parallel} }
		(ref $do eq 'ARRAY' ? @$do : ($do));
	ok $parallel, 'in_parallel step found in plan';
	for my $get (@{$parallel->{in_parallel}}) {
		next unless ref $get eq 'HASH' && exists $get->{trigger};
		is $get->{trigger}, 0,
			"get $get->{get} has trigger=false in manual mode";
	}

	# Group emitted
	my ($group) = grep { $_->{name} eq 'redeploy' } @{$pipeline->{groups}};
	ok $group, 'redeploy group emitted';
	ok grep { $_ eq 'redeploy-sandbox' } @{$group->{jobs}},
		'redeploy group contains redeploy-sandbox';
};

# =========================================================================
# 5. Signal trigger mode (same as manual from pipeline perspective)
# =========================================================================
subtest 'Signal trigger: behaves identically to manual (no auto-trigger)' => sub {
	my $ast      = _ast_for(env => 'sandbox', redeploy => 'signal', with_locker => 0);
	my $pipeline = _describe($ast);

	my ($job) = grep { $_->{name} eq 'redeploy-sandbox' } @{$pipeline->{jobs}};
	ok $job, 'redeploy-sandbox job emitted for signal mode';

	my @cron_res = grep { ($_->{name} || '') =~ /redeploy-cron/ } @{$pipeline->{resources}};
	is scalar @cron_res, 0, 'no cron time resource for signal mode';
};

# =========================================================================
# 6. Cron trigger mode
# =========================================================================
subtest 'Cron trigger: time resource emitted; job gets it with trigger=true' => sub {
	my $ast = _ast_for(
		env        => 'sandbox',
		redeploy   => 'cron',
		cron_start => '04:00',
		cron_stop  => '05:00',
		with_locker => 0,
	);
	my $pipeline = _describe($ast);

	# Time resource
	my ($cron_res) = grep { ($_->{name} || '') eq 'sandbox-redeploy-cron' }
		@{$pipeline->{resources}};
	ok $cron_res, 'sandbox-redeploy-cron time resource emitted';
	is $cron_res->{type},            'time',   'resource type is time';
	is $cron_res->{source}{start},   '04:00',  'source.start correct';
	is $cron_res->{source}{stop},    '05:00',  'source.stop correct';
	is $cron_res->{source}{location},'UTC',    'source.location is UTC';

	# Job
	my ($job) = grep { $_->{name} eq 'redeploy-sandbox' } @{$pipeline->{jobs}};
	ok $job, 'redeploy-sandbox job emitted';

	# Cron get has trigger=true
	my $plan_step = $job->{plan}[0];
	my $do = $plan_step->{do} || $plan_step;
	my ($parallel) = grep { ref $_ eq 'HASH' && exists $_->{in_parallel} }
		(ref $do eq 'ARRAY' ? @$do : ($do));
	ok $parallel, 'in_parallel step found in plan';

	my ($cron_get) = grep { ref $_ eq 'HASH' && ($_->{get} || '') eq 'sandbox-redeploy-cron' }
		@{$parallel->{in_parallel}};
	ok $cron_get,                'cron get step present';
	is $cron_get->{trigger}, 1,  'cron get has trigger=true';
};

# =========================================================================
# 7. Cron trigger defaults (no explicit start/stop)
# =========================================================================
subtest 'Cron trigger: defaults to 04:00-05:00 when no times specified' => sub {
	my $ast = _ast_for(
		env        => 'sandbox',
		redeploy   => 'cron',
		with_locker => 0,
	);
	my $pipeline = _describe($ast);

	my ($cron_res) = grep { ($_->{name} || '') eq 'sandbox-redeploy-cron' }
		@{$pipeline->{resources}};
	ok $cron_res, 'time resource emitted with defaults';
	is $cron_res->{source}{start}, '04:00', 'default start 04:00';
	is $cron_res->{source}{stop},  '05:00', 'default stop 05:00';
};

# =========================================================================
# 8. Dual-lock: redeploy job acquires both locks when locker configured
# =========================================================================
subtest 'Redeploy job acquires bosh-lock and deployment-lock' => sub {
	my $ast      = _ast_for(env => 'sandbox', redeploy => 'manual', with_locker => 1);
	my $pipeline = _describe($ast);

	my ($job) = grep { $_->{name} eq 'redeploy-sandbox' } @{$pipeline->{jobs}};
	ok $job, 'redeploy-sandbox job present';

	my $plan_step = $job->{plan}[0];
	my $do = $plan_step->{do};
	ok $do, 'plan has do block (with locks)';

	my @lock_puts = grep {
		ref $_ eq 'HASH' && $_->{put} && $_->{put} =~ /lock$/
	} @$do;

	my @bosh_locks = grep { $_->{put} eq 'sandbox-bosh-lock' } @lock_puts;
	my @depl_locks = grep { $_->{put} eq 'sandbox-deployment-lock' } @lock_puts;

	is scalar @bosh_locks, 1, 'sandbox-bosh-lock acquired';
	is scalar @depl_locks, 1, 'sandbox-deployment-lock acquired';

	is $bosh_locks[0]{params}{lock_op},   'lock', 'bosh-lock op=lock';
	is $bosh_locks[0]{params}{locked_by}, 'sandbox-redeploy',
		'bosh-lock locked_by=sandbox-redeploy';
	is $depl_locks[0]{params}{locked_by}, 'sandbox-redeploy',
		'deployment-lock locked_by=sandbox-redeploy';

	# ensure block releases locks
	my $ensure = $plan_step->{ensure};
	ok $ensure, 'ensure block present for lock release';
	my @unlock_puts = grep {
		ref $_ eq 'HASH' && $_->{put} && $_->{put} =~ /lock$/
	} @{$ensure->{do} || []};
	is scalar @unlock_puts, 2, '2 unlock steps in ensure';
};

# =========================================================================
# 9. create-env: redeploy skips bosh-lock (no BOSH director to protect)
# =========================================================================
subtest 'Redeploy job skips bosh-lock for create-env targets' => sub {
	my $ast = _ast_for(
		env        => 'sandbox',
		redeploy   => 'manual',
		with_locker => 1,
		create_env  => 1,
	);
	my $pipeline = _describe($ast);

	my ($job) = grep { $_->{name} eq 'redeploy-sandbox' } @{$pipeline->{jobs}};
	ok $job, 'redeploy-sandbox job present for create-env';

	my $plan_step = $job->{plan}[0];
	my $do = $plan_step->{do};

	my @bosh_locks = grep {
		ref $_ eq 'HASH' && ($_->{put} || '') eq 'sandbox-bosh-lock'
	} @$do;
	is scalar @bosh_locks, 0, 'no bosh-lock for create-env';

	my @depl_locks = grep {
		ref $_ eq 'HASH' && ($_->{put} || '') eq 'sandbox-deployment-lock'
	} @$do;
	is scalar @depl_locks, 1, 'deployment-lock still acquired for create-env';
};

# =========================================================================
# 10. Redeploy job uses ci-pipeline-deploy command
# =========================================================================
subtest 'Redeploy task uses ci-pipeline-deploy command' => sub {
	my $ast      = _ast_for(env => 'sandbox', redeploy => 'manual', with_locker => 0);
	my $pipeline = _describe($ast);

	my ($job) = grep { $_->{name} eq 'redeploy-sandbox' } @{$pipeline->{jobs}};
	ok $job, 'redeploy-sandbox job present';

	my $plan_step = $job->{plan}[0];
	my $do = $plan_step->{do};
	my ($task_step) = grep {
		ref $_ eq 'HASH' && ($_->{task} || '') eq 'bosh-redeploy'
	} @$do;
	ok $task_step, 'bosh-redeploy task step found';

	my $args = $task_step->{config}{run}{args};
	ok $args && grep { $_ eq 'ci-pipeline-deploy' } @$args,
		'task runs ci-pipeline-deploy';
};

# =========================================================================
# 11. Redeploy job does NOT appear in workflow deploy group
# =========================================================================
subtest 'Redeploy job does not pollute the main workflow group' => sub {
	my $ast      = _ast_for(env => 'sandbox', redeploy => 'manual', with_locker => 0);
	my $pipeline = _describe($ast);

	my ($main_group) = grep { $_->{name} ne 'redeploy' } @{$pipeline->{groups}};
	ok $main_group, 'main group present';

	my @redeploy_in_main = grep { /^redeploy-/ } @{$main_group->{jobs} || []};
	is scalar @redeploy_in_main, 0,
		'redeploy job not listed in main workflow group';
};

# =========================================================================
# 12. Multiple envs — only envs with redeploy config get redeploy jobs
# =========================================================================
subtest 'Multiple envs: only configured envs get redeploy jobs' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'multi-test', deployment_type => 'deployment' },
		branches     => { control => 'main' },
		integrations => {
			source_control => { provider => 'github', repository => 'org/repo' },
			vault          => { url => 'https://vault.example.com' },
		},
		targets => {
			sandbox  => { type => 'bosh-director', connection => {
				url => 'https://bosh.sb.example.com', ca_cert => 'c',
				auth => { client_id => 'u', client_secret => 's' } } },
			staging  => { type => 'bosh-director', connection => {
				url => 'https://bosh.st.example.com', ca_cert => 'c',
				auth => { client_id => 'u', client_secret => 's' } } },
			prod     => { type => 'bosh-director', connection => {
				url => 'https://bosh.pd.example.com', ca_cert => 'c',
				auth => { client_id => 'u', client_secret => 's' } } },
		},
		workflows => {
			default => {
				name  => 'default',
				type  => 'deployment',
				graph => {
					nodes => {
						sandbox => { alias => 'sandbox', stage_name => 'sandbox',
							auto => 0, type => 'deployment',
							require_pr => 0, manual => 0,
							redeploy => '',    redeploy_cron_start => '', redeploy_cron_stop => '' },
						staging => { alias => 'staging', stage_name => 'staging',
							auto => 0, type => 'deployment',
							require_pr => 0, manual => 0,
							redeploy => 'manual', redeploy_cron_start => '', redeploy_cron_stop => '' },
						prod    => { alias => 'prod', stage_name => 'prod',
							auto => 0, type => 'deployment',
							require_pr => 0, manual => 0,
							redeploy => 'cron',   redeploy_cron_start => '03:00', redeploy_cron_stop => '04:00' },
					},
					edges => [
						{ from => 'sandbox', to => 'staging' },
						{ from => 'staging', to => 'prod' },
					],
				},
			},
		},
		configuration => {
			task     => { image => 'genesiscommunity/concourse', version => 'latest' },
			registry => {},
		},
	);

	my $pipeline = _describe($ast);

	my @redeploy_jobs = grep { $_->{name} =~ /^redeploy-/ } @{$pipeline->{jobs}};
	is scalar @redeploy_jobs, 2, 'only 2 redeploy jobs (staging + prod)';

	my %rj = map { $_->{name} => 1 } @redeploy_jobs;
	ok $rj{'redeploy-staging'}, 'redeploy-staging present';
	ok $rj{'redeploy-prod'},    'redeploy-prod present';
	ok !$rj{'redeploy-sandbox'}, 'no redeploy-sandbox';

	# Cron resource only for prod
	my @cron_res = grep { ($_->{name} || '') =~ /redeploy-cron/ } @{$pipeline->{resources}};
	is scalar @cron_res, 1, 'one cron time resource (for prod only)';
	is $cron_res[0]{name}, 'prod-redeploy-cron', 'cron resource named prod-redeploy-cron';

	# Redeploy group lists both
	my ($rg) = grep { $_->{name} eq 'redeploy' } @{$pipeline->{groups}};
	ok $rg, 'redeploy group emitted';
	is_deeply [sort @{$rg->{jobs}}], ['redeploy-prod', 'redeploy-staging'],
		'redeploy group lists staging and prod';
};

done_testing;
