#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Cwd ();
use File::Temp ();

use_ok 'Genesis';

# ---------------------------------------------------------------------------
# Genesis snapshots the compile-time cwd into $Genesis::INITIAL_CWD and
# restores it in an END block.  Purpose: a die between pushd and popd
# (or any other unbalanced chdir) leaves the process cwd inside a
# tempdir that File::Temp's own END-block rmtree will then try to remove,
# emitting "cannot remove path when cwd is X" from File::Path.  Restoring
# cwd first sidesteps the whole class.
# ---------------------------------------------------------------------------

subtest 'INITIAL_CWD is defined and looks like a directory path' => sub {
	plan tests => 3;
	ok defined($Genesis::INITIAL_CWD),
		'$Genesis::INITIAL_CWD is set (BEGIN captured it)';
	ok length($Genesis::INITIAL_CWD),
		'$Genesis::INITIAL_CWD is non-empty';
	ok -d $Genesis::INITIAL_CWD,
		"\$Genesis::INITIAL_CWD ($Genesis::INITIAL_CWD) resolves to a real directory";
};

subtest 'INITIAL_CWD reflects the load-time cwd, not a later chdir' => sub {
	plan tests => 1;
	# Move cwd somewhere else after Genesis has loaded; the snapshot
	# should not follow us.
	my $tmp = File::Temp->newdir;
	my $before = $Genesis::INITIAL_CWD;
	chdir $tmp->dirname;
	my $after = $Genesis::INITIAL_CWD;
	# Restore cwd so the rest of the file doesn't run in a soon-to-be-
	# removed tempdir.
	chdir $before;
	is $after, $before,
		'INITIAL_CWD is a snapshot; subsequent chdir does not mutate it';
};

# END-block restore: exercise via a child process so we can observe the
# behaviour without polluting this process's state.  The child pushd's
# into a tempdir, then die's (without popd).  Without the restore, the
# child's File::Temp cleanup emits "cannot remove path when cwd is X".
# With the restore, cwd is moved back to $INITIAL_CWD first and cleanup
# runs silently.

subtest 'END block restores cwd, silencing File::Temp cleanup warning' => sub {
	plan tests => 2;

	# Child perl one-liner: load Genesis, create a tempdir via
	# File::Temp, chdir into it, die.  All on the command line so the
	# child is genuinely independent of this process's state.
	my $script = <<'PERL';
use lib 'lib';
use Genesis;
use File::Temp qw/tempdir/;
my $t = tempdir(CLEANUP => 1);
chdir $t;
die "simulated deploy failure\n";
PERL

	# stderr captures both the die message and any File::Path warnings
	my $stderr = `perl -Ilib -e '$script' 2>&1`;

	like $stderr, qr/simulated deploy failure/,
		'child died as expected (produced our sentinel error)';
	unlike $stderr, qr/cannot remove path when cwd is/,
		'no "cannot remove path when cwd is X" warning from File::Path';
};

done_testing;
