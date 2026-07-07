#!perl
use strict;
use warnings;
use utf8;

# Unit coverage for `genesis repo-init` (alias: `init`) -- the CLI
# surface pieces that involve no filesystem writes: command
# registration and option-parsing shape.  The validate + execute
# phases actually create files/dirs/symlinks and run real git
# commits, so they live in the sibling integration-tests file.
#
# Subtests in this file:
#   1. Command registration -- spec snapshot: define_command in
#      bin/genesis, alias 'init' -> 'repo-init', option set,
#      function-group + scope + routing
#   2. Option parsing       -- prepare_command + get_options exercises
#
# The command spec assertions here are pinned against the CURRENT
# CLI, not legacy.  The `--sub`/`--no-sub` option was removed in
# favour of auto-detection via `Service::Git->is_inside_work_tree('.')`
# (Commands/Repo.pm:131).  The `--ci-provider` option was replaced
# by `--with-ci` (commit 2dbb3984, 2026-04-22): repo-init now only
# sets up the manual provider, with automated providers configured
# later via `genesis repo config ci` -- bootstrap circularity means
# we can't init with the very provider being deployed by this repo.
# `--force` was standardised to `-f` (commit 78da5319, 2026-04-19).

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use Genesis::Commands;
use PadWalker qw/closed_over/;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# Load the command registry by requiring bin/genesis (its main() is
# guarded with `unless caller`, so this only runs the define_command
# calls, not the CLI dispatcher).
subtest 'load command registry' => sub {
	plan tests => 1;
	require_ok './bin/genesis';
};

# ---------------------------------------------------------------------------
# Phase 1: command registration
# ---------------------------------------------------------------------------

subtest 'command registration' => sub {
	plan tests => 15;

	ok(has_command('repo-init'), 'repo-init command is registered');
	ok(is_equivalent_command('init' => 'repo-init'),
		'init is an alias for repo-init');
	like(command_properties('repo-init')->{usage},
		qr/repo-init.*\[.*options/,
		'usage string mentions repo-init and options');

	is(command_properties('repo-init')->{function_group},
		Genesis::Commands::REPOSITORY,
		'repo-init belongs to repository group');
	is(command_properties('repo-init')->{scope}, 'empty',
		'repo-init has empty scope (no existing repo needed)');

	my %opts = command_properties('repo-init')->{options}->@*;

	ok(exists $opts{'kit|k=s'},          'repo-init has --kit (-k) option');
	ok(exists $opts{'link-dev-kit|l=s'}, 'repo-init has --link-dev-kit (-l) option');
	ok(exists $opts{'directory|d=s'},    'repo-init has --directory (-d) option');
	ok(exists $opts{'vault=s'},          'repo-init has --vault option');
	ok(exists $opts{'skip-vault'},       'repo-init has --skip-vault option');
	ok(exists $opts{'with-ci'},          'repo-init has --with-ci option (manual provider; full provider config via `repo config ci`)');
	ok(exists $opts{'force|f'},          'repo-init has --force (-f) option');

	ok(!command_properties('repo-init')->{deprecated},
		'repo-init is not deprecated');

	my $subref = $Genesis::Commands::RUN{'repo-init'};
	is(ref($subref), 'CODE',
		'repo-init command has a subroutine reference');
	cmp_deeply(scalar(closed_over($subref)), {
		'$fn'         => \'Genesis::Commands::Repo::repo_init',
		'$fn_require' => \'Genesis/Commands/Repo.pm',
		'$name'       => \'repo-init',
	}, 'repo-init routes to Genesis::Commands::Repo::repo_init');
};

# ---------------------------------------------------------------------------
# Phase 2: option parsing -- prepare_command + get_options shape
# ---------------------------------------------------------------------------

subtest 'option parsing' => sub {
	plan tests => 15;

	# Basic invocation
	prepare_command('repo-init', '-k', 'bosh', 'my-bosh');
	build_command_environment;
	my %opts = %{get_options()};
	my @args = get_args();
	is($opts{kit}, 'bosh', 'kit option parsed');
	is($args[0],   'my-bosh', 'name positional parsed');

	# --skip-vault
	prepare_command('repo-init', '-k', 'bosh', '--skip-vault', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	ok($opts{'skip-vault'}, '--skip-vault flag is set');
	ok(!$opts{vault},       '--vault is not set when --skip-vault used');

	# --vault
	prepare_command('repo-init', '-k', 'bosh', '--vault', 'my-vault', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{vault},        'my-vault', '--vault value parsed');
	ok(!$opts{'skip-vault'}, '--skip-vault not set when --vault specified');

	# --with-ci (boolean; sets up the manual provider at init time)
	prepare_command('repo-init', '-k', 'bosh', '--with-ci', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	ok($opts{'with-ci'}, '--with-ci flag is set');

	# --directory (-d)
	prepare_command('repo-init', '-k', 'bosh', '-d', '/tmp/my-repo', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{directory}, '/tmp/my-repo', '--directory (-d) parsed');

	# --link-dev-kit (-l)
	prepare_command('repo-init', '-l', '/path/to/dev-kit', 'my-dev');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{'link-dev-kit'}, '/path/to/dev-kit', '--link-dev-kit (-l) parsed');
	ok(!$opts{kit},           '--kit not set when --link-dev-kit used');

	# Name omitted entirely (validate phase derives it from kit)
	prepare_command('repo-init', '-k', 'shield');
	build_command_environment;
	@args = get_args();
	is(scalar(@args), 0, 'no positional args when name omitted');

	# All options together
	prepare_command('repo-init',
		'-k', 'bosh',
		'--with-ci', '--skip-vault',
		'-d', '/tmp/test',
		'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	@args = get_args();
	is($opts{kit},      'bosh',       'combined: kit parsed');
	is($args[0],        'my-bosh',    'combined: name parsed');
	ok($opts{'with-ci'},              'combined: --with-ci set');
	ok($opts{'skip-vault'},           'combined: --skip-vault set');
};
done_testing;
