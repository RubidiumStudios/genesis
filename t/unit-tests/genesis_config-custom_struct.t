#!perl
# Proves that custom_struct dispatches: the discriminator is validated
# against the map and refused by name when no module owns it, the
# discriminator's default is filled before the match, the rest of the
# block goes to that module's method, and the type does no validating of
# its own beyond the discriminator.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use Genesis::Term qw/csprintf/;
use_ok 'Genesis::Config';

# _validate_key hands back the raw strings, colour markup and all, so
# every match below renders them first and the file turns the colour off.
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

put_file('t/tmp/lib/Probe/Loud.pm', <<'LOUD');
package Probe::Loud;
our @CALLS;
sub validate_config {
	my ($class, $config, $path) = @_;
	push @CALLS, $path;
	return ("$path: the loud probe refuses everything");
}
1;
LOUD
put_file('t/tmp/lib/Probe/Quiet.pm', <<'QUIET');
package Probe::Quiet;
sub validate_config {return ()}
1;
QUIET
local @INC = ('t/tmp/lib', @INC);

my $schema = {
	block => {
		type                  => 'custom_struct',
		discriminator         => 'kind',
		discriminator_default => 'quiet',
		description           => 'A block whose shape its own kind decides',
		modules => {
			loud  => {module => 'Probe/Loud.pm',  class => 'Probe::Loud'},
			quiet => {module => 'Probe/Quiet.pm', class => 'Probe::Quiet'},
		},
	},
};

subtest 'the discriminator decides who validates the rest' => sub {
	plan tests => 3;

	local @Probe::Loud::CALLS = ();
	my $cfg = Genesis::Config->new();
	$cfg->set('block.kind', 'loud');

	my @errors = $cfg->_validate_key('block', $schema->{block});
	is_deeply [@Probe::Loud::CALLS], ['block'],
		'the owning module is handed the block by its path';
	like csprintf('%s', join("\n", @errors)),
		qr/the loud probe refuses everything/,
		"and what it says is what the operator reads";
	is scalar(@errors), 1,
		'the type adds nothing of its own to the module\'s answer';
};

subtest 'a value no module owns is refused by name' => sub {
	plan tests => 2;

	my $cfg = Genesis::Config->new();
	$cfg->set('block.kind', 'nonesuch');

	my @errors = $cfg->_validate_key('block', $schema->{block});
	like csprintf('%s', join("\n", @errors)),
		qr/block\.kind: unknown value: nonesuch; expected one of loud, quiet/,
		'the map is the valid list, and it reads the way the enum read';
	is scalar(@errors), 1,
		'and nothing was handed to a module that does not exist';
};

subtest "the discriminator takes the declaration's default" => sub {
	plan tests => 2;

	my $cfg = Genesis::Config->new();
	$cfg->set('block.whatever', 1);

	my @errors = $cfg->_validate_key('block', $schema->{block});
	is $cfg->get('block.kind'), 'quiet',
		'an absent discriminator is filled before the match runs';
	is_deeply [@errors], [],
		'so the block reaches the module the default names';
};

done_testing;
