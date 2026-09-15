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
	plan tests => 10;

	ok(has_command('propagate'), "propagate command is registered");

	is(command_properties('propagate')->{function_group},
		Genesis::Commands::PIPELINE,
		"propagate belongs to the pipeline group");

	# Repo scope only: propagate takes the environment it cascades from as
	# a positional, because it means "start from here", not "operate on
	# this one" -- which is what env scope would imply.
	is(command_properties('propagate')->{scope}, 'repo',
		"propagate is repo-scoped");

	is(command_properties('propagate')->{option_group},
		Genesis::Commands::REPO_OPTIONS,
		"propagate uses REPO_OPTIONS");

	my %opts = command_properties('propagate')->{options}->@*;
	ok(exists $opts{'dry-run|n'}, "propagate has a dry-run option");
	ok(exists $opts{'commit=s'},  "propagate has a commit option");
	ok(exists $opts{'no-push'},   "propagate has a no-push option");

	# -y is gone.  It was accepted and read by nothing, held only because
	# the deploy passed it whenever --fix-checks was set, and the deploy
	# passes it no longer, so a run that gives it is a usage error.
	ok(!exists $opts{'yes|y'}, "propagate no longer accepts a yes option");

	is(scalar(keys %opts), 3, "propagate has only the three options above");

	my $args = command_properties('propagate')->{arguments};
	cmp_deeply($args, ['env?', ignore()],
		"propagate takes one optional positional environment");
};

done_testing;
