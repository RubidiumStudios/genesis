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

subtest 'a writer judges the source control it would save, not the one it loaded' => sub {
	plan tests => 3;

	# The load worked out where the pipeline lives and kept the answer.  A
	# writer that has since changed the repository has to be judged on the
	# new value, not on the answer kept from before.
	my $dir = writer_repo('writer-source-control');
	my $before = slurp("$dir/.genesis/config");
	my $top = loaded_top($dir);

	$top->config->set('pipeline.source_control.repository', 'not a repository');

	my ($code, $err) = write_with { $top->set_vault(vault => new_vault()) };

	is($code, Genesis::Exit::CONFIG, 'the save is refused at the configuration exit');
	like($err, qr/names no\s+repository/, 'on the repository it would save');
	is(slurp("$dir/.genesis/config"), $before, 'and nothing is written');
};

done_testing;
