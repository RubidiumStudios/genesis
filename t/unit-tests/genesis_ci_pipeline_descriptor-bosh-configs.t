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
	$integrations{slack} = $o{slack} if $o{slack};

	my %config = (
		task     => { image => 'genesiscommunity/concourse', version => 'latest' },
		registry => {},
	);
	$config{track_bosh_configs} = $o{track_bosh_configs}
		if exists $o{track_bosh_configs};

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
	$node{track_bosh_configs} = $o{env_track_bosh_configs}
		if exists $o{env_track_bosh_configs};

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
		workflows => {
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

# Build AST with two envs, the second triggered by the first
sub _two_env_ast {
	my (%o) = @_;
	my %config = (
		task     => { image => 'genesiscommunity/concourse', version => 'latest' },
		registry => {},
	);
	$config{track_bosh_configs} = $o{track_bosh_configs}
		if exists $o{track_bosh_configs};

	my %nodes = (
		sandbox => {
			alias => 'sandbox', stage_name => 'sandbox', genesis_env => 'sandbox',
			auto => 1, type => 'deployment', require_pr => 0,
			manual => 0, redeploy => '', redeploy_cron_start => '',
			redeploy_cron_stop => '', status_signal => '',
			signal_prefix => '', bosh_parent => '', bosh_upgrade_lock => 1,
		},
		prod => {
			alias => 'prod', stage_name => 'prod', genesis_env => 'prod',
			auto => 0, type => 'deployment', require_pr => 0,
			manual => 0, redeploy => '', redeploy_cron_start => '',
			redeploy_cron_stop => '', status_signal => '',
			signal_prefix => '', bosh_parent => '', bosh_upgrade_lock => 1,
		},
	);
	if (exists $o{prod_track_bosh_configs}) {
		$nodes{prod}{track_bosh_configs} = $o{prod_track_bosh_configs};
	}

	my %targets = map { $_ => {
		type => 'bosh-director',
		connection => { url => "https://$_.example.com:25555", ca_cert => 'ca',
		                auth => { client_id => 'admin', client_secret => 'secret' } },
	}} qw(sandbox prod);

	return Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'test-pipeline', deployment_type => 'deployment' },
		branches     => { control => 'main' },
		integrations => {
			source_control => { provider => 'github', repository => 'org/repo' },
			vault          => { url => 'https://vault.example.com' },
		},
		targets      => \%targets,
		workflows    => {
			default => {
				name  => 'default',
				type  => 'deployment',
				graph => {
					nodes => \%nodes,
					edges => [{ from => 'sandbox', to => 'prod' }],
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

# Return get steps from the parallel block of a job's plan.
# Deploy jobs wrap everything in plan[0]{do}; notify jobs use a flat plan array.
sub _job_gets {
	my ($pipeline, $job_name) = @_;
	my $job = _find_job($pipeline, $job_name) or return ();
	my $plan  = $job->{plan} || [];
	my $steps = ($plan->[0] && $plan->[0]{do}) ? $plan->[0]{do} : $plan;
	my ($parallel) = grep { ref $_ eq 'HASH' && $_->{in_parallel} } @$steps;
	return $parallel ? @{$parallel->{in_parallel}} : ();
}

# Return get names from a job's parallel block
sub _get_names {
	my ($pipeline, $job_name) = @_;
	return map { ref $_ eq 'HASH' && $_->{get} ? $_->{get} : () }
		_job_gets($pipeline, $job_name);
}

# =========================================================================
# AC7 — Opt-in: default off
# =========================================================================
subtest 'Default (no track_bosh_configs): no bosh-config resources emitted' => sub {
	my $pl = _describe(_ast_for());

	ok(!_find_resource($pl, 'sandbox-cloud-config'),
		'No cloud-config resource by default');
	ok(!_find_resource($pl, 'sandbox-runtime-config'),
		'No runtime-config resource by default');
	ok(!_find_resource($pl, 'sandbox-cpi-config'),
		'No cpi-config resource by default');
};

subtest 'track_bosh_configs: false suppresses all resources' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => 0));

	ok(!_find_resource($pl, 'sandbox-cloud-config'),   'No cloud-config with false');
	ok(!_find_resource($pl, 'sandbox-runtime-config'), 'No runtime-config with false');
};

# =========================================================================
# AC2 — Concourse emits bosh-config resources when configured
# =========================================================================
subtest 'track_bosh_configs: true emits cloud-config and runtime-config' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => 1));

	ok(_find_resource($pl, 'sandbox-cloud-config'),   'cloud-config resource emitted');
	ok(_find_resource($pl, 'sandbox-runtime-config'), 'runtime-config resource emitted');
	ok(!_find_resource($pl, 'sandbox-cpi-config'),    'cpi-config not emitted for true');
};

subtest 'track_bosh_configs: [cloud, runtime, cpi] emits all three types' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => ['cloud', 'runtime', 'cpi']));

	ok(_find_resource($pl, 'sandbox-cloud-config'),   'cloud-config emitted');
	ok(_find_resource($pl, 'sandbox-runtime-config'), 'runtime-config emitted');
	ok(_find_resource($pl, 'sandbox-cpi-config'),     'cpi-config emitted');
};

# =========================================================================
# AC3 — Resource connection derived from env's bosh target
# =========================================================================
subtest 'bosh-config resource source derived from env target connection' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => 1));
	my $r  = _find_resource($pl, 'sandbox-cloud-config');

	ok($r, 'cloud-config resource present');
	is($r->{type}, 'bosh-config', 'type is bosh-config');
	is($r->{source}{target}, 'https://bosh.example.com:25555', 'target URL correct');
	is($r->{source}{client}, 'admin', 'client from auth.client_id');
	is($r->{source}{client_secret}, 'secret', 'client_secret from auth.client_secret');
	is($r->{source}{ca_cert}, 'fake-ca', 'ca_cert from connection.ca_cert');
	is($r->{source}{config}, 'cloud', 'config type is cloud');
	ok($r->{source}{all}, 'all: true set');
};

subtest 'runtime-config resource source correct' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => 1));
	my $r  = _find_resource($pl, 'sandbox-runtime-config');

	is($r->{source}{config}, 'runtime', 'config type is runtime');
	is($r->{source}{target}, 'https://bosh.example.com:25555', 'target correct');
};

subtest 'cpi-config resource source correct' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => ['cpi']));
	my $r  = _find_resource($pl, 'sandbox-cpi-config');

	ok($r, 'cpi-config resource present');
	is($r->{source}{config}, 'cpi', 'config type is cpi');
	is($r->{type}, 'bosh-config', 'resource type is bosh-config');
};

# =========================================================================
# AC4 — Subset selection
# =========================================================================
subtest 'track_bosh_configs: [cloud] emits only cloud-config' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => ['cloud']));

	ok(_find_resource($pl, 'sandbox-cloud-config'),    'cloud-config emitted');
	ok(!_find_resource($pl, 'sandbox-runtime-config'), 'runtime-config NOT emitted');
	ok(!_find_resource($pl, 'sandbox-cpi-config'),     'cpi-config NOT emitted');
};

subtest 'track_bosh_configs: [runtime] emits only runtime-config' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => ['runtime']));

	ok(!_find_resource($pl, 'sandbox-cloud-config'),  'cloud-config NOT emitted');
	ok(_find_resource($pl, 'sandbox-runtime-config'), 'runtime-config emitted');
	ok(!_find_resource($pl, 'sandbox-cpi-config'),    'cpi-config NOT emitted');
};

subtest 'track_bosh_configs: [cpi] emits only cpi-config' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => ['cpi']));

	ok(!_find_resource($pl, 'sandbox-cloud-config'),   'cloud-config NOT emitted');
	ok(!_find_resource($pl, 'sandbox-runtime-config'), 'runtime-config NOT emitted');
	ok(_find_resource($pl, 'sandbox-cpi-config'),      'cpi-config emitted');
};

subtest 'track_bosh_configs: [cloud, cpi] emits cloud and cpi but not runtime' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => ['cloud', 'cpi']));

	ok(_find_resource($pl, 'sandbox-cloud-config'),    'cloud-config emitted');
	ok(!_find_resource($pl, 'sandbox-runtime-config'), 'runtime-config NOT emitted');
	ok(_find_resource($pl, 'sandbox-cpi-config'),      'cpi-config emitted');
};

# =========================================================================
# AC5 — Per-env override
# =========================================================================
subtest 'Per-env track_bosh_configs overrides global default (off)' => sub {
	my $ast = _ast_for(
		env_track_bosh_configs => ['cloud'],
	);
	my $pl = _describe($ast);

	ok(_find_resource($pl, 'sandbox-cloud-config'),    'cloud-config emitted via per-env');
	ok(!_find_resource($pl, 'sandbox-runtime-config'), 'runtime-config not in per-env list');
};

subtest 'Per-env false overrides global true' => sub {
	my $ast = _two_env_ast(
		track_bosh_configs      => 1,
		prod_track_bosh_configs => 0,
	);
	my $pl = _describe($ast);

	ok(_find_resource($pl, 'sandbox-cloud-config'),   'sandbox gets cloud-config (global)');
	ok(!_find_resource($pl, 'prod-cloud-config'),     'prod suppressed by per-env false');
};

subtest 'Per-env superset overrides global subset' => sub {
	my $ast = _two_env_ast(
		track_bosh_configs      => ['cloud'],
		prod_track_bosh_configs => ['cloud', 'runtime', 'cpi'],
	);
	my $pl = _describe($ast);

	ok(_find_resource($pl, 'sandbox-cloud-config'),    'sandbox gets cloud (global)');
	ok(!_find_resource($pl, 'sandbox-runtime-config'), 'sandbox no runtime (global)');
	ok(_find_resource($pl, 'prod-cloud-config'),       'prod gets cloud');
	ok(_find_resource($pl, 'prod-runtime-config'),     'prod gets runtime');
	ok(_find_resource($pl, 'prod-cpi-config'),         'prod gets cpi');
};

# =========================================================================
# Job get-step wiring
# =========================================================================
subtest 'Auto env deploy job: bosh-config gets trigger when configured' => sub {
	my $pl = _describe(_ast_for(auto => 1, track_bosh_configs => 1));
	my @names = _get_names($pl, 'sandbox-deployment');

	ok(grep({ $_ eq 'sandbox-cloud-config'   } @names), 'cloud-config get in auto deploy');
	ok(grep({ $_ eq 'sandbox-runtime-config' } @names), 'runtime-config get in auto deploy');
};

subtest 'Auto env deploy job: no bosh-config gets when not configured' => sub {
	my $pl = _describe(_ast_for(auto => 1));
	my @names = _get_names($pl, 'sandbox-deployment');

	ok(!grep({ $_ eq 'sandbox-cloud-config'   } @names), 'no cloud-config get');
	ok(!grep({ $_ eq 'sandbox-runtime-config' } @names), 'no runtime-config get');
};

subtest 'Auto env deploy job: subset [cloud] adds only cloud get' => sub {
	my $pl = _describe(_ast_for(auto => 1, track_bosh_configs => ['cloud']));
	my @names = _get_names($pl, 'sandbox-deployment');

	ok(grep({ $_ eq 'sandbox-cloud-config' } @names),    'cloud-config get present');
	ok(!grep({ $_ eq 'sandbox-runtime-config' } @names), 'runtime-config get absent');
};

my $_slack = { channel => '#deploys', webhook => '((slack-webhook))' };

subtest 'Notify job: bosh-config gets trigger when configured' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => 1, slack => $_slack));
	my @names = _get_names($pl, 'notify-sandbox-deployment-changes');

	ok(grep({ $_ eq 'sandbox-cloud-config'   } @names), 'cloud-config get in notify job');
	ok(grep({ $_ eq 'sandbox-runtime-config' } @names), 'runtime-config get in notify job');
};

subtest 'Notify job: no bosh-config gets when not configured' => sub {
	my $pl = _describe(_ast_for(slack => $_slack));
	my @names = _get_names($pl, 'notify-sandbox-deployment-changes');

	ok(!grep({ $_ eq 'sandbox-cloud-config'   } @names), 'no cloud-config get in notify');
	ok(!grep({ $_ eq 'sandbox-runtime-config' } @names), 'no runtime-config get in notify');
};

subtest 'Notify job: bosh-config gets are triggering' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => 1, slack => $_slack));
	my @gets = _job_gets($pl, 'notify-sandbox-deployment-changes');
	my ($cc) = grep { ref $_ eq 'HASH' && ($_->{get}||'') eq 'sandbox-cloud-config' } @gets;

	ok($cc, 'cloud-config get found');
	ok($cc->{trigger}, 'cloud-config get triggers notify job');
};

# =========================================================================
# Resource icons
# =========================================================================
subtest 'Cloud-config resource has cloud icon' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => ['cloud']));
	my $r  = _find_resource($pl, 'sandbox-cloud-config');
	is($r->{icon}, 'cloud', 'cloud icon set');
};

subtest 'Runtime-config resource has run-fast icon' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => ['runtime']));
	my $r  = _find_resource($pl, 'sandbox-runtime-config');
	is($r->{icon}, 'run-fast', 'run-fast icon set');
};

subtest 'CPI-config resource has chip icon' => sub {
	my $pl = _describe(_ast_for(track_bosh_configs => ['cpi']));
	my $r  = _find_resource($pl, 'sandbox-cpi-config');
	is($r->{icon}, 'chip', 'chip icon set');
};

# =========================================================================
# Multi-env — correct resources per env with independent targets
# =========================================================================
subtest 'Two-env pipeline emits per-env bosh-config resources' => sub {
	my $pl = _describe(_two_env_ast(track_bosh_configs => 1));

	ok(_find_resource($pl, 'sandbox-cloud-config'),   'sandbox-cloud-config emitted');
	ok(_find_resource($pl, 'sandbox-runtime-config'), 'sandbox-runtime-config emitted');
	ok(_find_resource($pl, 'prod-cloud-config'),      'prod-cloud-config emitted');
	ok(_find_resource($pl, 'prod-runtime-config'),    'prod-runtime-config emitted');
};

subtest 'Two-env: each resource has its own director target' => sub {
	my $pl = _describe(_two_env_ast(track_bosh_configs => 1));

	my $sb = _find_resource($pl, 'sandbox-cloud-config');
	my $pr = _find_resource($pl, 'prod-cloud-config');

	is($sb->{source}{target}, 'https://sandbox.example.com:25555', 'sandbox target');
	is($pr->{source}{target}, 'https://prod.example.com:25555',    'prod target');
};

done_testing;
