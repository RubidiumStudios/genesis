#!perl
# Proves T364 for the writers on Genesis::Top: what set_vault and
# set_kit_provider save is judged by the load's own checks, on the result,
# just before the save, and a result the load would refuse is refused and
# writes nothing.
#
# Each Top here has loaded and validated its configuration before the
# writer runs, which is what made the writers' own checks no-ops: the
# load marked itself done, and every later check returned at once.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;
use Test::Exit;

# Explicit import: Genesis also exports workdir(), which would shadow the
# helper's and break every fixture below.
use Genesis qw/mkfile_or_fail mkdir_or_fail slurp run load_yaml/;
use Genesis::Exit;

use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Top';
use_ok 'Service::Vault::Remote';

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# A version 3 repository with a manual pipeline turned on, whose repository
# is derived from its GitHub remote rather than written down.
sub writer_repo {
	my ($name) = @_;
	scrub_git_env();
	my $dir = workdir($name);
	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<'EOF');
---
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
pipeline:
  enabled: true
  provider:
    type: manual
secrets_provider:
  alias: old-target
  url: https://old.example.com
version: 3
EOF
	run({dir => $dir}, 'git', 'init', '-q');
	run({dir => $dir}, 'git', 'remote', 'add', 'origin',
		'https://github.com/genesis/test-kit-deployments.git');
	return $dir;
}

# A Top over the repository whose configuration has been loaded, and so
# validated once, the way any command's has by the time it writes.
sub loaded_top {
	my ($dir) = @_;
	my $top = Genesis::Top->new($dir, no_vault => 1);
	$top->config;
	$top->_source_control;
	return $top;
}

sub new_vault {
	return Service::Vault::Remote->new(
		'https://new.example.com', 'new-target', 1, '', undef, '/secret/');
}

# Runs a writer and reports how it ended and what it said.
sub write_with (&) {
	my ($writer) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my ($code, $err);
	$err = stderr_from { $code = exit_code { $writer->() } };
	return ($code, $err);
}

subtest 'set_vault refuses a result the load would refuse' => sub {
	plan tests => 3;

	my $dir = writer_repo('writer-set-vault');
	my $before = slurp("$dir/.genesis/config");
	my $top = loaded_top($dir);

	# Something earlier in the run left a key no schema declares.
	$top->config->set('nonesuch', 'x');

	my ($code, $err) = write_with { $top->set_vault(vault => new_vault()) };

	is($code, Genesis::Exit::CONFIG, 'the save is refused at the configuration exit');
	like($err, qr/nonesuch: unknown configuration key/, 'naming what the load would refuse');
	is(slurp("$dir/.genesis/config"), $before, 'and nothing is written');
};

subtest 'set_kit_provider refuses a result the load would refuse' => sub {
	plan tests => 3;

	my $dir = writer_repo('writer-set-kit-provider');
	my $before = slurp("$dir/.genesis/config");
	my $top = loaded_top($dir);

	$top->config->set('nonesuch', 'x');

	my ($code, $err) = write_with { $top->set_kit_provider() };

	is($code, Genesis::Exit::CONFIG, 'the save is refused at the configuration exit');
	like($err, qr/nonesuch: unknown configuration key/, 'naming what the load would refuse');
	is(slurp("$dir/.genesis/config"), $before, 'and nothing is written');
};

subtest 'a writer judges the repository it would save by its rule' => sub {
	plan tests => 3;

	# The repository's syntax is the schema's own rule for the key (T365), so
	# a writer that has changed it since the load is judged on the new value.
	# Whether a remote points at it is not the writer's to ask.
	my $dir = writer_repo('writer-source-control');
	my $before = slurp("$dir/.genesis/config");
	my $top = loaded_top($dir);

	$top->config->set('pipeline.source_control.repository', 'not a repository');

	my ($code, $err) = write_with { $top->set_vault(vault => new_vault()) };

	is($code, Genesis::Exit::CONFIG, 'the save is refused at the configuration exit');
	like($err, qr/names no\s+repository/, 'on the repository it would save');
	is(slurp("$dir/.genesis/config"), $before, 'and nothing is written');
};

# T505 (D174): a repository with a pipeline names its vault, so the writer
# that would take the name away is refused as any writer's result is.
subtest 'clearing the vault is refused under a pipeline' => sub {
	plan tests => 3;

	my $dir = writer_repo('writer-clear-vault');
	my $before = slurp("$dir/.genesis/config");
	my $top = loaded_top($dir);

	my ($code, $err) = write_with { $top->set_vault(clear => 1) };

	is($code, Genesis::Exit::CONFIG, 'the save is refused at the configuration exit');
	like($err, qr/secrets_provider: .*names none/s, 'naming the vault the pipeline needs');
	is(slurp("$dir/.genesis/config"), $before, 'and nothing is written');
};

# T509: every writer records the Genesis that wrote, through the one save
# they share.  Clearing the vault never did, the stamp having sat in the
# branch that sets one.
subtest 'a writer records the Genesis that wrote' => sub {
	plan tests => 3;

	local $Genesis::VERSION = '3.2.9';

	# No pipeline, so the vault may be cleared (D174), and last written by
	# an older Genesis.
	my $repo = sub {
		scrub_git_env();
		my $dir = workdir($_[0]);
		mkdir_or_fail("$dir/.genesis");
		mkfile_or_fail("$dir/.genesis/config", <<'EOF');
---
creator_version: 3.1.0
deployment_type: test-kit
secrets_provider:
  alias: old-target
  url: https://old.example.com
updater_version: 3.1.0
version: 3
EOF
		run({dir => $dir}, 'git', 'init', '-q');
		run({dir => $dir}, 'git', 'remote', 'add', 'origin',
			'https://github.com/genesis/test-kit-deployments.git');
		return $dir;
	};
	my $stamp = sub {load_yaml(slurp("$_[0]/.genesis/config"))->{updater_version}};

	my $cleared = $repo->('writer-stamp-clear');
	write_with { loaded_top($cleared)->set_vault(clear => 1) };
	is($stamp->($cleared), '3.2.9', 'clearing the vault records it');

	my $pointed = $repo->('writer-stamp-point');
	write_with { loaded_top($pointed)->set_vault(vault => new_vault()) };
	is($stamp->($pointed), '3.2.9', 'so does pointing at another');

	my $kits = $repo->('writer-stamp-kits');
	write_with { loaded_top($kits)->set_kit_provider() };
	is($stamp->($kits), '3.2.9', 'and so does setting the kit provider');
};

# T506: genesis secrets-provider changes the secrets_provider block and the
# updater's version, and nothing else the file holds.  The file is read back
# from disk, since what the next command loads is what matters.
subtest 'a re-point leaves every key outside the block as it was' => sub {
	plan tests => 4;

	scrub_git_env();
	my $dir = workdir('writer-repoint-keeps');
	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<'EOF');
---
creator_version: 3.1.0
deployment_type: test-kit
manifest_store: exodus
minimum_version: 3.1.0
kit_provider:
  type: github
  organization: example-org
  domain: github.example.com
deployment_change_reason_required_size: 12
confirm_release_overrides: outdated
pipeline:
  enabled: true
  name: test-kit
  exodus_mount: /secret/exodus/
  provider:
    type: concourse
    url: https://ci.example.com
    team: main
    secrets_store:
      path_prefix: /concourse
      shared_path: common
  source_control:
    repository: example-org/test-kit-deployments
    control_branch: trunk
    auth:
      type: ssh
      path: ci/git
    identity:
      name: Genesis CI
  vault:
    auth:
      type: approle
      path: ci/vault
      secret_id: ci/other:sid
  locker:
    url: https://locker.example.com
  shuttle:
    backend: s3
    bucket: pipes
    auth:
      access_key_id: bucket:aws_access_key_id
      secret_access_key: bucket:aws_secret_access_key
  notifications:
    slack:
      webhook: ci/slack:webhook
      channel: '#deploys'
secrets_provider:
  alias: old-target
  url: https://old.example.com
  insecure: true
  namespace: ops
  strongbox: false
version: 3
EOF
	run({dir => $dir}, 'git', 'init', '-q');
	run({dir => $dir}, 'git', 'remote', 'add', 'origin',
		'https://github.com/example-org/test-kit-deployments.git');

	my $before = load_yaml(slurp("$dir/.genesis/config"));
	my $top = loaded_top($dir);
	my ($code, $err) = write_with { $top->set_vault(vault => new_vault()) };
	is($code, undef, 'the re-point is saved') or diag($err);

	my $after = load_yaml(slurp("$dir/.genesis/config"));
	is($after->{secrets_provider}{url}, 'https://new.example.com', 'the block names the new vault');

	my %changed = map {($_ => 1)} qw/secrets_provider updater_version/;
	is_deeply([sort grep {!$changed{$_}} keys %$after], [sort grep {!$changed{$_}} keys %$before],
		'no top-level key is gained or lost');
	is_deeply({map {($_ => $after->{$_})} grep {!$changed{$_}} keys %$after},
		{map {($_ => $before->{$_})} grep {!$changed{$_}} keys %$before},
		'and every other value is as it was, the nested ones included');
};

# A new repository's configuration as Genesis::Top->create leaves it, before
# genesis init --with-ci writes the pipeline section, in a clone that has no
# remote yet, which is how init leaves it.  It names its vault, as init
# leaves one that was given a vault, and --with-ci is given no other (D174).
sub scaffold_repo {
	my ($name) = @_;
	scrub_git_env();
	my $dir = workdir($name);
	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<'EOF');
---
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
secrets_provider:
  alias: a-target
  url: https://vault.example.com
version: 3
EOF
	run({dir => $dir}, 'git', 'init', '-q');
	return $dir;
}

subtest "init's pipeline scaffold is judged before it is saved" => sub {
	plan tests => 3;

	# The scaffold takes any provider type, and an automated one written
	# with none of the keys it requires is a file the load refuses.
	require Genesis::Commands::Repo;
	my $dir = scaffold_repo('writer-scaffold-refused');
	my $before = slurp("$dir/.genesis/config");
	my $top = Genesis::Top->new($dir, no_vault => 1);
	$top->config;

	my ($code, $err) = write_with {
		Genesis::Commands::Repo::_create_pipeline_scaffold($top, provider => 'concourse')
	};

	is($code, Genesis::Exit::CONFIG, 'the save is refused at the configuration exit');
	like($err, qr/missing required key|is required/, "naming what the provider requires");
	is(slurp("$dir/.genesis/config"), $before, 'and nothing is written');
};

subtest "init's manual scaffold saves, with no remote to judge" => sub {
	plan tests => 2;

	# What init itself writes, judged as any writer's result is.  The clone
	# has no remote, and the judgement no longer asks it for one (T365).
	require Genesis::Commands::Repo;
	my $dir = scaffold_repo('writer-scaffold-manual');
	my $top = Genesis::Top->new($dir, no_vault => 1);
	$top->config;

	my ($code, $err) = write_with {
		Genesis::Commands::Repo::_create_pipeline_scaffold($top)
	};
	is($code, undef, 'the scaffold is saved');

	my ($load) = write_with { Genesis::Top->new($dir, no_vault => 1)->config };
	is($load, undef, 'and the next command loads it');
};

done_testing;
