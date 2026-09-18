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

# deploy is here now.  It declared no class while it carried a
# checkout_one_way of its own, because one state would then have taken two
# switches, and it declares one now that the switch has gone.
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
	'deploy'             => Genesis::Commands::DEPLOYED_STATE,
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

	# The deploy's own half, said in its own words rather than left to the
	# sweep above, because this is the declaration that let the deploy stop
	# switching for itself.
	is(command_properties('deploy')->{branch_class},
		Genesis::Commands::DEPLOYED_STATE,
		'deploy declares the deployed-state branch class');
};

subtest 'only the command that deploys fast-forwards its branch' => sub {
	# The gate's one write is declared rather than assumed, so a command
	# that reads the deployment branch cannot acquire a ref move by sharing
	# a gate with one that deploys.  The three commands of the class are
	# read one by one and then swept, because the sweep alone would pass
	# for a tree where the property had moved from the deploy to another of
	# them, and the per-command rows alone would pass for a tree that had
	# given it to a command outside the class as well.  Green on arrival,
	# the declaration having landed with the gate's arm that reads it, and a
	# guard against an edit that moves it or hands it round.
	ok(command_properties('deploy')->{branch_fast_forward},
		'deploy declares that it brings its deployment branch forward');
	ok(!command_properties('info')->{branch_fast_forward},
		'info declares no such move, because a read moves no ref');
	ok(!command_properties('bosh')->{branch_fast_forward},
		'and neither do the bosh subcommands');

	my @forwards = sort grep {
		command_properties($_)->{branch_fast_forward}
	} Genesis::Commands::commands();
	is_deeply(\@forwards, ['deploy'],
		'and it is the only command in the tree that declares it');
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
