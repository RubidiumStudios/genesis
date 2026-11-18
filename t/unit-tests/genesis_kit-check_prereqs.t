#!/usr/bin/env perl
# A kit's prereqs hook runs through run_hook, is a known hook, and decides
# whether check_prereqs passes by how the script ended.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Helpers;
use Genesis::Kit;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/kit";
mkdir "$dir/kit/hooks";
mkdir "$dir/work";
Genesis::Helpers->write("$dir/kit/.helper");

package FakeEnv {
	sub get_environment_variables { () }
	sub workpath { "$dir/work/$_[1]" }
	sub name { 'fake-env' }
}

ok(scalar(grep { $_ eq 'prereqs' } Genesis::Kit::known_hooks()), 'prereqs is a known hook');
ok(scalar(grep { $_ eq 'feature' } Genesis::Kit::known_hooks()), 'the feature entry is still there');

sub check_with_prereqs {
	my ($exit) = @_;
	put_file("$dir/kit/hooks/prereqs", 0755, "#!/bin/bash\nexit $exit\n");
	no warnings qw/redefine once/;
	local *Genesis::Kit::has_hook = sub { $_[1] eq 'prereqs' };
	local *Genesis::Kit::id = sub { "fake/1.0.0" };
	local *Genesis::Kit::name = sub { "fake" };
	local *Genesis::Kit::version = sub { "1.0.0" };
	local *Genesis::Kit::metadata = sub { {} };
	local *Genesis::Kit::path = sub { my $p = $_[1]; $p ? "$dir/kit/$p" : "$dir/kit" };
	local %ENV = (%ENV,
		GENESIS_LIB => "$ENV{GENESIS_TOPDIR}/lib",
		GENESIS_ROOT => "$dir/root",
		GENESIS_ENVIRONMENT => 'fake-env',
		GENESIS_NO_MODULE_HOOKS => 1,
	);
	my ($ok, $error);
	my ($log, $stderr) = capture_trace {
		$ok = eval { bless({}, 'Genesis::Kit')->check_prereqs(bless({}, 'FakeEnv')) };
		$error = $@;
	};
	return ($ok, $error, $stderr);
}

subtest 'a prereqs hook that exits 0 passes' => sub {
	my ($ok, $error) = check_with_prereqs(0);
	is($error, '', 'no error is raised');
	ok($ok, 'check_prereqs passes');
};

subtest 'a prereqs hook that exits nonzero fails' => sub {
	my ($ok, $error, $stderr) = check_with_prereqs(4);
	is($error, '', 'no error is raised');
	ok(!$ok, 'check_prereqs fails');
	like($stderr, qr/Prerequisite check for kit .*fake\/1\.0\.0.* failed/, 'and says the prerequisite check failed');
};

done_testing;
