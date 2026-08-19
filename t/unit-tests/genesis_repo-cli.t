#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Output;
use Test::Exit;

use Genesis::Commands;
use PadWalker qw/closed_over/;
use Genesis;

# Initialize the Genesis environment
$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# Registers the commands this file asserts against.
require './bin/genesis';

subtest 'genesis repo-init' => sub {
	plan tests => 23;

	ok(has_command('repo-init'), "repo-init command is registered");
	ok(is_equivalent_command('init' => 'repo-init'), "init is an alias for repo-init");
	is($Genesis::Commands::GENESIS_COMMANDS{init}, 'repo-init',
		"init alias resolves to repo-init");

	like(command_properties('repo-init')->{usage}, qr/repo-init.*options/,
		"usage string mentions repo-init and options");

	is(command_properties('repo-init')->{function_group}, Genesis::Commands::REPOSITORY,
		"repo-init belongs to the repository group");
	is(command_properties('repo-init')->{scope}, 'empty',
		"repo-init has empty scope (it creates the repo it would otherwise need)");
	ok(command_properties('repo-init')->{no_vault},
		"repo-init runs without a vault");

	my %opts = command_properties('repo-init')->{options}->@*;
	ok(exists $opts{'kit|k=s'},          "repo-init has --kit option");
	ok(exists $opts{'link-dev-kit|l=s'}, "repo-init has --link-dev-kit option");
	ok(exists $opts{'kits-path|K:s'},    "repo-init has --kits-path option");
	ok(exists $opts{'vault=s'},          "repo-init has --vault option");
	ok(exists $opts{'directory|d=s'},    "repo-init has --directory option");
	ok(exists $opts{'no-commit'},        "repo-init has --no-commit option");
	ok(exists $opts{'reason=s'},         "repo-init has --reason option");
	ok(exists $opts{'force|f'},          "repo-init has --force option");
	ok(exists $opts{'skip-vault'},       "repo-init has --skip-vault option");
	ok(exists $opts{'with-ci'},          "repo-init has --with-ci option");
	is(scalar(keys %opts), 10, "repo-init only has the 10 options above");

	my %args = command_properties('repo-init')->{arguments}->@*;
	is(scalar(keys %args), 1, "repo-init has one argument");
	ok(exists $args{'name?'}, "repo-init has an optional 'name' argument");

	not_ok(command_properties('repo-init')->{deprecated}, "repo-init is not deprecated");

	my $subref = $Genesis::Commands::RUN{'repo-init'};
	is(ref($subref), 'CODE', "repo-init command has a subroutine reference");
	cmp_deeply(scalar(closed_over($subref)), {
		'$fn' => \'Genesis::Commands::Repo::repo_init',
		'$fn_require' => \'Genesis/Commands/Repo.pm',
		'$name' => \'repo-init',
	}, "repo-init command routes to Repo::repo_init");
};

subtest 'repo-init option processing' => sub {
	plan tests => 12;

	prepare_command('repo-init', '-k', 'bosh', 'my-bosh');
	build_command_environment;
	my %opts = %{get_options()};
	my @args = get_args();
	is($opts{kit}, 'bosh', "kit option parsed correctly");
	is($args[0], 'my-bosh', "name argument passed through");
	ok(!$opts{'with-ci'}, "with-ci is off unless asked for");

	prepare_command('repo-init', '-k', 'bosh', '--with-ci', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	ok($opts{'with-ci'}, "--with-ci flag is set");

	prepare_command('repo-init', '-k', 'bosh', '--skip-vault', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	ok($opts{'skip-vault'}, "--skip-vault flag is set");
	ok(!$opts{vault}, "vault is not set when skip-vault is used");

	prepare_command('repo-init', '-k', 'bosh', '--vault', 'my-vault', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{vault}, 'my-vault', "--vault value parsed correctly");
	ok(!$opts{'skip-vault'}, "skip-vault not set when vault is specified");

	prepare_command('repo-init', '-k', 'bosh', '-d', 'some/dir', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{directory}, 'some/dir', "--directory value parsed correctly");

	prepare_command('repo-init', '-k', 'bosh', '--no-commit', '--reason', 'because', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	ok($opts{'no-commit'}, "--no-commit flag is set");
	is($opts{reason}, 'because', "--reason value parsed correctly");

	prepare_command('repo-init', '-l', 'dev/kit', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{'link-dev-kit'}, 'dev/kit', "--link-dev-kit value parsed correctly");
};

done_testing;
