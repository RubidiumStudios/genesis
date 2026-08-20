#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;

# Explicit import: Genesis exports its own workdir() which would otherwise
# clobber helper's.
use Genesis qw/mkdir_or_fail mkfile_or_fail slurp pushd popd/;
use Genesis::Commands;
use Genesis::Commands::Core;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# Registers the commands and runs Genesis::Init, which prepare_command and
# the logger both depend on.
require './bin/genesis';

sub config_repo {
	my ($name) = @_;
	my $dir = workdir($name);
	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<'EOF');
---
ci:
  enabled: true
  provider:
    type: manual
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
version: 3
EOF
	return $dir;
}

subtest 'config with no arguments dumps the repository configuration' => sub {
	plan tests => 1;

	pushd config_repo('config-dump');
	prepare_command('config');
	build_command_environment;
	my $out = stdout_from { Genesis::Commands::Core::config() };
	popd;

	like($out, qr/manifest_store:\s*exodus/,
		"dump reports the repository's manifest_store");
};

subtest 'config with one argument prints that value' => sub {
	plan tests => 1;

	pushd config_repo('config-get');
	prepare_command('config');
	build_command_environment;
	my $out = stdout_from { Genesis::Commands::Core::config('manifest_store') };
	popd;

	is($out, "exodus\n", "prints the bare scalar, without YAML framing");
};

subtest 'config resolves a dotted path' => sub {
	plan tests => 1;

	pushd config_repo('config-get-dotted');
	prepare_command('config');
	build_command_environment;
	my $out = stdout_from { Genesis::Commands::Core::config('ci.provider.type') };
	popd;

	is($out, "manual\n", "walks into nested keys");
};

subtest 'config renders a non-scalar key as YAML' => sub {
	plan tests => 1;

	pushd config_repo('config-get-section');
	prepare_command('config');
	build_command_environment;
	my $out = stdout_from { Genesis::Commands::Core::config('ci') };
	popd;

	like($out, qr/^provider:\n(?:.*\n)*?\s+type:\s*manual$/m,
		"renders the section rather than stringifying the reference");
};

subtest 'config keeps values on stdout and messages off it' => sub {
	plan tests => 2;

	pushd config_repo('config-streams');
	prepare_command('config');
	build_command_environment;
	my ($out, $err) = output_from { Genesis::Commands::Core::config('manifest_store') };
	popd;

	is($out, "exodus\n", "the value goes to stdout");
	is($err, '', "nothing is written to stderr alongside it");
};

subtest 'config reports an unset key without pretending it is empty' => sub {
	plan tests => 3;

	pushd config_repo('config-unset');
	prepare_command('config');
	build_command_environment;
	my ($out, $err, $rc);
	($out, $err) = output_from { $rc = Genesis::Commands::Core::config('no_such_key') };
	popd;

	is($out, '', "prints nothing to stdout, so a script capturing it gets nothing");
	like($err, qr/\(unset\)/, "says the key is unset, on stderr");
	isnt($rc, 0, "exits non-zero so callers can branch on it");
};

subtest 'config --set persists a value' => sub {
	plan tests => 1;

	my $dir = config_repo('config-set');
	pushd $dir;
	prepare_command('config', '--set', 'manifest_store', 'repository');
	build_command_environment;
	output_from { Genesis::Commands::Core::config() };
	popd;

	like(slurp("$dir/.genesis/config"), qr/manifest_store:\s*repository/,
		"writes the new value to .genesis/config");
};

subtest 'config --set refuses a value the schema rejects' => sub {
	plan tests => 2;

	my $dir = config_repo('config-set-invalid');
	pushd $dir;
	prepare_command('config', '--set', 'manifest_store', 'nonsense');
	build_command_environment;
	# $@ has to be taken inside the block: popd runs before the assertions
	# and clears it.
	my $raised = '';
	my ($out, $err) = output_from {
		eval { Genesis::Commands::Core::config() };
		$raised = $@;
	};
	popd;

	like(slurp("$dir/.genesis/config"), qr/manifest_store:\s*exodus/,
		"leaves the original value on disk");
	like($err.$raised, qr/manifest_store/,
		"names the offending key");
};

done_testing;
