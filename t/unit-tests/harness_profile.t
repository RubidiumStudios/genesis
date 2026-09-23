#!/usr/bin/env perl
# The opt-in profiler.  Loaded through PERL5OPT with GENESIS_TEST_PROFILE
# naming a log, it records every command Genesis::run spawns and every
# profiled process's own CPU, each line tagged with the test file the process
# descends from, so t/bin/profile-report can say where a file's time went.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use File::Temp qw/tempdir/;
use Genesis qw/slurp/;

my $dir = tempdir(CLEANUP => 1);
my $log = "$dir/profile.log";

# A stand-in for a test file.  Its name ends in .t, which is what the
# profiler takes a test process by, and it spawns one command of its own.
my $script = "$dir/fixture.t";
put_file($script, <<'EOS');
use Genesis;
Genesis::run({stderr => 0}, 'true');
Genesis::run({stderr => 0}, 'echo "$1" >/dev/null', 'hello');
EOS

subtest 'a profiled process logs what it spawned and what it cost' => sub {
	plan tests => 5;

	local $ENV{GENESIS_TEST_PROFILE} = $log;
	local $ENV{PERL5OPT} = "-I$helper::TOPDIR/t -I$helper::TOPDIR/lib -MHarness::Profile";
	delete local $ENV{HARNESS_PROFILE_ROOT};
	system($^X, $script) == 0 or die "fixture failed: $?";

	my @lines = map {[split /\t/]} split /\n/, slurp($log);
	my @runs  = grep {$_->[0] eq 'run'}  @lines;
	my @procs = grep {$_->[0] eq 'proc'} @lines;

	is_deeply([map {$_->[5]} @runs], ['true', 'echo'],
		'each spawned command is logged by its program name');
	ok((grep {$_->[4] >= $_->[3]} @runs) == 2,
		'with a start and an end, the end no earlier than the start');
	is(scalar(@procs), 1, 'and the process logs its own cost once, at exit');
	like($procs[0][3], qr{fixture\.t$}, 'naming itself');
	is($runs[0][1], $procs[0][1],
		'and every line carries the test file the process belongs to');
};

subtest 'the report reads the log one test file at a time' => sub {
	plan tests => 3;

	my $report = qx($^X $helper::TOPDIR/t/bin/profile-report $log);
	is($? >> 8, 0, 'the report reads the log');
	like($report, qr{fixture\.t}, 'names the test file');
	like($report, qr{^\s*test\s+true\s+1\b}m,
		'and counts what the test process spawned, by program');
};

subtest 'nothing is logged without the variable' => sub {
	plan tests => 1;

	unlink $log;
	delete local $ENV{GENESIS_TEST_PROFILE};
	local $ENV{PERL5OPT} = "-I$helper::TOPDIR/t -I$helper::TOPDIR/lib -MHarness::Profile";
	system($^X, $script) == 0 or die "fixture failed: $?";
	ok(!-e $log, 'no log is written, so loading it by accident costs nothing');
};

done_testing;
