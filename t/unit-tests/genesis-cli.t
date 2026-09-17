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

subtest 'genesis propagate' => sub {
	plan tests => 11;

	ok(has_command('propagate'), "propagate command is registered");

	is(command_properties('propagate')->{function_group},
		Genesis::Commands::PIPELINE,
		"propagate belongs to the pipeline group");

	# Repo scope only: one run walks every environment in the repository,
	# so there is nothing for env scope to scope it to.
	is(command_properties('propagate')->{scope}, 'repo',
		"propagate is repo-scoped");

	is(command_properties('propagate')->{option_group},
		Genesis::Commands::REPO_OPTIONS,
		"propagate uses REPO_OPTIONS");

	my %opts = command_properties('propagate')->{options}->@*;
	ok(exists $opts{'dry-run|n'}, "propagate has a dry-run option");

	# -y is back, with a new meaning under D83.  It was retired when the
	# only thing that passed it was the deploy, and it returns as the
	# publish preview's pre-approval, which is the one question it answers
	# and the provider gate is not it.
	ok(exists $opts{'yes|y'},     "propagate has a yes option");

	ok(exists $opts{'force'},     "propagate has a force option");

	# The commit override and the push switch are gone.  Both let a caller
	# change what the run did, and a run the pipeline and the operator can
	# both make has to be the same run either way.
	ok(!exists $opts{'commit=s'},
		"propagate no longer accepts a commit option");
	ok(!exists $opts{'no-push'},
		"propagate no longer accepts a no-push option");

	is(scalar(keys %opts), 3, "propagate has only the three options above");

	my $args = command_properties('propagate')->{arguments};
	cmp_deeply($args, [], "propagate takes no positional arguments");
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
		'propagate' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [qw/dry-run|n yes|y force/],
			absent  => [qw/no-fetch no-refresh no-push commit=s/],
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
	}

	# The seeding command is retired under D41, so it is not part of the
	# surface this sweep reads.  Green on arrival, and a guard against a
	# step that revives it.
	ok(!has_command('pipeline-prepare')
		|| command_properties('pipeline-prepare')->{retired},
		'the retired seeding command is absent from the flag-carrying set');
};

done_testing;
