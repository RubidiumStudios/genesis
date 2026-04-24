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
use_ok 'Genesis::CI::Compiler::ASTBuilder';
use_ok 'Genesis::CI::Compiler::PipelineDescriptor';

# =========================================================================
# Helpers
# =========================================================================

sub _ast_for {
	my (%o) = @_;

	my %config = (
		task     => { image => 'genesiscommunity/concourse', version => 'latest' },
		registry => {},
	);
	$config{auto_update} = $o{auto_update} if $o{auto_update};

	my %integrations = (
		source_control => {
			provider       => 'github',
			repository     => 'org/repo',
			default_branch => $o{control_branch} || 'main',
			($o{sc_auth} ? (auth => $o{sc_auth}) : ()),
		},
		vault => { url => 'https://vault.example.com' },
	);

	my $env = 'sandbox';
	return Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'test-pipeline', deployment_type => 'deployment' },
		branches     => { control => $o{control_branch} || 'main' },
		integrations => \%integrations,
		targets      => {
			$env => {
				type       => 'bosh-director',
				connection => {
					url     => 'https://bosh.example.com:25555',
					ca_cert => 'ca',
					auth    => { client_id => 'admin', client_secret => 'secret' },
				},
			},
		},
		workflows => {
			default => {
				name  => 'default',
				type  => 'deployment',
				graph => {
					nodes => {
						$env => {
							alias => $env, stage_name => $env, genesis_env => $env,
							auto => 0, type => 'deployment', require_pr => 0,
							manual => 0, redeploy => '', redeploy_cron_start => '',
							redeploy_cron_stop => '', status_signal => '',
							signal_prefix => '', bosh_parent => '', bosh_upgrade_lock => 1,
						},
					},
					edges => [],
				},
			},
		},
		configuration => \%config,
	);
}

# Run AST through ASTBuilder normalization path (multi-file)
sub _ast_via_builder {
	my (%o) = @_;

	require Genesis::CI::Compiler::ASTBuilder;

	my $au_raw = $o{auto_update};
	my $parsed = {
		_source_format => 'multi-file',
		integrations   => {
			source_control => {
				provider       => 'github',
				repository     => 'org/repo',
				default_branch => 'main',
			},
			vault => { url => 'https://vault.example.com' },
		},
		pipeline => {
			configuration => {
				task         => { image => 'genesiscommunity/concourse', version => 'latest' },
				registry     => {},
				auto_update  => $au_raw,
			},
		},
		targets => {},
	};

	my $builder = Genesis::CI::Compiler::ASTBuilder->new();
	return $builder->build($parsed, {});
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

sub _find_group {
	my ($pipeline, $name) = @_;
	my ($g) = grep { $_->{name} eq $name } @{$pipeline->{groups}};
	return $g;
}

sub _plan_tasks {
	my ($job) = @_;
	return grep { ref $_ eq 'HASH' && $_->{task} } @{$job->{plan} || []};
}

sub _plan_puts {
	my ($job) = @_;
	return grep { ref $_ eq 'HASH' && $_->{put} } @{$job->{plan} || []};
}

sub _parallel_gets {
	my ($job) = @_;
	my ($step) = grep { ref $_ eq 'HASH' && $_->{in_parallel} } @{$job->{plan} || []};
	return $step ? @{$step->{in_parallel}} : ();
}

sub _task_params {
	my ($job, $task_name) = @_;
	my ($t) = grep { ref $_ eq 'HASH' && ($_->{task} || '') eq $task_name } @{$job->{plan}};
	return $t ? %{($t->{config} || {})->{params} || {}} : ();
}

# =========================================================================
# 1. Opt-out: no auto_update or enabled: false → no job emitted
# =========================================================================
subtest 'No auto_update config: no update-genesis-assets job' => sub {
	my $ast = _ast_for();
	my $pl  = _describe($ast);

	ok(!_find_job($pl, 'update-genesis-assets'), 'no job without auto_update');
	ok(!_find_resource($pl, 'kit-release'),      'no kit-release without auto_update');
	ok(!_find_resource($pl, 'genesis-release'),  'no genesis-release without auto_update');
	ok(!_find_group($pl, 'genesis-updates'),     'no genesis-updates group');
};

subtest 'enabled: false suppresses emission' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 0,
		kit     => 'cf',
		org     => 'genesis-community',
		file    => 'lm.yml',
	});
	my $pl = _describe($ast);

	ok(!_find_job($pl, 'update-genesis-assets'), 'no job when enabled: false');
};

# =========================================================================
# 2. Basic emission: enabled: true emits job + resources + group
# =========================================================================
subtest 'enabled: true emits update-genesis-assets job' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1,
		kit     => 'cf',
		org     => 'genesis-community',
		file    => 'lm.yml',
	});
	my $pl = _describe($ast);

	ok(_find_job($pl,      'update-genesis-assets'), 'job emitted');
	ok(_find_resource($pl, 'kit-release'),           'kit-release resource emitted');
	ok(_find_resource($pl, 'genesis-release'),       'genesis-release resource emitted');
	ok(_find_group($pl,    'genesis-updates'),       'genesis-updates group emitted');
};

subtest 'genesis-updates group contains update-genesis-assets' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
	});
	my $g = _find_group(_describe($ast), 'genesis-updates');
	cmp_deeply($g->{jobs}, ['update-genesis-assets'], 'group lists exactly the update job');
};

# =========================================================================
# 3. Kit-release resource config
# =========================================================================
subtest 'kit-release resource points at correct GitHub repo' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
	});
	my $r = _find_resource(_describe($ast), 'kit-release');

	is($r->{type},          'github-release',        'type is github-release');
	is($r->{source}{user},  'genesis-community',     'org correct');
	is($r->{source}{repository}, 'cf-genesis-kit',   'repo is kit-genesis-kit');
};

subtest 'kit-release check_every defaults to 24h' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
	});
	my $r = _find_resource(_describe($ast), 'kit-release');
	is($r->{check_every}, '24h', 'default check period');
};

subtest 'kit-release check_every uses configured period' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml', period => '12h',
	});
	my $r = _find_resource(_describe($ast), 'kit-release');
	is($r->{check_every}, '12h', 'custom period respected');
};

subtest 'kit-release auth_token passthrough' => sub {
	my $ast = _ast_for(auto_update => {
		enabled        => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
		kit_auth_token => { secret_ref => 'github-kit-token' },
	});
	my $r = _find_resource(_describe($ast), 'kit-release');
	is($r->{source}{access_token}, '((github-kit-token))', 'kit_auth_token unwrapped');
};

subtest 'kit-release falls back to auth_token when kit_auth_token absent' => sub {
	my $ast = _ast_for(auto_update => {
		enabled    => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
		auth_token => { secret_ref => 'github-token' },
	});
	my $r = _find_resource(_describe($ast), 'kit-release');
	is($r->{source}{access_token}, '((github-token))', 'auth_token fallback');
};

subtest 'kit-release api_url for GitHub Enterprise' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
		api_url => 'https://api.github.example.com',
	});
	my $r = _find_resource(_describe($ast), 'kit-release');
	is($r->{source}{github_api_url}, 'https://api.github.example.com', 'api_url set');
};

# =========================================================================
# 4. Genesis-release resource config
# =========================================================================
subtest 'genesis-release resource always points at genesis-community/genesis' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
	});
	my $r = _find_resource(_describe($ast), 'genesis-release');

	is($r->{type},               'github-release',    'type is github-release');
	is($r->{source}{user},       'genesis-community', 'user is genesis-community');
	is($r->{source}{repository}, 'genesis',           'repo is genesis');
};

subtest 'genesis-release genesis_auth_token passthrough' => sub {
	my $ast = _ast_for(auto_update => {
		enabled              => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
		genesis_auth_token   => { secret_ref => 'genesis-token' },
	});
	my $r = _find_resource(_describe($ast), 'genesis-release');
	is($r->{source}{access_token}, '((genesis-token))', 'genesis_auth_token unwrapped');
};

# =========================================================================
# 5. Job plan structure: gets trigger correctly
# =========================================================================
subtest 'Both enabled: both resources trigger' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
	});
	my $job   = _find_job(_describe($ast), 'update-genesis-assets');
	my @gets  = _parallel_gets($job);

	my ($kit_get) = grep { ($_->{get} || '') eq 'kit-release'     } @gets;
	my ($gen_get) = grep { ($_->{get} || '') eq 'genesis-release' } @gets;

	ok($kit_get->{trigger}, 'kit-release triggers');
	ok($gen_get->{trigger}, 'genesis-release triggers');
};

# =========================================================================
# 6. update_genesis: false — skip genesis tasks and resource
# =========================================================================
subtest 'update_genesis: false omits genesis-release resource' => sub {
	my $ast = _ast_for(auto_update => {
		enabled        => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
		update_genesis => 0,
	});
	my $pl = _describe($ast);

	ok(!_find_resource($pl, 'genesis-release'), 'no genesis-release resource');
	ok(_find_resource($pl,  'kit-release'),     'kit-release still present');
};

subtest 'update_genesis: false omits update-genesis task from job' => sub {
	my $ast = _ast_for(auto_update => {
		enabled        => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
		update_genesis => 0,
	});
	my $job   = _find_job(_describe($ast), 'update-genesis-assets');
	my @tasks = _plan_tasks($job);

	ok(!grep({ $_->{task} eq 'update-genesis' } @tasks), 'no update-genesis task');
	ok(grep({ $_->{task} eq 'list-kits'       } @tasks), 'list-kits still present');
	ok(grep({ $_->{task} eq 'fetch-kit'       } @tasks), 'fetch-kit still present');
};

subtest 'update_genesis: false omits genesis-release get' => sub {
	my $ast  = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
		update_genesis => 0,
	});
	my $job  = _find_job(_describe($ast), 'update-genesis-assets');
	my @gets = _parallel_gets($job);

	ok(!grep({ ($_->{get} || '') eq 'genesis-release' } @gets),
		'no genesis-release get');
};

# =========================================================================
# 7. update_kit: false — skip kit tasks and resource
# =========================================================================
subtest 'update_kit: false omits kit-release resource' => sub {
	my $ast = _ast_for(auto_update => {
		enabled    => 1, kit => 'cf', org => 'genesis-community',
		update_kit => 0,
	});
	my $pl = _describe($ast);

	ok(!_find_resource($pl, 'kit-release'),    'no kit-release resource');
	ok(_find_resource($pl,  'genesis-release'), 'genesis-release still present');
};

subtest 'update_kit: false omits list-kits and fetch-kit tasks' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', update_kit => 0,
	});
	my $job   = _find_job(_describe($ast), 'update-genesis-assets');
	my @tasks = _plan_tasks($job);

	ok(!grep({ $_->{task} eq 'list-kits'  } @tasks), 'no list-kits task');
	ok(!grep({ $_->{task} eq 'fetch-kit'  } @tasks), 'no fetch-kit task');
	ok(grep({ $_->{task} eq 'update-genesis' } @tasks), 'update-genesis still present');
};

# =========================================================================
# 8. commit_label / label param
# =========================================================================
subtest 'commit_label maps to CI_LABEL in update-genesis and fetch-kit tasks' => sub {
	my $ast = _ast_for(auto_update => {
		enabled      => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
		commit_label => '[pipeline]',
	});
	my $job = _find_job(_describe($ast), 'update-genesis-assets');
	my %gp  = _task_params($job, 'update-genesis');
	my %fp  = _task_params($job, 'fetch-kit');

	is($gp{CI_LABEL}, '[pipeline]', 'CI_LABEL in update-genesis');
	is($fp{CI_LABEL}, '[pipeline]', 'CI_LABEL in fetch-kit');
};

subtest 'label key (legacy) maps to CI_LABEL' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
		label   => 'concourse',
	});
	my $job = _find_job(_describe($ast), 'update-genesis-assets');
	my %gp  = _task_params($job, 'update-genesis');
	is($gp{CI_LABEL}, 'concourse', 'label key used directly');
};

subtest 'CI_LABEL defaults to concourse when neither commit_label nor label set' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
	});
	my $job = _find_job(_describe($ast), 'update-genesis-assets');
	my %gp  = _task_params($job, 'update-genesis');
	is($gp{CI_LABEL}, 'concourse', 'default CI_LABEL');
};

# =========================================================================
# 9. fetch-kit task: KIT_VERSION_FILE from file / kit_version_file
# =========================================================================
subtest 'fetch-kit KIT_VERSION_FILE from file key' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
	});
	my $job = _find_job(_describe($ast), 'update-genesis-assets');
	my %p   = _task_params($job, 'fetch-kit');
	is($p{KIT_VERSION_FILE}, 'lm.yml', 'KIT_VERSION_FILE set from file key');
};

# =========================================================================
# 10. target_branch: pushes to control branch by default
# =========================================================================
subtest 'Default push uses git resource (control branch)' => sub {
	my $ast = _ast_for(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
	});
	my $job = _find_job(_describe($ast), 'update-genesis-assets');
	my ($put) = _plan_puts($job);

	is($put->{put},                  'git', 'puts to git resource');
	is($put->{params}{repository},   'git', 'repository param is git');
	ok($put->{params}{rebase},       'rebase: true set');
	ok(!_find_resource(_describe($ast), 'git-autoupdate'), 'no git-autoupdate resource');
};

subtest 'target_branch different from control branch emits git-autoupdate resource' => sub {
	my $ast = _ast_for(
		control_branch => 'main',
		auto_update    => {
			enabled       => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
			target_branch => 'auto-commits',
		},
	);
	my $pl  = _describe($ast);
	my $r   = _find_resource($pl, 'git-autoupdate');

	ok($r, 'git-autoupdate resource emitted');
	is($r->{type},           'git',           'type is git');
	is($r->{source}{branch}, 'auto-commits',  'branch is target_branch');
};

subtest 'target_branch: put uses git-autoupdate resource' => sub {
	my $ast = _ast_for(
		control_branch => 'main',
		auto_update    => {
			enabled       => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
			target_branch => 'auto-commits',
		},
	);
	my $job = _find_job(_describe($ast), 'update-genesis-assets');
	my ($put) = _plan_puts($job);

	is($put->{put},                'git-autoupdate', 'puts to git-autoupdate');
	is($put->{params}{repository}, 'git-autoupdate', 'repository param matches');
};

subtest 'target_branch equal to control branch: no git-autoupdate resource' => sub {
	my $ast = _ast_for(
		control_branch => 'main',
		auto_update    => {
			enabled       => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
			target_branch => 'main',
		},
	);
	ok(!_find_resource(_describe($ast), 'git-autoupdate'), 'no extra resource needed');
};

# =========================================================================
# 11. ASTBuilder normalization: v2 keys mapped correctly
# =========================================================================
subtest 'ASTBuilder: kit_version_file normalized to file' => sub {
	my $ast = _ast_via_builder(auto_update => {
		enabled          => 1,
		kit              => 'cf',
		org              => 'genesis-community',
		kit_version_file => 'lm.yml',
	});
	my $au = ($ast->configuration || {})->{auto_update};
	is($au->{file},    'lm.yml', 'file set from kit_version_file');
	is($au->{enabled}, 1,        'enabled preserved');
};

subtest 'ASTBuilder: commit_label normalized to label' => sub {
	my $ast = _ast_via_builder(auto_update => {
		enabled      => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
		commit_label => '[pipeline]',
	});
	my $au = ($ast->configuration || {})->{auto_update};
	is($au->{label}, '[pipeline]', 'label set from commit_label');
};

subtest 'ASTBuilder: enabled defaults to 1 when file is set (legacy compat)' => sub {
	my $ast = _ast_via_builder(auto_update => {
		kit => 'cf', org => 'genesis-community', file => 'lm.yml',
	});
	my $au = ($ast->configuration || {})->{auto_update};
	is($au->{enabled}, 1, 'enabled auto-set when file present');
};

subtest 'ASTBuilder: enabled defaults to 0 when no file and no explicit enabled' => sub {
	my $ast = _ast_via_builder(auto_update => {
		kit => 'cf', org => 'genesis-community',
	});
	my $au = ($ast->configuration || {})->{auto_update};
	is($au->{enabled}, 0, 'enabled defaults to 0 without file');
};

subtest 'ASTBuilder: update_genesis and update_kit default to 1' => sub {
	my $ast = _ast_via_builder(auto_update => {
		enabled => 1, kit => 'cf', org => 'genesis-community', file => 'lm.yml',
	});
	my $au = ($ast->configuration || {})->{auto_update};
	is($au->{update_genesis}, 1, 'update_genesis defaults to 1');
	is($au->{update_kit},     1, 'update_kit defaults to 1');
};

done_testing;
