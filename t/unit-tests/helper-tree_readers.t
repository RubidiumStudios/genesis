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
use File::Temp ();

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

subtest 'standin_vault answers a fixed set and keeps a ledger' => sub {
	plan tests => 3;

	my @asked;
	my $vault = standin_vault(\@asked, {dependencies => 'other/bosh'});

	is_deeply($vault->get('/secret/exodus/qa/bosh'),
		{dependencies => 'other/bosh'},
		'the set it was built with is the set it answers');

	is_deeply($vault->get('/secret/exodus/lab/bosh'),
		{dependencies => 'other/bosh'},
		'and it answers the same set at a second path');

	is_deeply(\@asked, ['/secret/exodus/qa/bosh', '/secret/exodus/lab/bosh'],
		'while every path it was asked for lands in the ledger, in order');
};

subtest 'local_env sets what it is given and puts it all back' => sub {
	plan tests => 6;

	local $ENV{HELPER_T_HELD} = 'before';
	delete $ENV{HELPER_T_ABSENT};

	{
		my $guard = local_env(
			HELPER_T_HELD   => 'during',
			HELPER_T_ABSENT => 'new',
		);
		is($ENV{HELPER_T_HELD}, 'during', 'a variable that was set is replaced');
		is($ENV{HELPER_T_ABSENT}, 'new', 'one that was unset is created');
	}

	is($ENV{HELPER_T_HELD}, 'before', 'the replaced value comes back');
	ok(!exists $ENV{HELPER_T_ABSENT},
		'and one that was never there is removed, not left standing empty');

	my $guard = local_env(HELPER_T_HELD => 'again');
	$guard->restore;
	is($ENV{HELPER_T_HELD}, 'before', 'an explicit teardown puts it back too');

	$guard->restore;
	is($ENV{HELPER_T_HELD}, 'before', 'and a second teardown changes nothing');
};

subtest 'local_env puts it back even where the row dies' => sub {
	plan tests => 3;

	local $ENV{HELPER_T_THROWN} = 'before';

	my $err;
	eval {
		my $guard = local_env(HELPER_T_THROWN => 'during');
		die "the row gave up partway\n";
	} or $err = $@;

	like($err, qr/gave up partway/, 'the death reaches the caller');
	is($ENV{HELPER_T_THROWN}, 'before',
		'and the variable is back to what it held before the row ran');

	local $ENV{HELPER_T_REMOVED} = 'present';
	{
		my $guard = local_env(HELPER_T_REMOVED => undef);
		ok(!exists $ENV{HELPER_T_REMOVED},
			'an undefined value takes the variable away for the guard\'s life');
	}
};

subtest 'local_env refuses a call that throws its guard away' => sub {
	plan tests => 2;

	local $ENV{HELPER_T_VOID} = 'before';

	my $err;
	eval {local_env(HELPER_T_VOID => 'during'); 1} or $err = $@;

	like($err, qr/guard/,
		'a call in void context is a death, because it would arm nothing');
	is($ENV{HELPER_T_VOID}, 'before',
		'and the variable is left exactly as it was');
};

subtest 'vault_ok folds a multi-line failure onto one line' => sub {
	plan tests => 3;

	my @failed;
	{
		no warnings 'redefine';
		local *helper::fail = sub {push @failed, $_[0]};
		local *helper::vault_start = sub {
			die "expected numeric value for Vault pid, but got this:\n\tnot-a-pid\n";
		};
		eval {helper::vault_ok('helper-t-folding-check'); 1};
	}

	is(scalar(@failed), 1, 'the failure is reported once');
	unlike($failed[0], qr/\s\s|\n|\t/,
		'the text handed to fail carries no newline and no run of whitespace');
	like($failed[0], qr/numeric value for Vault pid, but got this: not-a-pid/,
		'because the whole message folded onto one readable line');
};

subtest 'a vault that never answered leaves no pid behind' => sub {
	plan tests => 2;

	# The stub stands in for t/bin/vault and reports a pid no process holds,
	# which is the shape of a vault that said it had started and had not.
	my $top = File::Temp::tempdir(CLEANUP => 1);
	mkdir "$top/t" and mkdir "$top/t/bin"
		or die "could not build the stub tree under $top: $!\n";
	open my $stub, '>', "$top/t/bin/vault"
		or die "could not write the stub vault: $!\n";
	print $stub "#!/bin/sh\necho 99999\n";
	close $stub;
	chmod 0755, "$top/t/bin/vault";

	local $ENV{GENESIS_TOPDIR} = $top;
	my $target = 'helper-t-dead-vault';

	my $first;
	eval {vault_start($target); 1} or $first = $@;
	like($first, qr/couldn't signal pid 99999/,
		'the start dies where the pid it was handed answers no signal');

	# The record is what vault_ok reads to say a vault is already running,
	# so a start that died must leave none, and the second call proves it by
	# trying again instead of answering from it.
	my $second;
	eval {vault_start($target); 1} or $second = $@;
	like($second, qr/couldn't signal pid 99999/,
		'and a second start tries again rather than answering from a record');
};

done_testing;
