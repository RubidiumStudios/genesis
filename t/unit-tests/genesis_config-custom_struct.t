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
use Genesis::Term qw/csprintf decolorize/;
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
# A module that answers with a bare undef and an empty string beside one
# real complaint, which is what a rule that fell through its own branches
# hands back.
put_file('t/tmp/lib/Probe/Mumble.pm', <<'MUMBLE');
package Probe::Mumble;
sub validate_config {
	my ($class, $config, $path) = @_;
	return (undef, '', "$path: the one thing the mumble probe means to say");
}
1;
MUMBLE
# A module whose rule falls over, which is a fault in somebody else's
# code reached from the middle of a configuration load.
put_file('t/tmp/lib/Probe/Boom.pm', <<'BOOM');
package Probe::Boom;
sub validate_config {die "the boom probe fell over\n"}
1;
BOOM
# And one that raises a Genesis fatal, which says the module is broken
# rather than that the operator wrote the block wrongly.
put_file('t/tmp/lib/Probe/Broken.pm', <<'BROKEN');
package Probe::Broken;
use Genesis;
sub validate_config {bug("the broken probe is broken")}
1;
BROKEN
local @INC = ('t/tmp/lib', @INC);

my $schema = {
	block => {
		type                  => 'custom_struct',
		discriminator         => 'kind',
		discriminator_default => 'quiet',
		description           => 'A block whose shape its own kind decides',
		modules => {
			boom   => {module => 'Probe/Boom.pm',   class => 'Probe::Boom'},
			broken => {module => 'Probe/Broken.pm', class => 'Probe::Broken'},
			loud   => {module => 'Probe/Loud.pm',   class => 'Probe::Loud'},
			mumble => {module => 'Probe/Mumble.pm', class => 'Probe::Mumble'},
			quiet  => {module => 'Probe/Quiet.pm',  class => 'Probe::Quiet'},
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
		qr/block\.kind: unknown value: nonesuch; expected one of boom, broken, loud, mumble, quiet/,
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

subtest 'a block written as an empty hash still takes the default' => sub {
	plan tests => 2;

	my $cfg = Genesis::Config->new();

	# What "block: {}" in the file gives the loaded store.  The merge takes
	# the highest-priority structure first and skips any key whose ancestor
	# is already there, so a discriminator filed at default priority sits
	# under an empty hash that has already claimed the block, and the
	# operator meets a refusal naming a null kind instead of the default.
	$cfg->_update_source('loaded', 'block', {});

	my @errors = $cfg->_validate_key('block', $schema->{block});
	is $cfg->get('block.kind'), 'quiet',
		'the default is read back through the empty hash the file carried';
	is_deeply [@errors], [],
		'so the block still reaches the module the default names';
};

subtest 'a block that is not a hash is refused before the map is read' => sub {
	plan tests => 1;

	my $cfg = Genesis::Config->new();
	$cfg->set('block', 'a string');

	my @errors = $cfg->_validate_key('block', $schema->{block});
	is_deeply [map {csprintf('%s', $_)} @errors], ['block: expected a hash'],
		'the shape is checked before the discriminator is looked for';
};

subtest "nothing empty survives out of the module's answer" => sub {
	plan tests => 2;

	my $cfg = Genesis::Config->new();
	$cfg->set('block.kind', 'mumble');

	# A rule that fell through its own branches answers with an undef or an
	# empty string, and printing one gives the operator a bullet with
	# nothing after it to read.
	my @errors = $cfg->_validate_key('block', $schema->{block});
	is scalar(@errors), 1,
		'the undef and the empty string are dropped on the way out';
	is csprintf('%s', $errors[0] // ''),
		'block: the one thing the mumble probe means to say',
		'and what the module meant to say is what is left';
};

subtest 'a module that falls over is answered under its own block' => sub {
	plan tests => 3;

	my $cfg = Genesis::Config->new();
	$cfg->set('block.kind', 'boom');

	# The module is somebody else's code, so what it does when it goes
	# wrong is the load's problem rather than the operator's: the rule is
	# run inside an eval and what it said becomes one error like any
	# other, under the block it was asked about.
	my @errors = $cfg->_validate_key('block', $schema->{block});
	is scalar(@errors), 1, 'a rule that dies answers with one error';
	my $said = csprintf('%s', $errors[0] // '');
	like $said, qr/^block: /, 'filed under the block it was asked about';
	like $said, qr/the boom probe fell over/, 'carrying what the module said';
};

subtest "a defect in a module is not the operator's mistake" => sub {
	plan tests => 2;

	my $cfg = Genesis::Config->new();
	$cfg->set('block.kind', 'broken');

	# Genesis raises its own fatals already framed, and one of those says
	# the module is broken.  Gathering it as an error about the block
	# would tell whoever reads the refusal to go and fix a configuration
	# that has nothing wrong with it.
	my $raised = '';
	eval {$cfg->_validate_key('block', $schema->{block}); 1} or $raised = $@;
	like decolorize($raised), qr/the broken probe is broken/,
		'the raise goes up rather than being gathered as an error';
	like decolorize($raised), qr/bug in Genesis itself/,
		'and it is still reported as the defect it is';
};

done_testing;
