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

# Build a minimal AST with one env and configurable signal/notification/redeploy attributes.
sub _ast_for {
	my (%opts) = @_;

	my $env           = $opts{env}           || 'sandbox';
	my $alias         = $opts{alias}         || $env;
	my $redeploy      = $opts{redeploy}      || '';
	my $status_signal = $opts{status_signal} // '';
	my $signal_prefix = $opts{signal_prefix} || '';
	my $with_locker   = $opts{with_locker}   // 0;
	my $create_env    = $opts{create_env}    // 0;
	my $signal_cfg    = $opts{signal_cfg};     # global status_signal config hashref

	my $target_type = $create_env ? 'bosh-create-env' : 'bosh-director';
	my %target = (type => $target_type);
	unless ($create_env) {
		$target{connection} = {
			url     => 'https://bosh.example.com:25555',
			ca_cert => 'fake-ca',
			auth    => { client_id => 'admin', client_secret => 'secret' },
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
	if (my $notif = $opts{notifications}) {
		$integrations{notifications} = $notif;
	}

	my %config = (
		task     => { image => 'genesiscommunity/concourse', version => 'latest' },
		registry => {},
	);
	$config{status_signal} = $signal_cfg if $signal_cfg;

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
							redeploy_cron_start => '',
							redeploy_cron_stop  => '',
							status_signal       => $status_signal,
							signal_prefix       => $signal_prefix,
						},
					},
					edges => [],
				},
			},
		},
		configuration => \%config,
	);
}

sub _describe {
	my ($ast) = @_;
	my $d = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);
	return $d->describe();
}

# Extract the plan's do-block from a job's plan[0]
sub _do_block {
	my ($job) = @_;
	my $step = $job->{plan}[0] or return [];
	return $step->{do} || [];
}

# Find the in_parallel step within a do-block
sub _parallel_gets {
	my ($do) = @_;
	my ($par) = grep { ref $_ eq 'HASH' && exists $_->{in_parallel} } @$do;
	return $par ? $par->{in_parallel} : [];
}

# =========================================================================
# 1. shuttle resource_type emitted when status_signal is globally configured
# =========================================================================
subtest 'shuttle resource_type emitted when status_signal configured' => sub {
	my $ast = _ast_for(
		env        => 'sandbox',
		signal_cfg => { backend => 'file', path => '/tmp/signals' },
		status_signal => '1',
	);
	my $pipeline = _describe($ast);

	my @shuttle = grep { ($_->{name} || '') eq 'shuttle' } @{$pipeline->{resource_types}};
	is scalar @shuttle, 1, 'one shuttle resource_type entry';
	is $shuttle[0]{type}, 'registry-image', 'shuttle type is registry-image';
	like $shuttle[0]{source}{repository}, qr/shuttle/, 'repository contains "shuttle"';
};

# =========================================================================
# 2. No shuttle resource_type when status_signal is not configured globally
# =========================================================================
subtest 'No shuttle resource_type when status_signal not configured' => sub {
	my $ast      = _ast_for(env => 'sandbox');
	my $pipeline = _describe($ast);

	my @shuttle = grep { ($_->{name} || '') eq 'shuttle' } @{$pipeline->{resource_types}};
	is scalar @shuttle, 0, 'no shuttle resource_type when signal not configured';
};

# =========================================================================
# 3. File backend: signal resource emitted with correct source
# =========================================================================
subtest 'File backend: signal resource has correct source' => sub {
	my $ast = _ast_for(
		env        => 'sandbox',
		signal_cfg => { backend => 'file', path => '/tmp/genesis-signals' },
		status_signal => '1',
	);
	my $pipeline = _describe($ast);

	my ($res) = grep { ($_->{name} || '') eq 'sandbox-signal' } @{$pipeline->{resources}};
	ok $res, 'sandbox-signal resource emitted';
	is $res->{type}, 'shuttle', 'resource type is shuttle';
	is $res->{source}{backend}, 'file', 'source.backend = file';
	like $res->{source}{path}, qr{/tmp/genesis-signals}, 'source.path contains base path';
};

# =========================================================================
# 4. S3 backend: signal resource has correct source fields
# =========================================================================
subtest 'S3 backend: signal resource has bucket/region/credentials' => sub {
	my $ast = _ast_for(
		env        => 'sandbox',
		signal_cfg => {
			backend           => 's3',
			bucket            => 'my-signals',
			region            => 'eu-west-1',
			access_key_id     => 'AKID',
			secret_access_key => 'SECRET',
		},
		status_signal => '1',
	);
	my $pipeline = _describe($ast);

	my ($res) = grep { ($_->{name} || '') eq 'sandbox-signal' } @{$pipeline->{resources}};
	ok $res, 'sandbox-signal resource emitted';
	is $res->{source}{backend},            's3',           'source.backend = s3';
	is $res->{source}{bucket},             'my-signals',   'source.bucket correct';
	is $res->{source}{region},             'eu-west-1',    'source.region correct';
	is $res->{source}{access_key_id},      'AKID',         'source.access_key_id correct';
	is $res->{source}{secret_access_key},  'SECRET',       'source.secret_access_key correct';
};

# =========================================================================
# 5. GCS backend: signal resource has bucket and json_key
# =========================================================================
subtest 'GCS backend: signal resource has bucket and json_key' => sub {
	my $ast = _ast_for(
		env        => 'sandbox',
		signal_cfg => {
			backend  => 'gcs',
			bucket   => 'gcs-signals',
			json_key => 'gcs-service-account-json',
		},
		status_signal => '1',
	);
	my $pipeline = _describe($ast);

	my ($res) = grep { ($_->{name} || '') eq 'sandbox-signal' } @{$pipeline->{resources}};
	ok $res, 'sandbox-signal resource emitted';
	is $res->{source}{backend},  'gcs',                      'source.backend = gcs';
	is $res->{source}{bucket},   'gcs-signals',              'source.bucket correct';
	is $res->{source}{json_key}, 'gcs-service-account-json', 'source.json_key correct';
};

# =========================================================================
# 6. Per-env disable: status_signal=false suppresses signal for that env
# =========================================================================
subtest 'Per-env disable: status_signal=false suppresses signal resource' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'test-pipeline', deployment_type => 'deployment' },
		branches     => { control => 'main' },
		integrations => {
			source_control => { provider => 'github', repository => 'org/repo' },
			vault          => { url => 'https://vault.example.com' },
		},
		targets => {
			sandbox => { type => 'bosh-director', connection => {
				url => 'https://bosh.sb', ca_cert => 'c',
				auth => { client_id => 'u', client_secret => 's' } } },
			prod    => { type => 'bosh-director', connection => {
				url => 'https://bosh.pd', ca_cert => 'c',
				auth => { client_id => 'u', client_secret => 's' } } },
		},
		workflows => {
			default => {
				name  => 'default',
				type  => 'deployment',
				graph => {
					nodes => {
						sandbox => {
							alias => 'sandbox', stage_name => 'sandbox',
							genesis_env => 'sandbox', auto => 0, type => 'deployment',
							require_pr => 0, manual => 0,
							redeploy => '', redeploy_cron_start => '', redeploy_cron_stop => '',
							status_signal => '1', signal_prefix => '',
						},
						prod => {
							alias => 'prod', stage_name => 'prod',
							genesis_env => 'prod', auto => 0, type => 'deployment',
							require_pr => 0, manual => 0,
							redeploy => '', redeploy_cron_start => '', redeploy_cron_stop => '',
							status_signal => '0', signal_prefix => '',
						},
					},
					edges => [{ from => 'sandbox', to => 'prod' }],
				},
			},
		},
		configuration => {
			task        => { image => 'genesiscommunity/concourse', version => 'latest' },
			registry    => {},
			status_signal => { backend => 'file', path => '/tmp/signals' },
		},
	);
	my $pipeline = _describe($ast);

	my ($sb_res) = grep { ($_->{name} || '') eq 'sandbox-signal' } @{$pipeline->{resources}};
	ok $sb_res, 'sandbox-signal resource emitted (enabled)';

	my ($pd_res) = grep { ($_->{name} || '') eq 'prod-signal' } @{$pipeline->{resources}};
	ok !$pd_res, 'prod-signal resource NOT emitted (disabled per-env)';
};

# =========================================================================
# 7. Prefix: per-env signal_prefix overrides global prefix
# =========================================================================
subtest 'Per-env signal_prefix overrides global prefix in resource source' => sub {
	my $ast = _ast_for(
		env           => 'sandbox',
		signal_cfg    => { backend => 'file', path => '/tmp/sig', prefix => 'mypipeline' },
		status_signal => '1',
		signal_prefix => 'custom-prefix',
	);
	my $pipeline = _describe($ast);

	my ($res) = grep { ($_->{name} || '') eq 'sandbox-signal' } @{$pipeline->{resources}};
	ok $res, 'sandbox-signal resource emitted';
	is $res->{source}{prefix}, 'custom-prefix', 'per-env signal_prefix used instead of global';
};

# =========================================================================
# 8. All four outcome hooks emitted when signal is configured
# =========================================================================
subtest 'All four outcome hooks emitted when signal configured' => sub {
	my $ast = _ast_for(
		env        => 'sandbox',
		signal_cfg => { backend => 'file' },
		status_signal => '1',
	);
	my $pipeline = _describe($ast);

	my ($job) = grep { $_->{name} eq 'sandbox-deployment' } @{$pipeline->{jobs}};
	ok $job, 'sandbox-deployment job present';

	my $plan_step = $job->{plan}[0];
	for my $hook (qw(on_success on_failure on_abort on_error)) {
		ok exists $plan_step->{$hook}, "$hook hook present";
		my $h = $plan_step->{$hook};
		if (ref $h eq 'HASH' && $h->{put}) {
			is $h->{put}, 'sandbox-signal', "$hook put targets sandbox-signal";
			(my $outcome = $hook) =~ s/^on_//;
			is $h->{params}{status}, $outcome, "$hook params.status = $outcome";
		}
	}
};

# =========================================================================
# 9. Notification + signal combined into in_parallel
# =========================================================================
subtest 'Notification and signal combined into in_parallel in hooks' => sub {
	my $ast = _ast_for(
		env        => 'sandbox',
		signal_cfg => { backend => 'file' },
		status_signal => '1',
		notifications => [
			{ type => 'slack', webhook => 'https://hooks.slack.com/services/test' },
		],
	);
	my $pipeline = _describe($ast);

	my ($job) = grep { $_->{name} eq 'sandbox-deployment' } @{$pipeline->{jobs}};
	ok $job, 'sandbox-deployment job present';

	my $plan_step = $job->{plan}[0];

	# on_success: notification + signal → in_parallel
	my $success = $plan_step->{on_success};
	ok $success, 'on_success hook present';
	ok exists $success->{in_parallel}, 'on_success uses in_parallel when both present';
	my @sp = @{$success->{in_parallel}};
	my @slack_steps = grep { ref $_ eq 'HASH' && ($_->{put} || '') eq 'slack' } @sp;
	my @signal_steps = grep { ref $_ eq 'HASH' && ($_->{put} || '') eq 'sandbox-signal' } @sp;
	is scalar @slack_steps,  1, 'one slack step in on_success in_parallel';
	is scalar @signal_steps, 1, 'one signal step in on_success in_parallel';

	# on_failure: notification + signal → in_parallel
	my $failure = $plan_step->{on_failure};
	ok $failure, 'on_failure hook present';
	ok exists $failure->{in_parallel}, 'on_failure uses in_parallel when both present';

	# on_abort: signal only (no notification) → direct put, not in_parallel
	my $abort = $plan_step->{on_abort};
	ok $abort, 'on_abort hook present';
	ok !exists $abort->{in_parallel}, 'on_abort is a direct put (no notification)';
	is $abort->{put}, 'sandbox-signal', 'on_abort put targets sandbox-signal';

	# on_error: same as abort
	my $error = $plan_step->{on_error};
	ok $error, 'on_error hook present';
	ok !exists $error->{in_parallel}, 'on_error is a direct put (no notification)';
};

# =========================================================================
# 10. No hooks when neither signal nor notifications configured
# =========================================================================
subtest 'No outcome hooks when neither signal nor notifications configured' => sub {
	my $ast      = _ast_for(env => 'sandbox');
	my $pipeline = _describe($ast);

	my ($job) = grep { $_->{name} eq 'sandbox-deployment' } @{$pipeline->{jobs}};
	ok $job, 'sandbox-deployment job present';

	my $plan_step = $job->{plan}[0];
	for my $hook (qw(on_success on_failure on_abort on_error)) {
		ok !exists $plan_step->{$hook}, "no $hook hook when no signal or notifications";
	}
};

# =========================================================================
# 11. Redeploy job also gets all four outcome hooks
# =========================================================================
subtest 'Redeploy job also gets signal outcome hooks' => sub {
	my $ast = _ast_for(
		env           => 'sandbox',
		redeploy      => 'manual',
		signal_cfg    => { backend => 'file' },
		status_signal => '1',
	);
	my $pipeline = _describe($ast);

	my ($job) = grep { $_->{name} eq 'redeploy-sandbox' } @{$pipeline->{jobs}};
	ok $job, 'redeploy-sandbox job present';

	my $plan_step = $job->{plan}[0];
	for my $hook (qw(on_success on_failure on_abort on_error)) {
		ok exists $plan_step->{$hook}, "redeploy job has $hook hook";
	}
};

# =========================================================================
# 12. Signal redeploy trigger: redeploy=signal + signal configured
#     → get sandbox-signal with trigger=true, version={status: success}
# =========================================================================
subtest 'Signal redeploy trigger: gets signal resource with trigger=true' => sub {
	my $ast = _ast_for(
		env           => 'sandbox',
		redeploy      => 'signal',
		signal_cfg    => { backend => 'file' },
		status_signal => '1',
	);
	my $pipeline = _describe($ast);

	my ($job) = grep { $_->{name} eq 'redeploy-sandbox' } @{$pipeline->{jobs}};
	ok $job, 'redeploy-sandbox job emitted';

	my $do   = _do_block($job);
	my $gets = _parallel_gets($do);

	my ($sig_get) = grep { ref $_ eq 'HASH' && ($_->{get} || '') eq 'sandbox-signal' } @$gets;
	ok $sig_get, 'sandbox-signal get step present in redeploy job';
	is $sig_get->{trigger}, 1, 'trigger=true on signal get';
	is_deeply $sig_get->{version}, { status => 'success' },
		'version filter is {status: success}';
};

# =========================================================================
# 13. Signal redeploy without signal configured → no signal get, no trigger
# =========================================================================
subtest 'Signal redeploy without global signal config: no signal get' => sub {
	my $ast = _ast_for(env => 'sandbox', redeploy => 'signal');
	my $pipeline = _describe($ast);

	my ($job) = grep { $_->{name} eq 'redeploy-sandbox' } @{$pipeline->{jobs}};
	ok $job, 'redeploy-sandbox job emitted';

	my $do   = _do_block($job);
	my $gets = _parallel_gets($do);

	my @sig_gets = grep { ref $_ eq 'HASH' && ($_->{get} || '') =~ /signal/ } @$gets;
	is scalar @sig_gets, 0, 'no signal get when global config absent';

	# All gets should have trigger=false (manual-like behaviour)
	for my $g (@$gets) {
		next unless ref $g eq 'HASH' && exists $g->{trigger};
		is $g->{trigger}, 0,
			"$g->{get} has trigger=false when no signal config";
	}
};

# =========================================================================
# 14. ASTBuilder reads status_signal from env files
# =========================================================================
subtest 'ASTBuilder reads status_signal config from env files' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	_write("$tmp/sandbox.yml", <<'YAML');
---
genesis:
  env: sandbox
  pipeline:
    status_signal: s3
    signal_prefix: my-pipeline/sandbox
YAML
	_write("$tmp/prod.yml", <<'YAML');
---
genesis:
  env: prod
  pipeline:
    prior_env: sandbox
    status_signal: false
YAML
	_write("$tmp/staging.yml", <<'YAML');
---
genesis:
  env: staging
  pipeline:
    prior_env: sandbox
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
	my $ast   = $builder->build($parsed, {});
	my $nodes = $ast->workflows->{default}{graph}{nodes};

	is $nodes->{sandbox}{status_signal}, 's3',
		'sandbox: status_signal=s3';
	is $nodes->{sandbox}{signal_prefix},  'my-pipeline/sandbox',
		'sandbox: signal_prefix read correctly';
	is $nodes->{prod}{status_signal}, '0',
		'prod: status_signal=false normalised to 0';
	is $nodes->{staging}{status_signal}, '',
		'staging: no status_signal = empty string';
};

# =========================================================================
# 15. Per-env backend override: env-level status_signal=gcs overrides global file
# =========================================================================
subtest 'Per-env backend: env-level status_signal overrides global backend' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'test-pipeline', deployment_type => 'deployment' },
		branches     => { control => 'main' },
		integrations => {
			source_control => { provider => 'github', repository => 'org/repo' },
			vault          => { url => 'https://vault.example.com' },
		},
		targets => {
			sandbox => { type => 'bosh-director', connection => {
				url => 'https://bosh.sb', ca_cert => 'c',
				auth => { client_id => 'u', client_secret => 's' } } },
		},
		workflows => {
			default => {
				name  => 'default',
				type  => 'deployment',
				graph => {
					nodes => {
						sandbox => {
							alias => 'sandbox', stage_name => 'sandbox',
							genesis_env => 'sandbox', auto => 0, type => 'deployment',
							require_pr => 0, manual => 0,
							redeploy => '', redeploy_cron_start => '', redeploy_cron_stop => '',
							status_signal => 'gcs', signal_prefix => '',
						},
					},
					edges => [],
				},
			},
		},
		configuration => {
			task          => { image => 'genesiscommunity/concourse', version => 'latest' },
			registry      => {},
			status_signal => {
				backend  => 'file',    # global default is file
				bucket   => 'my-gcs-bucket',
				json_key => 'json-sa-key',
			},
		},
	);
	my $pipeline = _describe($ast);

	my ($res) = grep { ($_->{name} || '') eq 'sandbox-signal' } @{$pipeline->{resources}};
	ok $res, 'sandbox-signal resource emitted';
	is $res->{source}{backend}, 'gcs',
		'per-env status_signal=gcs overrides global file backend';
	is $res->{source}{bucket}, 'my-gcs-bucket', 'bucket from global config preserved';
};

done_testing;
