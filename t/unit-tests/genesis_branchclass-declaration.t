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

subtest 'only the command that commits on control declares it' => sub {
	# D45's refusal is about a commit that cannot reach control through a
	# pull request, so it is asked of the command and not of the class.
	# Every other pre-deploy command runs on control as before:
	# pipeline-apply writes to the provider, and refusing it would leave
	# an operator no way to turn on the very protection the key derives.
	is(command_properties('create')->{commits}, 1,
		'create declares that it commits on control');

	my @commits = sort grep {
		command_properties($_)->{commits}
	} Genesis::Commands::commands();
	is_deeply(\@commits, ['create'],
		'and it is the only command in the tree that declares it');

	for my $cmd (qw/pipeline-apply pipeline-status pipeline-describe
	                check-secrets rotate-secrets propagate/) {
		ok(!defined(command_properties($cmd)->{commits}),
			"$cmd declares no commit on control");
	}
};

subtest 'every declared class is marked in the help listing' => sub {
	# command_help writes through Genesis::info, which the logger sends to
	# STDERR, and it ends in exit, so the listing is read off STDERR with
	# the exit caught.  A plain eval catches no exit and stdout_from reads
	# the stream the listing never reaches.
	my $help = stderr_from { exits_zero { Genesis::Commands::command_help() } };

	# Each row is anchored to the command column of its own entry, which is
	# the scope icons, the command name, and the gap before its summary.  A
	# word boundary is not enough: a hyphen is a non-word character, so
	# \bsecrets\b matches inside check-secrets and rotate-secrets, and the
	# secrets row was satisfied by whichever of those lines carried a marker.
	# The icon field is upper-case letters and spaces, so nothing of a longer
	# command's name can be mistaken for the field in front of a shorter one.
	for my $cmd (sort keys %expected) {
		my $marker = $expected{$cmd} eq Genesis::Commands::PRE_DEPLOY
			? '[control]'
			: '[env branch]';
		like($help, qr/^[A-Z ]*\Q$cmd\E\s{2,}[^\n]*\Q$marker\E/m,
			"the help entry for $cmd carries the $marker marker");
	}

	unlike($help, qr/^[A-Z ]*version\s{2,}[^\n]*\[(?:control|env branch)\]/m,
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

subtest 'the marker stays on the command line at an ordinary width' => sub {
	# The rows above pin the width at 999, where no summary folds, so they
	# would pass against an implementation that appends the marker to the
	# summary before the wrap.  That implementation is the one this row
	# catches: at an ordinary width the marker travelled with the last
	# words of the summary onto a continuation line, where it names no
	# command and the left column cannot say whose it is.  The row is green
	# on arrival, because the marker is already put on after the wrap.
	local $ENV{GENESIS_OUTPUT_COLUMNS} = 100;
	my $help = stderr_from { exits_zero { Genesis::Commands::command_help() } };

	for my $cmd (sort keys %expected) {
		my $marker = $expected{$cmd} eq Genesis::Commands::PRE_DEPLOY
			? '[control]'
			: '[env branch]';
		like($help, qr/^[A-Z ]*\Q$cmd\E\s{2,}[^\n]*\Q$marker\E/m,
			"${cmd}'s marker is on its own first line at 100 columns");
	}
};

done_testing;
