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

done_testing;
