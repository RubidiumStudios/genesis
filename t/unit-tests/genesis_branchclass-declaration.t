#!/usr/bin/env perl
# Proves T194: every pipeline-aware registration declares one branch class,
# every declared class appears as a marker in the help listing, and the two
# are read from the same attribute so they cannot disagree.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;
use Test::Exit;

use Genesis::Commands;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

require_ok './bin/genesis';

# deploy is absent on purpose.  It declares its class at M13, where its own
# checkout_one_way is retired, so that one state never carries two switches.
my %expected = (
	'create'             => Genesis::Commands::PRE_DEPLOY,
	'propagate'          => Genesis::Commands::PRE_DEPLOY,
	'pipeline-apply'     => Genesis::Commands::PRE_DEPLOY,
	'pipeline-status'    => Genesis::Commands::PRE_DEPLOY,
	'pipeline-describe'  => Genesis::Commands::PRE_DEPLOY,
	'check-secrets'      => Genesis::Commands::PRE_DEPLOY,
	'secrets'            => Genesis::Commands::PRE_DEPLOY,
	'add-secrets'        => Genesis::Commands::PRE_DEPLOY,
	'rotate-secrets'     => Genesis::Commands::PRE_DEPLOY,
	'remove-secrets'     => Genesis::Commands::PRE_DEPLOY,
	'info'               => Genesis::Commands::DEPLOYED_STATE,
	'bosh'               => Genesis::Commands::DEPLOYED_STATE,
);

subtest 'one class per pipeline-aware registration' => sub {
	for my $cmd (sort keys %expected) {
		is(command_properties($cmd)->{branch_class}, $expected{$cmd},
			"$cmd declares the $expected{$cmd} branch class");
	}

	# propagate is the one exception D81 carries, and it says so at its own
	# registration rather than in a special case inside the gate.
	is(command_properties('propagate')->{branch_target}, 'control',
		'propagate declares that it switches to control itself');
	is(scalar(grep {
		defined(command_properties($_)->{branch_target})
	} Genesis::Commands::commands()), 1,
		'propagate is the only command declaring a branch target');

	# A command outside the pipeline surface declares nothing, so the gate
	# has nothing to read and leaves it alone.
	ok(!defined(command_properties('version')->{branch_class}),
		'version declares no branch class');
	ok(!defined(command_properties('list-kits')->{branch_class}),
		'list-kits declares no branch class');

	# M13's half of the same attribute, asserted here so that a step which
	# declared it early would be caught by the file that owns the surface.
	ok(!defined(command_properties('deploy')->{branch_class}),
		'deploy declares no branch class until M13 retires its own switch');
};

subtest 'every declared class is marked in the help listing' => sub {
	# command_help writes through Genesis::info, which the logger sends to
	# STDERR, and it ends in exit, so the listing is read off STDERR with
	# the exit caught.  A plain eval catches no exit and stdout_from reads
	# the stream the listing never reaches.
	my $help = stderr_from { exits_zero { Genesis::Commands::command_help() } };

	for my $cmd (sort keys %expected) {
		my $marker = $expected{$cmd} eq Genesis::Commands::PRE_DEPLOY
			? '[control]'
			: '[env branch]';
		like($help, qr/\b\Q$cmd\E\b[^\n]*\Q$marker\E/,
			"the help entry for $cmd carries the $marker marker");
	}

	unlike($help, qr/\bversion\b[^\n]*\[(?:control|env branch)\]/,
		'a command with no class carries no marker');
};

subtest 'the marker and the refusal read one attribute' => sub {
	# The marker is computed from the same property the gate reads, so a
	# registration that changed one without the other could not exist.
	for my $cmd (sort keys %expected) {
		my $marker = Genesis::Commands::_branch_class_marker($cmd);
		like($marker, qr/\Q@{[ command_properties($cmd)->{branch_class} eq Genesis::Commands::PRE_DEPLOY ? '[control]' : '[env branch]' ]}\E/,
			"${cmd}'s marker is derived from its declared class");
	}
};

done_testing;
