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

subtest 'bin/genesis' => sub {

	require_ok './bin/genesis';

	# TODO: Add tests to make sure all the defined commands are valid in their definitions in general (ie: specify existing function groups, correct format of options, etc)

};

# Proves T323: one sweep reads the whole flag-carrying surface, so each
# command asserts the options its registration declares and the class
# marker it carries, and the retired seeding command is absent.
subtest 'the flag-carrying pipeline surface' => sub {

	# deploy is not in the sweep, because it declares no class until M13.
	my %surface = (
		'create' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [qw/prior-env=s require-pr manual no-commit reason=s/],
			# Green on arrival, and a guard rather than a proof: a step that
			# gave genesis new a flag to skip the control refresh would put
			# the ancestry check back on a stale tracking ref.
			absent  => [qw/no-fetch no-refresh/],
		},
		# propagate is the one command in the sweep whose whole registration
		# is read, rather than its flags alone.  D36 retired its argument,
		# D44 and D40 retired three of its flags, and D83 gave -y a new
		# meaning, so an option or an argument that came back would be a
		# decision reversed and not a flag added.  The four keys below are
		# read only where a command declares them.
		'propagate' => {
			class        => Genesis::Commands::PRE_DEPLOY,
			options      => [qw/dry-run|n yes|y force/],
			absent       => [qw/no-fetch no-refresh no-push commit=s/],
			exactly      => 3,
			arguments    => [],
			scope        => 'repo',
			group        => Genesis::Commands::PIPELINE,
			option_group => Genesis::Commands::REPO_OPTIONS,
		},
		'pipeline-status' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [qw/no-refresh/],
			absent  => [qw/no-fetch/],
		},
		'pipeline-apply' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [qw/dry-run|n yes|y/],
			absent  => [qw/platform|provider|p=s no-fetch/],
		},
		'pipeline-describe' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [],
			absent  => [qw/no-fetch no-refresh/],
		},
	);

	for my $cmd (sort keys %surface) {
		ok(has_command($cmd), "$cmd is registered");
		my %opts = @{command_properties($cmd)->{options} || []};
		ok(exists $opts{$_}, "$cmd declares $_")
			for @{$surface{$cmd}{options}};
		ok(!exists $opts{$_}, "$cmd does not declare $_")
			for @{$surface{$cmd}{absent}};
		is(command_properties($cmd)->{branch_class}, $surface{$cmd}{class},
			"$cmd carries the $surface{$cmd}{class} marker");

		is(scalar(keys %opts), $surface{$cmd}{exactly},
			"$cmd declares only the options read above")
			if exists $surface{$cmd}{exactly};
		cmp_deeply(command_properties($cmd)->{arguments},
			$surface{$cmd}{arguments},
			"$cmd takes the positional arguments it declares")
			if exists $surface{$cmd}{arguments};
		is(command_properties($cmd)->{scope}, $surface{$cmd}{scope},
			"$cmd is $surface{$cmd}{scope}-scoped")
			if exists $surface{$cmd}{scope};
		is(command_properties($cmd)->{function_group}, $surface{$cmd}{group},
			"$cmd belongs to the group it declares")
			if exists $surface{$cmd}{group};
		is(command_properties($cmd)->{option_group},
			$surface{$cmd}{option_group},
			"$cmd takes the option group it declares")
			if exists $surface{$cmd}{option_group};
	}

	# The seeding command is retired under D41, so it is not part of the
	# surface this sweep reads.  Green on arrival, and a guard against a
	# step that revives it.
	ok(!has_command('pipeline-prepare')
		|| command_properties('pipeline-prepare')->{retired},
		'the retired seeding command is absent from the flag-carrying set');
};

done_testing;
