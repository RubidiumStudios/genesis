#!perl
# The shared readers and guards in t/helper.pm, which several test files and
# the propagation harness all call.  They build no product state of their own,
# so nothing else in the suite asserts what they do, and two of them are the
# floor under the tree sweeps that hunt a forbidden form.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

$ENV{NOCOLOR} = 1;

subtest 'sweep_files reaches every corner the guards rely on' => sub {
	plan tests => 6;

	my $top = $ENV{GENESIS_TOPDIR};
	my @files = sweep_files();

	ok((grep {$_ eq "$top/lib/Genesis/Exit.pm"} @files),
		'a module deep under lib/ is swept');
	ok((grep {$_ eq "$top/bin/genesis"} @files),
		'the genesis script is swept');
	ok((grep {$_ eq "$top/bin/pipey"} @files),
		'and so is the second script under bin/, which no guard had opened');

	is_deeply([@files], [sort @files], 'the list comes back sorted');

	my %seen;
	$seen{$_}++ for @files;
	is_deeply([grep {$seen{$_} > 1} keys %seen], [],
		'and no file is named twice');

	is(scalar(grep {index($_, "$top/t/") == 0} @files), 0,
		'nothing under t/ is swept, so a fixture is never reported');
};

subtest 'sweep_files is anchored on the topdir, not on the cwd' => sub {
	plan tests => 3;

	my @files = sweep_files();

	my $count = sweep_files();
	is($count, scalar(@files),
		'scalar context answers the count rather than the last path');

	my $top = $ENV{GENESIS_TOPDIR};
	is(scalar(grep {index($_, "$top/") != 0} @files), 0,
		'every path it answers is absolute and under the topdir');

	my $elsewhere = helper::workdir;
	my $cwd = Cwd::getcwd();
	chdir $elsewhere or die "cannot chdir to $elsewhere: $!\n";
	my @from_elsewhere = eval {sweep_files()};
	my $err = $@;
	chdir $cwd or die "cannot chdir back to $cwd: $!\n";
	die $err if $err;
	is_deeply(\@from_elsewhere, \@files,
		'and a run from another directory sweeps the same files');
};

subtest 'sweep_files sorts what it finds by the rules it declares' => sub {
	plan tests => 5;

	my $top = helper::workdir . '/swept';
	helper::put_file("$top/lib/Thing.pm",       "package Thing;\n1;\n");
	helper::put_file("$top/lib/deep/task.pl",   "#!/usr/bin/env perl\n");
	helper::put_file("$top/lib/notes.txt",      "not perl\n");
	helper::put_file("$top/bin/runner", 0755,   "#!/bin/sh\n");
	helper::put_file("$top/bin/notes.txt",      "not a script\n");
	helper::put_file("$top/t/fixture.pm",       "package Fixture;\n1;\n");
	my $guard = local_env(GENESIS_TOPDIR => $top);
	my @files = sweep_files();

	ok((grep {$_ eq "$top/lib/Thing.pm"} @files), 'a module under lib/ is swept');
	ok((grep {$_ eq "$top/lib/deep/task.pl"} @files),
		'so is a script under lib/, because the walk takes .pl as well as .pm');
	ok(!(grep {$_ eq "$top/lib/notes.txt"} @files),
		'a file under lib/ that is neither is left alone');
	ok((grep {$_ eq "$top/bin/runner"} @files),
		'an executable under bin/ is swept whatever it is called');
	ok(!(grep {$_ eq "$top/bin/notes.txt"} @files),
		'and one without the executable bit is not');
};

subtest 'sweep_files refuses to answer quietly where the anchor is wrong' => sub {
	plan tests => 2;

	my $empty = helper::workdir . '/empty';
	helper::mkdir_or_fail("$empty/lib");
	helper::mkdir_or_fail("$empty/bin");

	{
		my $guard = local_env(GENESIS_TOPDIR => $empty);
		my @files = eval {sweep_files()};
		like($@, qr/sweep_files found nothing/,
			'a tree with no files to sweep is a death, not an empty list');
	}

	{
		my $guard = local_env(GENESIS_TOPDIR => undef);
		my @files = eval {sweep_files()};
		like($@, qr/GENESIS_TOPDIR/,
			'and an unset anchor says which variable is missing');
	}
};

subtest 'strip_comment takes the comment and leaves the code' => sub {
	plan tests => 5;

	is(strip_comment(q{exit TEMPFAIL; # the partial run a retry repairs}),
		q{exit TEMPFAIL; },
		'a trailing comment goes');

	is(strip_comment(q{exit TEMPFAIL;}), q{exit TEMPFAIL;},
		'a line with no comment is handed back whole');

	is(strip_comment(q{my $note = "exit 75 # here"; # and here}),
		q{my $note = "exit 75 # here"; },
		'a hash inside a quoted string is not a comment');

	is(strip_comment(q{$slug =~ s#^/?(.*?)/?$#$1#; # trim the slashes}),
		q{$slug =~ s#^/?(.*?)/?$#$1#; },
		'a hash that delimits a regex is not a comment either');

	is(strip_comment(q{my $last = $#codes;}), q{my $last = $#codes;},
		'and neither is the last-index sigil');
};

done_testing;
