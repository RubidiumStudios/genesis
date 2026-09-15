#!perl
# Proves that a schema can be applied to one block of a configuration: the
# block's own keys are typed, its defaults are filled into the same store
# every other reader uses, an undeclared key is named with its full dotted
# path, and the errors come back as strings rather than as a bail.
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

# The errors come back carrying Genesis's own colour markup, because they
# are the same strings validate() hands to bail, so every match below
# renders them first and the file turns the colour off.
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $schema = {
	target => {type => 'string',  required => 1, description => 'One key'},
	team   => {type => 'string',  default  => 'main', description => 'Another'},
	debug  => {type => 'boolean', default  => Genesis::Config::FALSE(), description => 'A third'},
};

subtest 'the block is validated where it sits' => sub {
	plan tests => 4;

	my $cfg = Genesis::Config->new();
	$cfg->set('pipeline.provider.type',   'concourse');
	$cfg->set('pipeline.provider.target', 'ci');

	my @errors = $cfg->validate_subtree('pipeline.provider', $schema,
		ignore => ['type']);
	is_deeply [@errors], [], 'a valid block reports nothing';

	is $cfg->get('pipeline.provider.team'), 'main',
		'the default is filled where every other reader looks for it';
	is $cfg->get('pipeline.provider.debug'), Genesis::Config::FALSE(),
		'and so is a boolean default, in its normalised form';
	is $cfg->get('pipeline.provider.target'), 'ci',
		'while what the operator wrote is left alone';
};

subtest 'the defaults it filled last time do not outlive the schema' => sub {
	plan tests => 2;

	my $cfg = Genesis::Config->new();
	$cfg->set('pipeline.provider.type', 'concourse');
	$cfg->set('pipeline.provider.target', 'ci');
	$cfg->validate_subtree('pipeline.provider', $schema, ignore => ['type']);
	is $cfg->get('pipeline.provider.team'), 'main',
		'the first pass fills what its schema declares';

	# The same block, validated against a schema that declares neither of
	# the two keys the first one defaulted, which is what a run rewriting
	# the provider type does.
	my @errors = $cfg->validate_subtree('pipeline.provider',
		{target => {type => 'string', description => 'The only key now'}},
		ignore => ['type']);
	is_deeply [@errors], [],
		'and the second reports no key the first one filled';
};

subtest 'what is wrong comes back as strings, named in full' => sub {
	plan tests => 3;

	my $cfg = Genesis::Config->new();
	$cfg->set('pipeline.provider.type',     'concourse');
	$cfg->set('pipeline.provider.nonesuch', 1);

	my @errors = $cfg->validate_subtree('pipeline.provider', $schema,
		ignore => ['type']);
	my $said = csprintf('%s', join("\n", @errors));

	like $said,
		qr/pipeline\.provider\.nonesuch: unknown configuration key/,
		'an undeclared key is named by its whole path and not by its leaf';
	like $said,
		qr/pipeline\.provider: missing required key .*target/,
		'and a required key that is absent is named beside it';
	is scalar(@errors), 2,
		'both are reported from one call rather than one refusal at a time';
};

done_testing;
