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

subtest 'the deployments aliases' => sub {
	require_ok './bin/genesis';

	is($Genesis::Commands::GENESIS_COMMANDS{deployments}, 'deployments', 'deployments is a command');
	for my $alias (qw/deps hist history/) {
		is($Genesis::Commands::GENESIS_COMMANDS{$alias}, 'deployments', "$alias is an alias of deployments");
	}
};

subtest 'the deployments count option' => sub {
	require_ok './bin/genesis';

	# The count option answers to its correct spelling and to the old one.
	require Getopt::Long;
	my %specs = @{$Genesis::Commands::PROPS{deployments}{options}};
	my ($spec) = grep {/\|n=i$/} keys %specs;
	ok($spec, 'deployments has a count option');
	for my $name (qw/recent resent n/) {
		my %got;
		my $parser = Getopt::Long::Parser->new(config => ['bundling_override', 'no_ignore_case']);
		my $ok = $parser->getoptionsfromarray($name eq 'n' ? ['-n', '3'] : ["--$name", '3'], \%got, $spec);
		ok($ok, $name eq 'n' ? "-n parses" : "--$name parses");
		is((values %got)[0], 3, "and takes the count");
	}
};

done_testing;
