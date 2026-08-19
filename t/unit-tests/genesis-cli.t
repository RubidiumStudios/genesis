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

subtest 'genesis pipeline-prepare' => sub {
	plan tests => 13;

	ok(has_command('pipeline-prepare'), "pipeline-prepare command is registered");

	is(command_properties('pipeline-prepare')->{function_group},
		Genesis::Commands::PIPELINE,
		"pipeline-prepare belongs to the pipeline group, alongside pipeline-status");

	# The scope IS the feature.  A ['repo','env'] command is handed the
	# environment name by the dispatcher when invoked as
	# `genesis <env> pipeline-prepare`, and nothing when invoked bare --
	# which is how repo mode and env mode are told apart without a flag.
	cmp_deeply(command_properties('pipeline-prepare')->{scope},
		bag('repo', 'env'),
		"pipeline-prepare accepts both repo and env scope");

	is(command_properties('pipeline-prepare')->{option_group},
		Genesis::Commands::REPO_OPTIONS,
		"pipeline-prepare uses REPO_OPTIONS");

	my %opts = command_properties('pipeline-prepare')->{options}->@*;
	ok(exists $opts{'dry-run|n'}, "pipeline-prepare has a dry-run option");
	ok(exists $opts{'no-fetch'},  "pipeline-prepare has a no-fetch option");
	is(scalar(keys %opts), 2, "pipeline-prepare has only the two options above");

	# No positional environment argument: the env comes from the scope,
	# not from `pipeline-prepare <env>`, so that it reads the same way as
	# every other env-scoped command.
	my $args = command_properties('pipeline-prepare')->{arguments};
	ok(!$args || !@$args, "pipeline-prepare takes no positional arguments");

	not_ok(command_properties('pipeline-prepare')->{deprecated},
		"pipeline-prepare is not deprecated");
	not_ok(command_properties('pipeline-prepare')->{retired},
		"pipeline-prepare is not retired");

	my $subref = $Genesis::Commands::RUN{'pipeline-prepare'};
	is(ref($subref), 'CODE', "pipeline-prepare has a subroutine reference");
	cmp_deeply(scalar(closed_over($subref)), {
		'$fn' => \'Genesis::Commands::Pipelines::pipeline_prepare',
		'$fn_require' => \'Genesis/Commands/Pipelines.pm',
		'$name' => \'pipeline-prepare',
	}, "pipeline-prepare resolves to the right handler");

	# It repairs what propagate refuses to guess about, so it should be
	# findable from that bail's wording.
	like(command_properties('pipeline-prepare')->{description},
		qr/propagate/i,
		"pipeline-prepare's description points back at propagate");
};

subtest 'genesis propagate' => sub {
	plan tests => 11;

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
	ok(exists $opts{'no-fetch'},  "propagate has a no-fetch option");

	# -y authorizes creating a branch for an environment that has none.
	# It follows deploy/terminate/repipe/pipeline-apply rather than
	# inventing a propagate-specific spelling.
	ok(exists $opts{'yes|y'},
		"propagate has the conventional yes option");

	is(scalar(keys %opts), 5, "propagate has only the five options above");

	my $args = command_properties('propagate')->{arguments};
	cmp_deeply($args, ['env?', ignore()],
		"propagate takes one optional positional environment");
};

done_testing;
