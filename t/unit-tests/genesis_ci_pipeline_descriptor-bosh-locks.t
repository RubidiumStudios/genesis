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

sub _node {
	my (%o) = @_;
	return {
		alias               => $o{alias}             || $o{env},
		stage_name          => $o{env},
		genesis_env         => $o{env},
		auto                => $o{auto}              // 0,
		type                => 'deployment',
		require_pr          => 0,
		manual              => 0,
		redeploy            => '',
		redeploy_cron_start => '',
		redeploy_cron_stop  => '',
		status_signal       => '',
		signal_prefix       => '',
		bosh_parent         => $o{bosh_parent}       || '',
		bosh_upgrade_lock   => $o{bosh_upgrade_lock} // 1,
	};
}

sub _target {
	my (%o) = @_;
	return $o{create_env}
		? { type => 'bosh-create-env' }
		: {
			type       => 'bosh-director',
			connection => {
				url     => $o{url} || 'https://bosh.example.com:25555',
				ca_cert => 'fake-ca',
				auth    => { client_id => 'admin', client_secret => 'secret' },
			},
		};
}

# Build an AST with one or more envs.
# envs: arrayref of hashrefs (env, alias, bosh_parent, bosh_upgrade_lock, create_env, url)
# with_locker: 0/1
# edges: arrayref of {from, to} hashrefs
sub _ast {
	my (%o) = @_;

	my (%nodes, %targets);
	for my $spec (@{$o{envs}}) {
		my $env = $spec->{env};
		$nodes{$env}   = _node(%$spec);
		$targets{$env} = _target(%$spec);
	}

	my %integrations = (
		source_control => { provider => 'github', repository => 'org/repo' },
		vault          => { url => 'https://vault.example.com' },
	);
	if ($o{with_locker}) {
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
		configuration => {
			task     => { image => 'genesiscommunity/concourse', version => 'latest' },
			registry => {},
		},
	);
}

sub _describe {
	my ($ast) = @_;
	Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast)->describe();
}

sub _mermaid {
	my ($ast) = @_;
	Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast)->mermaid();
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

sub _do_block {
	my ($job) = @_;
	return ($job->{plan}[0] || {})->{do} || [];
}

sub _ensure_do {
	my ($job) = @_;
	return (($job->{plan}[0] || {})->{ensure} || {})->{do} || [];
}

# Returns all put steps in a do-block that are locker operations
sub _lock_puts {
	my ($do) = @_;
	return grep {
		ref $_ eq 'HASH'
		&& exists $_->{put}
		&& ref($_->{params}) eq 'HASH'
		&& exists $_->{params}{lock_op}
	} @$do;
}

# =========================================================================
# 1. Standalone env: per-env bosh-lock uses bosh_lock (URL), deployment-lock uses lock_name
# =========================================================================
subtest 'Standalone env: bosh-lock uses bosh_lock URL source' => sub {
	my $ast      = _ast(
		envs        => [{ env => 'sandbox', url => 'https://bosh.sb:25555' }],
		with_locker => 1,
	);
	my $pipeline = _describe($ast);

	my $bl = _find_resource($pipeline, 'sandbox-bosh-lock');
	ok $bl, 'sandbox-bosh-lock resource emitted';
	is $bl->{type}, 'locker', 'type is locker';
	like $bl->{source}{bosh_lock}, qr{https://bosh\.sb}, 'source.bosh_lock is BOSH URL';
	ok !$bl->{source}{lock_name}, 'no lock_name for standalone bosh-lock';

	my $dl = _find_resource($pipeline, 'sandbox-deployment-lock');
	ok $dl, 'sandbox-deployment-lock resource emitted';
	like $dl->{source}{lock_name}, qr/sandbox-deployment/, 'deployment-lock uses lock_name';
};

# =========================================================================
# 2. Director env: bosh-lock uses lock_name (not bosh_lock URL)
# =========================================================================
subtest 'Director env: bosh-lock uses lock_name, not bosh_lock URL' => sub {
	my $ast = _ast(
		envs => [
			{ env => 'bosh-lab',  url => 'https://bosh.lab:25555' },
			{ env => 'cf-lab',    bosh_parent => 'bosh-lab' },
		],
		with_locker => 1,
	);
	my $pipeline = _describe($ast);

	my $bl = _find_resource($pipeline, 'bosh-lab-bosh-lock');
	ok $bl, 'bosh-lab-bosh-lock resource emitted';
	is $bl->{source}{lock_name}, 'bosh-lab-bosh-upgrade', 'lock_name is <alias>-bosh-upgrade';
	ok !$bl->{source}{bosh_lock}, 'no bosh_lock URL in director lock source';
};

# =========================================================================
# 3. Child env: no own bosh-lock resource; only deployment-lock
# =========================================================================
subtest 'Child env: no own bosh-lock resource, only deployment-lock' => sub {
	my $ast = _ast(
		envs => [
			{ env => 'bosh-lab' },
			{ env => 'cf-lab',  bosh_parent => 'bosh-lab' },
		],
		with_locker => 1,
	);
	my $pipeline = _describe($ast);

	my $own_bl = _find_resource($pipeline, 'cf-lab-bosh-lock');
	ok !$own_bl, 'child cf-lab has no own bosh-lock resource';

	my $dl = _find_resource($pipeline, 'cf-lab-deployment-lock');
	ok $dl, 'child cf-lab has deployment-lock resource';
};

# =========================================================================
# 4. Director deploy job acquires its own bosh-lock with correct key
# =========================================================================
subtest 'Director deploy job: acquires own bosh-lock (dont-upgrade-bosh-on-me)' => sub {
	my $ast = _ast(
		envs => [
			{ env => 'bosh-lab' },
			{ env => 'cf-lab', bosh_parent => 'bosh-lab' },
		],
		with_locker => 1,
	);
	my $pipeline = _describe($ast);
	my $job      = _find_job($pipeline, 'bosh-lab-deployment');
	my @locks    = _lock_puts(_do_block($job));

	my ($bosh_lock) = grep { $_->{put} eq 'bosh-lab-bosh-lock' } @locks;
	ok $bosh_lock, 'director job locks bosh-lab-bosh-lock';
	is $bosh_lock->{params}{key}, 'dont-upgrade-bosh-on-me', 'key is dont-upgrade-bosh-on-me';
	is $bosh_lock->{params}{lock_op}, 'lock', 'lock_op is lock';

	my ($deploy_lock) = grep { $_->{put} eq 'bosh-lab-deployment-lock' } @locks;
	ok $deploy_lock, 'director job also locks bosh-lab-deployment-lock';
	is $deploy_lock->{params}{key}, 'i-need-to-deploy-myself', 'key is i-need-to-deploy-myself';
};

# =========================================================================
# 5. Child deploy job acquires director's bosh-lock, not its own
# =========================================================================
subtest 'Child deploy job: acquires director bosh-lock, not own' => sub {
	my $ast = _ast(
		envs => [
			{ env => 'bosh-lab' },
			{ env => 'cf-lab', bosh_parent => 'bosh-lab' },
		],
		with_locker => 1,
	);
	my $pipeline = _describe($ast);
	my $job      = _find_job($pipeline, 'cf-lab-deployment');
	my @locks    = _lock_puts(_do_block($job));

	my ($dir_lock) = grep { $_->{put} eq 'bosh-lab-bosh-lock' } @locks;
	ok $dir_lock, 'child job acquires bosh-lab-bosh-lock (director)';
	is $dir_lock->{params}{key},      'dont-upgrade-bosh-on-me', 'key is dont-upgrade-bosh-on-me';
	is $dir_lock->{params}{locked_by}, 'cf-lab-deployment',       'locked_by is cf-lab-deployment';

	my ($own_lock) = grep { $_->{put} eq 'cf-lab-bosh-lock' } @locks;
	ok !$own_lock, 'child job does NOT acquire cf-lab-bosh-lock';

	my ($deploy_lock) = grep { $_->{put} eq 'cf-lab-deployment-lock' } @locks;
	ok $deploy_lock, 'child job still acquires cf-lab-deployment-lock';
};

# =========================================================================
# 6. Unlock steps mirror lock steps
# =========================================================================
subtest 'Deploy job: ensure block has matching unlock steps' => sub {
	my $ast = _ast(
		envs => [
			{ env => 'bosh-lab' },
			{ env => 'cf-lab', bosh_parent => 'bosh-lab' },
		],
		with_locker => 1,
	);
	my $pipeline   = _describe($ast);
	my $job        = _find_job($pipeline, 'cf-lab-deployment');
	my @unlocks    = _lock_puts(_ensure_do($job));

	my ($dir_unlock) = grep { $_->{put} eq 'bosh-lab-bosh-lock' } @unlocks;
	ok $dir_unlock, 'ensure block unlocks bosh-lab-bosh-lock';
	is $dir_unlock->{params}{lock_op}, 'unlock', 'lock_op is unlock';

	my ($deploy_unlock) = grep { $_->{put} eq 'cf-lab-deployment-lock' } @unlocks;
	ok $deploy_unlock, 'ensure block unlocks cf-lab-deployment-lock';
};

# =========================================================================
# 7. Opt-out (bosh_upgrade_lock: false): child treated as standalone
# =========================================================================
subtest 'Opt-out (bosh_upgrade_lock=false): child gets own bosh-lock, not director lock' => sub {
	my $ast = _ast(
		envs => [
			{ env => 'bosh-lab', url => 'https://bosh.lab:25555' },
			{ env => 'cf-lab', bosh_parent => 'bosh-lab', bosh_upgrade_lock => 0,
			  url => 'https://bosh.lab:25555' },
		],
		with_locker => 1,
	);
	my $pipeline = _describe($ast);

	my $own_bl = _find_resource($pipeline, 'cf-lab-bosh-lock');
	ok $own_bl, 'cf-lab gets own bosh-lock when bosh_upgrade_lock=false';
	like $own_bl->{source}{bosh_lock}, qr{https://bosh\.lab}, 'source.bosh_lock is BOSH URL';

	my $job   = _find_job($pipeline, 'cf-lab-deployment');
	my @locks = _lock_puts(_do_block($job));

	my ($own_lock) = grep { $_->{put} eq 'cf-lab-bosh-lock' } @locks;
	ok $own_lock, 'opt-out child acquires own bosh-lock';

	my ($dir_lock) = grep { $_->{put} eq 'bosh-lab-bosh-lock' } @locks;
	ok !$dir_lock, 'opt-out child does NOT acquire director bosh-lock';
};

# =========================================================================
# 8. Multi-child: both children acquire the same director lock resource
# =========================================================================
subtest 'Multi-child: both children acquire the shared director bosh-lock' => sub {
	my $ast = _ast(
		envs => [
			{ env => 'bosh-lab' },
			{ env => 'cf-lab',  bosh_parent => 'bosh-lab' },
			{ env => 'shield',  bosh_parent => 'bosh-lab' },
		],
		with_locker => 1,
	);
	my $pipeline = _describe($ast);

	# Only one bosh-lab-bosh-lock resource
	my @director_locks = grep { ($_->{name} || '') eq 'bosh-lab-bosh-lock' }
		@{$pipeline->{resources}};
	is scalar(@director_locks), 1, 'exactly one bosh-lab-bosh-lock resource emitted';

	# cf-lab job acquires director lock
	my $cf_job    = _find_job($pipeline, 'cf-lab-deployment');
	my @cf_locks  = _lock_puts(_do_block($cf_job));
	my ($cf_dir)  = grep { $_->{put} eq 'bosh-lab-bosh-lock' } @cf_locks;
	ok $cf_dir, 'cf-lab job acquires bosh-lab-bosh-lock';

	# shield job acquires director lock
	my $sh_job    = _find_job($pipeline, 'shield-deployment');
	my @sh_locks  = _lock_puts(_do_block($sh_job));
	my ($sh_dir)  = grep { $_->{put} eq 'bosh-lab-bosh-lock' } @sh_locks;
	ok $sh_dir, 'shield job acquires bosh-lab-bosh-lock';

	# Neither child has its own bosh-lock resource
	ok !_find_resource($pipeline, 'cf-lab-bosh-lock'),  'cf-lab has no own bosh-lock';
	ok !_find_resource($pipeline, 'shield-bosh-lock'),   'shield has no own bosh-lock';
};

# =========================================================================
# 9. bosh-create-env director: lock_name-based lock (no BOSH URL available)
# =========================================================================
subtest 'bosh-create-env director: bosh-lock uses lock_name, not bosh_lock URL' => sub {
	my $ast = _ast(
		envs => [
			{ env => 'bosh-mgmt', create_env => 1 },
			{ env => 'cf-mgmt',   bosh_parent => 'bosh-mgmt' },
		],
		with_locker => 1,
	);
	my $pipeline = _describe($ast);

	my $bl = _find_resource($pipeline, 'bosh-mgmt-bosh-lock');
	ok $bl, 'bosh-mgmt-bosh-lock resource emitted';
	is $bl->{source}{lock_name}, 'bosh-mgmt-bosh-upgrade',
		'lock_name is bosh-mgmt-bosh-upgrade (not URL-based)';
	ok !$bl->{source}{bosh_lock},
		'no bosh_lock URL in create-env director lock source';
};

# =========================================================================
# 10. Error: bosh_parent set but no locker configured
# =========================================================================
subtest 'Error: bosh_parent with no locker integration causes bail' => sub {
	my $ast = _ast(
		envs => [
			{ env => 'bosh-lab' },
			{ env => 'cf-lab', bosh_parent => 'bosh-lab' },
		],
		with_locker => 0,   # no locker!
	);
	my $d = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);

	my $err;
	eval { $d->describe(); 1 } or do { $err = $@ };

	ok $err, 'describe() died when bosh_parent set but no locker';
	like $err, qr/locker/i,        'error mentions locker';
	like $err, qr/bosh_upgrade/i, 'error mentions bosh_upgrade opt-out';
	like $err, qr/cf-lab/i,        'error names the offending env';
	like $err, qr/bosh-lab/i,      'error names the parent director';
};

# =========================================================================
# 11. Redeploy job: same BOSH lock topology as deploy job
# =========================================================================
subtest 'Redeploy job: child acquires director bosh-lock, not own' => sub {
	my $ast = _ast(
		envs => [
			{ env => 'bosh-lab' },
			{ env => 'cf-lab', bosh_parent => 'bosh-lab',
			  redeploy => 'manual' },
		],
		with_locker => 1,
	);

	# Patch redeploy into the node so the redeploy job is emitted
	my $node = $ast->workflows->{default}{graph}{nodes}{'cf-lab'};
	$node->{redeploy} = 'manual';

	my $pipeline = _describe($ast);
	my $rj       = _find_job($pipeline, 'redeploy-cf-lab');
	ok $rj, 'redeploy-cf-lab job emitted';

	my @locks   = _lock_puts(_do_block($rj));
	my ($dlock) = grep { $_->{put} eq 'bosh-lab-bosh-lock' } @locks;
	ok $dlock, 'redeploy job acquires bosh-lab-bosh-lock (director)';
	is $dlock->{params}{locked_by}, 'cf-lab-redeploy',
		'locked_by is cf-lab-redeploy';
};

# =========================================================================
# 12. ASTBuilder reads genesis.bosh_env from env files
# =========================================================================
subtest 'ASTBuilder reads genesis.bosh_env and sets bosh_parent on child nodes' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	_write("$tmp/bosh-lab.yml", <<'YAML');
---
genesis:
  env: bosh-lab
  pipeline: {}
YAML

	_write("$tmp/cf-lab.yml", <<'YAML');
---
genesis:
  env: cf-lab
  bosh_env: bosh-lab
  pipeline:
    prior_env: bosh-lab
YAML

	_write("$tmp/shield.yml", <<'YAML');
---
genesis:
  env: shield
  bosh_env: bosh-lab
  pipeline:
    prior_env: bosh-lab
YAML

	_write("$tmp/prod.yml", <<'YAML');
---
genesis:
  env: prod
  bosh_env: external-bosh
  pipeline: {}
YAML

	my $builder = Genesis::CI::Compiler::ASTBuilder->new(env_dir => $tmp);
	my $parsed  = {
		_source_format  => 'multi-file',
		env_dir         => $tmp,
		pipeline        => {},
		targets         => {},
		integrations    => {},
		scripts         => {},
		provider_config => {},
	};
	my $ast   = $builder->build($parsed, {});
	my $nodes = $ast->workflows->{default}{graph}{nodes};

	is $nodes->{'cf-lab'}{bosh_parent},  'bosh-lab',
		'cf-lab: bosh_parent=bosh-lab (director in same pipeline)';
	is $nodes->{shield}{bosh_parent},    'bosh-lab',
		'shield: bosh_parent=bosh-lab (director in same pipeline)';
	is $nodes->{'bosh-lab'}{bosh_parent}, '',
		'bosh-lab: no bosh_parent (it is the director)';
	is $nodes->{prod}{bosh_parent}, '',
		'prod: bosh_parent empty (external-bosh not in pipeline)';
};

# =========================================================================
# 13. ASTBuilder: bosh_upgrade_lock: false opt-out is respected
# =========================================================================
subtest 'ASTBuilder: bosh_upgrade_lock: false disables lock for that env' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	_write("$tmp/bosh-lab.yml", <<'YAML');
---
genesis:
  env: bosh-lab
  pipeline: {}
YAML

	_write("$tmp/cf-lab.yml", <<'YAML');
---
genesis:
  env: cf-lab
  bosh_env: bosh-lab
  pipeline:
    prior_env: bosh-lab
    locks:
      bosh_upgrade: false
YAML

	my $builder = Genesis::CI::Compiler::ASTBuilder->new(env_dir => $tmp);
	my $parsed  = {
		_source_format  => 'multi-file',
		env_dir         => $tmp,
		pipeline        => {},
		targets         => {},
		integrations    => {},
		scripts         => {},
		provider_config => {},
	};
	my $ast   = $builder->build($parsed, {});
	my $nodes = $ast->workflows->{default}{graph}{nodes};

	is $nodes->{'cf-lab'}{bosh_parent},       'bosh-lab',
		'cf-lab: bosh_parent still set';
	is $nodes->{'cf-lab'}{bosh_upgrade_lock}, 0,
		'cf-lab: bosh_upgrade_lock=0 (opt-out)';
};

# =========================================================================
# 14. Mermaid: director node gets DIRECTOR annotation
# =========================================================================
subtest 'Mermaid: director node annotated with DIRECTOR label' => sub {
	my $ast = _ast(
		envs => [
			{ env => 'bosh-lab' },
			{ env => 'cf-lab', bosh_parent => 'bosh-lab' },
		],
		edges       => [{ from => 'bosh-lab', to => 'cf-lab' }],
		with_locker => 1,
	);
	my $mermaid = _mermaid($ast);

	like   $mermaid, qr/bosh-lab.*DIRECTOR/,  'bosh-lab node includes DIRECTOR annotation';
	unlike $mermaid, qr/cf-lab.*DIRECTOR/,    'cf-lab child does not get DIRECTOR label';
};

done_testing;
