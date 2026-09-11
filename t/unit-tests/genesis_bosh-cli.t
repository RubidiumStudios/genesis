#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use Genesis::Commands;
use PadWalker qw/closed_over/;
use Genesis;

# Initialize the Genesis environment
$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# Registers the commands this file asserts against.
require './bin/genesis';

subtest 'genesis bosh-configs' => sub {
	plan tests => 10;

	ok(has_command('bosh-configs'), "bosh-configs command is registered");
	my $props = command_properties('bosh-configs');

	cmp_deeply($props->{aliases}, ['bc', 'configs'],
		"bosh-configs keeps its bc and configs aliases");
	is($props->{function_group}, Genesis::Commands::BOSH,
		"bosh-configs is filed under the BOSH function group");
	is($props->{scope}, 'env', "bosh-configs is an environment-scoped command");

	my %opts = $props->{options}->@*;
	ok(exists $opts{'type|t=s'},   "bosh-configs has a --type option taking a value");
	ok(exists $opts{'name|n=s'},   "bosh-configs has a --name option taking a value");
	ok(exists $opts{'uploaded|u'}, "bosh-configs has a --uploaded flag");
	ok(exists $opts{'yes|y'},      "bosh-configs has a --yes flag");

	# Dispatch resolves the handler lazily, so a wrong name here only
	# surfaces when someone runs the command.
	my $subref = $Genesis::Commands::RUN{'bosh-configs'};
	is(ref($subref), 'CODE', "bosh-configs command has a subroutine reference");
	cmp_deeply(scalar(closed_over($subref)), {
		'$fn' => \'Genesis::Commands::Bosh::bosh_configs',
		'$fn_require' => \'Genesis/Commands/Bosh.pm',
		'$name' => \'bosh-configs',
	}, "bosh-configs command routes to Bosh::bosh_configs");
};

done_testing;
