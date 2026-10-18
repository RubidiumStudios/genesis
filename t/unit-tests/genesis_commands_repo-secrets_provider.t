#!perl
# Proves T407: genesis secrets-provider reads the configuration in repair
# mode, as genesis config does, so it answers on a file the load refuses
# (runbook finding 32).  A change it would save is still judged on its
# result, which names what the load would refuse.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;
use Test::Exit;

use Genesis qw/mkfile_or_fail mkdir_or_fail slurp pushd popd run/;
use Genesis::Commands;
use Genesis::Exit;
require Genesis::Commands::Repo;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

require './bin/genesis';

subtest 'secrets-provider reads a configuration the load refuses' => sub {
	plan tests => 3;

	# The rc builds' ci block, which every other command refuses at load.
	scrub_git_env();
	my $dir = workdir('secrets-provider-repair');
	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<'EOF');
---
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
ci:
  enabled: true
version: 3
EOF
	run({dir => $dir}, 'git', 'init', '-q');
	my $before = slurp("$dir/.genesis/config");

	pushd $dir;
	prepare_command('secrets-provider');
	build_command_environment;
	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my $code;
	my ($out, $err) = output_from {$code = exit_code {Genesis::Commands::Repo::secrets_provider()}};
	popd;

	is($code, 0, 'the read answers');
	like("$out$err", qr/Secrets provider for test-kit deployment/, 'with the provider it found');
	is(slurp("$dir/.genesis/config"), $before, 'and writes nothing');
};

done_testing;
