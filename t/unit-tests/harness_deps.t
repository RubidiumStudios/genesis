#!/usr/bin/env perl
# The dependency recorder.  Loaded through PERL5OPT with GENESIS_TEST_DEPS
# naming a log, each test process, and each genesis child it runs, records at
# exit which files under lib/ and t/ it loaded, tagged with the test file it
# belongs to.  t/bin/affected-tests reads that record to choose the tests a
# change can reach.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Genesis qw/slurp/;

my $dir = "$helper::TMP/deps";
mkdir $dir;
my $log = "$dir/deps.log";

# A stand-in for a genesis child: its name is what the recorder takes a child
# by, and it loads a module the test file itself never does.
put_file("$dir/genesis", 0755, <<"EOS");
#!$^X
use lib '$helper::TOPDIR/lib';
require Genesis::Top;
EOS

# A stand-in for a test file, which loads one module and runs the child.
my $script = "$dir/fixture.t";
put_file($script, <<"EOS");
use lib '$helper::TOPDIR/lib';
require Genesis::Kit;
system('$dir/genesis') == 0 or die "child failed: \$?";
EOS

subtest 'a test file and its genesis child record what they loaded' => sub {
	plan tests => 5;

	local $ENV{GENESIS_TEST_DEPS} = $log;
	local $ENV{PERL5OPT} = "-I$helper::TOPDIR/t -MHarness::Deps";
	delete local $ENV{HARNESS_DEPS_ROOT};
	system($^X, $script) == 0 or die "fixture failed: $?";

	my %loaded;
	for (split /\n/, slurp($log)) {
		my ($test, $file) = split /\t/;
		$loaded{$file} = $test;
	}
	is($loaded{'lib/Genesis/Kit.pm'}, $script, 'the module the test file loaded is recorded against it');
	is($loaded{'lib/Genesis/Top.pm'}, $script, "and so is the one only its genesis child loaded");
	ok(!grep({m{^/}} keys %loaded), 'every file is named relative to the repository');
	ok(!grep({!m{^(lib|t)/}} keys %loaded), 'and only files under lib/ and t/ are named');
	ok(!exists $loaded{'t/Harness/Deps.pm'}, 'the recorder does not name itself');
};

subtest 'nothing is recorded without the variable' => sub {
	plan tests => 1;

	unlink $log;
	delete local $ENV{GENESIS_TEST_DEPS};
	local $ENV{PERL5OPT} = "-I$helper::TOPDIR/t -MHarness::Deps";
	system($^X, $script) == 0 or die "fixture failed: $?";
	ok(!-e $log, 'no record is written');
};

done_testing;
