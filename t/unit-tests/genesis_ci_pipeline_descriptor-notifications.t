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

# Build a minimal AST with configurable Slack notification config.
# slack_cfg: hashref placed directly at integrations.slack
# legacy_notifications: arrayref placed at integrations.notifications (old format)
# legacy_style: string placed at configuration.notifications.style (old format)
sub _ast_for {
	my (%o) = @_;

	my $env   = $o{env}   || 'sandbox';
	my $alias = $o{alias} || $env;

	my %integrations = (
		source_control => { provider => 'github', repository => 'org/repo' },
		vault          => { url => 'https://vault.example.com' },
	);

	if ($o{slack_cfg}) {
		$integrations{slack} = $o{slack_cfg};
	} elsif ($o{legacy_notifications}) {
		$integrations{notifications} = $o{legacy_notifications};
	}

	my %config = (
		task     => { image => 'genesiscommunity/concourse', version => 'latest' },
		registry => {},
	);
	$config{notifications} = { style => $o{legacy_style} }
		if $o{legacy_style};

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

	my %nodes = ($env => \%node);
	my %targets = (
		$env => {
			type       => 'bosh-director',
			connection => {
				url     => 'https://bosh.example.com:25555',
				ca_cert => 'fake-ca',
				auth    => { client_id => 'admin', client_secret => 'secret' },
			},
		},
	);

	# Multi-env support
	if ($o{extra_envs}) {
		for my $eenv (@{$o{extra_envs}}) {
			my $en = $eenv->{env};
			$nodes{$en} = {
				alias               => $en,
				stage_name          => $en,
				genesis_env         => $en,
				auto                => $eenv->{auto} // 0,
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
			};
			$targets{$en} = {
				type       => 'bosh-director',
				connection => { url => 'https://bosh.example.com:25555',
				    ca_cert => 'c', auth => { client_id => 'u', client_secret => 's' } },
			};
		}
	}

	return Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'test-pipeline', deployment_type => 'deployment' },
		branches     => { control => 'main' },
		integrations => \%integrations,
		targets      => \%targets,
		workflows    => {
			default => {
				name  => 'default',
				type  => 'deployment',
				graph => {
					nodes => \%nodes,
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

sub _find_job {
	my ($pipeline, $name) = @_;
	my ($j) = grep { $_->{name} eq $name } @{$pipeline->{jobs}};
	return $j;
}

sub _find_resource {
	my ($pipeline, $name) = @_;
	my ($r) = grep { $_->{name} eq $name } @{$pipeline->{resources}};
	return $r;
}

sub _find_rtype {
	my ($pipeline, $name) = @_;
	my ($r) = grep { $_->{name} eq $name } @{$pipeline->{resource_types}};
	return $r;
}

sub _outcome_hook {
	my ($job, $hook) = @_;
	return ($job->{plan}[0] || {})->{$hook};
}

# =========================================================================
# 1. style: per-env — notify jobs created, inline with deploy
# =========================================================================
subtest 'per-env style: notify jobs created and inlined with deploy' => sub {
	my $ast = _ast_for(
		env      => 'sandbox',
		slack_cfg => {
			webhook => '((slack-hook))',
			channel => '#deployments',
			style   => 'per-env',
			mentions_on_failure => [],
			per_env_overrides   => {},
		},
	);
	my $pipeline = _describe($ast);

	my $nj = _find_job($pipeline, 'notify-sandbox-deployment-changes');
	ok $nj, 'notify job created for non-auto env';

	my $dj = _find_job($pipeline, 'sandbox-deployment');
	my $gets = $dj->{plan}[0]{do};
	my ($par) = grep { ref $_ eq 'HASH' && $_->{in_parallel} } @$gets;
	my ($changes_get) = grep { ($_->{get}||'') eq 'sandbox-branch' }
		@{$par->{in_parallel}};
	ok $changes_get->{passed}, 'deploy job gets sandbox-branch with passed dependency';
	like $changes_get->{passed}[0], qr/notify-sandbox/, 'passed references notify job';

	my $rt = _find_rtype($pipeline, 'slack-notification');
	ok $rt, 'slack-notification resource type emitted';

	my $slack_res = _find_resource($pipeline, 'slack');
	ok $slack_res, 'slack resource emitted';
};

# =========================================================================
# 2. style: grouped — notify jobs created, in separate group, deploy independent
# =========================================================================
subtest 'grouped style: notify jobs in separate group, deploy gets changes directly' => sub {
	my $ast = _ast_for(
		env      => 'sandbox',
		slack_cfg => {
			webhook => '((slack-hook))',
			channel => '#deployments',
			style   => 'grouped',
			mentions_on_failure => [],
			per_env_overrides   => {},
		},
	);
	my $pipeline = _describe($ast);

	my $nj = _find_job($pipeline, 'notify-sandbox-deployment-changes');
	ok $nj, 'notify job created for grouped style';

	# 'notifications' group must exist
	my ($notif_group) = grep { $_->{name} eq 'notifications' } @{$pipeline->{groups}};
	ok $notif_group, 'notifications group emitted';
	ok grep({ $_ eq 'notify-sandbox-deployment-changes' } @{$notif_group->{jobs}}),
		'notify job is in the notifications group';

	# Deploy job must NOT depend on notify job (gets changes directly)
	my $dj   = _find_job($pipeline, 'sandbox-deployment');
	my $do   = $dj->{plan}[0]{do};
	my ($par) = grep { ref $_ eq 'HASH' && $_->{in_parallel} } @$do;
	my ($cg)  = grep { ($_->{get}||'') eq 'sandbox-branch' }
		@{$par->{in_parallel}};
	ok !$cg->{passed}, 'deploy job gets sandbox-branch WITHOUT passed dependency';
};

# =========================================================================
# 3. style: minimal — no notify jobs; only on_failure hook
# =========================================================================
subtest 'minimal style: no notify jobs, only on_failure hook in deploy' => sub {
	my $ast = _ast_for(
		env      => 'sandbox',
		slack_cfg => {
			webhook => '((slack-hook))',
			channel => '#deployments',
			style   => 'minimal',
			mentions_on_failure => [],
			per_env_overrides   => {},
		},
	);
	my $pipeline = _describe($ast);

	ok !_find_job($pipeline, 'notify-sandbox-deployment-changes'),
		'no notify job for minimal style';

	my $dj = _find_job($pipeline, 'sandbox-deployment');
	ok !_outcome_hook($dj, 'on_success'), 'no on_success hook for minimal style';
	ok  _outcome_hook($dj, 'on_failure'), 'on_failure hook present for minimal style';

	ok _find_resource($pipeline, 'slack'), 'slack resource still emitted for minimal';
};

# =========================================================================
# 4. style: none — no notifications at all
# =========================================================================
subtest 'none style: no slack resources, no notify jobs, no hooks' => sub {
	my $ast = _ast_for(
		env      => 'sandbox',
		slack_cfg => {
			webhook => '((slack-hook))',
			channel => '#deployments',
			style   => 'none',
			mentions_on_failure => [],
			per_env_overrides   => {},
		},
	);
	my $pipeline = _describe($ast);

	ok !_find_job($pipeline, 'notify-sandbox-deployment-changes'),
		'no notify job for none style';
	ok !_find_resource($pipeline, 'slack'),
		'no slack resource for none style';
	ok !_find_rtype($pipeline, 'slack-notification'),
		'no slack-notification resource type for none style';

	my $dj = _find_job($pipeline, 'sandbox-deployment');
	ok !_outcome_hook($dj, 'on_success'), 'no on_success hook';
	ok !_outcome_hook($dj, 'on_failure'), 'no on_failure hook';
};

# =========================================================================
# 5. mentions_on_failure prepended to failure notification text
# =========================================================================
subtest 'mentions_on_failure prepended to failure notification text' => sub {
	my $ast = _ast_for(
		env      => 'prod',
		slack_cfg => {
			webhook             => '((slack-hook))',
			channel             => '#alerts',
			style               => 'per-env',
			mentions_on_failure => ['@sre-oncall', '@prod-sre'],
			per_env_overrides   => {},
		},
	);
	my $pipeline = _describe($ast);

	my $dj       = _find_job($pipeline, 'prod-deployment');
	my $on_fail  = _outcome_hook($dj, 'on_failure');
	ok $on_fail, 'on_failure hook present';

	# Unwrap: on_failure may be a single put or in_parallel
	my $put = ref($on_fail) eq 'HASH' && $on_fail->{in_parallel}
		? $on_fail->{in_parallel}[0]
		: $on_fail;
	like $put->{params}{text}, qr/\@sre-oncall/,  'mention @sre-oncall in failure text';
	like $put->{params}{text}, qr/\@prod-sre/,    'mention @prod-sre in failure text';

	# Success hook must NOT have mentions
	my $on_succ = _outcome_hook($dj, 'on_success');
	if ($on_succ) {
		my $sput = ref($on_succ) eq 'HASH' && $on_succ->{in_parallel}
			? $on_succ->{in_parallel}[0]
			: $on_succ;
		unlike $sput->{params}{text}, qr/\@sre-oncall/, 'no mention in success text';
	}
};

# =========================================================================
# 6. per_env_overrides: different channel and mentions for specific env
# =========================================================================
subtest 'per_env_overrides: env uses its own channel and mentions' => sub {
	my $ast = _ast_for(
		env      => 'sandbox',
		extra_envs => [{ env => 'prod' }],
		slack_cfg => {
			webhook             => '((slack-hook))',
			channel             => '#deployments',
			style               => 'per-env',
			mentions_on_failure => [],
			per_env_overrides   => {
				prod => {
					channel             => '#prod-alerts',
					mentions_on_failure => ['@prod-oncall'],
				},
			},
		},
	);
	my $pipeline = _describe($ast);

	# Sandbox notify job should use global channel
	my $sb_nj   = _find_job($pipeline, 'notify-sandbox-deployment-changes');
	ok $sb_nj, 'sandbox notify job present';
	my $sb_put  = $sb_nj->{plan}[-1];
	$sb_put = $sb_put->{in_parallel}[0] if ref($sb_put) eq 'HASH' && $sb_put->{in_parallel};
	is $sb_put->{params}{channel}, '#deployments', 'sandbox uses global channel';

	# Prod notify job should use override channel
	my $prod_nj = _find_job($pipeline, 'notify-prod-deployment-changes');
	ok $prod_nj, 'prod notify job present';
	my $prod_put = $prod_nj->{plan}[-1];
	$prod_put = $prod_put->{in_parallel}[0] if ref($prod_put) eq 'HASH' && $prod_put->{in_parallel};
	is $prod_put->{params}{channel}, '#prod-alerts', 'prod uses override channel';

	# Prod failure hook should have mentions
	my $prod_dj   = _find_job($pipeline, 'prod-deployment');
	my $on_fail   = _outcome_hook($prod_dj, 'on_failure');
	my $fail_put  = ref($on_fail) eq 'HASH' && $on_fail->{in_parallel}
		? $on_fail->{in_parallel}[0] : $on_fail;
	like $fail_put->{params}{text}, qr/\@prod-oncall/, 'prod failure has mention';
	is   $fail_put->{params}{channel}, '#prod-alerts',  'prod failure uses override channel';

	# Sandbox failure hook should NOT have mentions
	my $sb_dj    = _find_job($pipeline, 'sandbox-deployment');
	my $sb_fail  = _outcome_hook($sb_dj, 'on_failure');
	my $sf_put   = ref($sb_fail) eq 'HASH' && $sb_fail->{in_parallel}
		? $sb_fail->{in_parallel}[0] : $sb_fail;
	unlike $sf_put->{params}{text}, qr/\@prod-oncall/, 'sandbox failure has no prod mention';
	is     $sf_put->{params}{channel}, '#deployments',  'sandbox failure uses global channel';
};

# =========================================================================
# 7. Legacy notifications: grouped backward compat
# =========================================================================
subtest 'Legacy notifications: grouped maps to grouped style' => sub {
	my $ast = _ast_for(
		env                  => 'sandbox',
		legacy_notifications => [
			{ type => 'slack', webhook => '((hook))', channel => '#ci',
			  username => 'bot', icon => 'http://icon' }
		],
		legacy_style => 'grouped',
	);
	my $pipeline = _describe($ast);

	my $nj = _find_job($pipeline, 'notify-sandbox-deployment-changes');
	ok $nj, 'notify job created (grouped compat)';

	my ($notif_group) = grep { $_->{name} eq 'notifications' } @{$pipeline->{groups}};
	ok $notif_group, 'notifications group emitted for legacy grouped style';

	my $rt = _find_rtype($pipeline, 'slack-notification');
	ok $rt, 'slack-notification resource type emitted';
};

# =========================================================================
# 8. Legacy notifications: inline (default) maps to per-env style
# =========================================================================
subtest 'Legacy notifications: inline maps to per-env (notify job with passed dep)' => sub {
	my $ast = _ast_for(
		env                  => 'sandbox',
		legacy_notifications => [
			{ type => 'slack', webhook => '((hook))', channel => '#ci',
			  username => 'bot', icon => 'http://icon' }
		],
		# no legacy_style → defaults to inline → maps to per-env
	);
	my $pipeline = _describe($ast);

	my $nj = _find_job($pipeline, 'notify-sandbox-deployment-changes');
	ok $nj, 'notify job created for legacy inline style';

	my $dj   = _find_job($pipeline, 'sandbox-deployment');
	my $do   = $dj->{plan}[0]{do};
	my ($par) = grep { ref $_ eq 'HASH' && $_->{in_parallel} } @$do;
	my ($cg)  = grep { ($_->{get}||'') eq 'sandbox-branch' }
		@{$par->{in_parallel}};
	ok $cg->{passed}, 'deploy job has passed dependency (inline/per-env behavior)';

	my ($notif_group) = grep { $_->{name} eq 'notifications' } @{$pipeline->{groups}};
	ok !$notif_group, 'no separate notifications group for inline style';
};

# =========================================================================
# 9. Legacy notifications: no Slack configured → no slack resources or jobs
# =========================================================================
subtest 'No Slack config: no slack resource, no notify jobs' => sub {
	my $ast = _ast_for(env => 'sandbox');
	my $pipeline = _describe($ast);

	ok !_find_job($pipeline, 'notify-sandbox-deployment-changes'),
		'no notify job when no Slack configured';
	ok !_find_resource($pipeline, 'slack'), 'no slack resource';
	ok !_find_rtype($pipeline, 'slack-notification'), 'no slack-notification resource type';
};

# =========================================================================
# 10. auto env: no notify job regardless of style
# =========================================================================
subtest 'auto env: no notify job even with per-env style' => sub {
	my $ast = _ast_for(
		env  => 'sandbox',
		auto => 1,
		slack_cfg => {
			webhook => '((hook))',
			channel => '#ci',
			style   => 'per-env',
			mentions_on_failure => [],
			per_env_overrides   => {},
		},
	);
	my $pipeline = _describe($ast);

	ok !_find_job($pipeline, 'notify-sandbox-deployment-changes'),
		'no notify job for auto env';
};

# =========================================================================
# 11. minimal: deploy job gets changes directly (no passed dependency)
# =========================================================================
subtest 'minimal style: deploy job gets changes directly' => sub {
	my $ast = _ast_for(
		env      => 'sandbox',
		slack_cfg => {
			webhook => '((hook))',
			channel => '#ci',
			style   => 'minimal',
			mentions_on_failure => [],
			per_env_overrides   => {},
		},
	);
	my $pipeline = _describe($ast);

	my $dj   = _find_job($pipeline, 'sandbox-deployment');
	my $do   = $dj->{plan}[0]{do};
	my ($par) = grep { ref $_ eq 'HASH' && $_->{in_parallel} } @$do;
	my ($cg)  = grep { ($_->{get}||'') eq 'sandbox-branch' }
		@{$par->{in_parallel}};
	ok !$cg->{passed}, 'minimal: deploy gets changes without passed dependency';
};

# =========================================================================
# 12. ASTBuilder: legacy notifications array normalized to integrations.slack
# =========================================================================
subtest 'ASTBuilder normalizes legacy notifications array to integrations.slack' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	_write("$tmp/sandbox.yml", <<'YAML');
---
genesis:
  env: sandbox
  pipeline: {}
YAML

	my $builder = Genesis::CI::Compiler::ASTBuilder->new(env_dir => $tmp);
	my $parsed  = {
		_source_format  => 'multi-file',
		env_dir         => $tmp,
		pipeline        => {},
		targets         => {},
		integrations    => {
			notifications => [
				{ type => 'slack', webhook => 'https://hooks.slack.com/test',
				  channel => '#ci', username => 'bot', icon => 'http://icon' }
			],
		},
		scripts         => {},
		provider_config => {},
	};
	my $ast = $builder->build($parsed, {});

	my $slack = $ast->integrations->{slack};
	ok $slack, 'integrations.slack created from legacy notifications array';
	is $slack->{webhook}, 'https://hooks.slack.com/test', 'webhook preserved';
	is $slack->{channel}, '#ci',                          'channel preserved';
	is $slack->{style},   'per-env',                      'default style is per-env';
	is ref($slack->{mentions_on_failure}), 'ARRAY',       'mentions_on_failure is array';
	is ref($slack->{per_env_overrides}),   'HASH',        'per_env_overrides is hash';
};

# =========================================================================
# 13. ASTBuilder: legacy notifications: grouped sets style to grouped
# =========================================================================
subtest 'ASTBuilder: legacy notifications: grouped → style: grouped' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	_write("$tmp/sandbox.yml", <<'YAML');
---
genesis:
  env: sandbox
  pipeline: {}
YAML

	my $builder = Genesis::CI::Compiler::ASTBuilder->new(env_dir => $tmp);
	my $parsed  = {
		_source_format  => 'legacy',
		env_dir         => $tmp,
		pipeline        => {},
		targets         => {},
		integrations    => {
			notifications => [
				{ type => 'slack', webhook => 'https://hooks.slack.com/test',
				  channel => '#ci' }
			],
		},
		scripts         => {},
		provider_config => {},
		_legacy_raw     => {
			pipeline => {
				notifications => 'grouped',
				name          => 'test',
				git           => { branch => 'main' },
			},
		},
	};

	my $ast = $builder->build($parsed, {});
	my $slack = $ast->integrations->{slack};
	ok $slack, 'integrations.slack present';
	is $slack->{style}, 'grouped', 'legacy notifications: grouped maps to style: grouped';
};

# =========================================================================
# 14. New slack: config directly in integrations
# =========================================================================
subtest 'New slack: config block used directly from integrations' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	_write("$tmp/sandbox.yml", <<'YAML');
---
genesis:
  env: sandbox
  pipeline: {}
YAML

	my $builder = Genesis::CI::Compiler::ASTBuilder->new(env_dir => $tmp);
	my $parsed  = {
		_source_format  => 'multi-file',
		env_dir         => $tmp,
		pipeline        => {},
		targets         => {},
		integrations    => {
			slack => {
				webhook             => '((slack-webhook))',
				channel             => '#deployments',
				style               => 'minimal',
				mentions_on_failure => ['@sre'],
				per_env_overrides   => {},
			},
		},
		scripts         => {},
		provider_config => {},
	};
	my $ast = $builder->build($parsed, {});

	my $slack = $ast->integrations->{slack};
	ok $slack, 'integrations.slack preserved as-is';
	is $slack->{style},               'minimal', 'style preserved';
	is $slack->{mentions_on_failure}[0], '@sre', 'mentions_on_failure preserved';
};

done_testing;
