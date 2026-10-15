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
use Genesis qw/mkfile_or_fail mkdir_or_fail slurp run/;
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

# A new repository's configuration as Genesis::Top->create leaves it, before
# genesis init --with-ci writes the pipeline section, in a clone that has no
# remote yet, which is how init leaves it.
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
