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

subtest 'genesis config' => sub {
	plan tests => 4;

	ok(has_command('config'), "config command is registered");

	my %opts = command_properties('config')->{options}->@*;
	# The @ matters: without it Getopt::Long keeps only the last
	# occurrence's value and discards every key.
	ok(exists $opts{'set=s@{2}'},
		"config has a repeatable --set taking a key and a value");

	# Dispatch resolves the handler lazily, so a wrong name here only
	# surfaces when someone runs the command.
	my $subref = $Genesis::Commands::RUN{'config'};
	is(ref($subref), 'CODE', "config command has a subroutine reference");
	cmp_deeply(scalar(closed_over($subref)), {
		'$fn' => \'Genesis::Commands::Core::config',
		'$fn_require' => \'Genesis/Commands/Core.pm',
		'$name' => \'config',
	}, "config command routes to Core::config");
};

done_testing;
