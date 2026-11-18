#!/usr/bin/env perl
# has_hook accepts hooks/<name>.sh, so run_hook has to run that same file.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
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

sub fake_kit {
	no warnings qw/redefine once/;
	*Genesis::Kit::id = sub { "fake/1.0.0" };
	*Genesis::Kit::name = sub { "fake" };
	*Genesis::Kit::version = sub { "1.0.0" };
	*Genesis::Kit::path = sub { my $p = $_[1]; $p ? "$dir/kit/$p" : "$dir/kit" };
	return bless({}, 'Genesis::Kit');
}

local %ENV = (%ENV,
	GENESIS_LIB => "$ENV{GENESIS_TOPDIR}/lib",
	GENESIS_ROOT => "$dir/root",
	GENESIS_ENVIRONMENT => 'fake-env',
	GENESIS_NO_MODULE_HOOKS => 1,
);

subtest 'a kit that ships only hooks/<name>.sh can run that hook' => sub {
	put_file("$dir/kit/hooks/blueprint.sh", 0644, "#!/bin/bash\necho manifests/from-sh.yml\n");
	my $kit = fake_kit();
	ok($kit->has_hook('blueprint'), 'the kit is reported as having the hook');
	my $files = eval { $kit->run_hook('blueprint', env => bless({}, 'FakeEnv')) };
	is($@, '', 'running it does not fail');
	is_deeply($files, ['manifests/from-sh.yml'], 'and runs the .sh script');
	unlink "$dir/kit/hooks/blueprint.sh";
};

subtest 'a plain hook still wins over a .sh of the same name' => sub {
	put_file("$dir/kit/hooks/blueprint", 0755, "#!/bin/bash\necho manifests/plain.yml\n");
	put_file("$dir/kit/hooks/blueprint.sh", 0644, "#!/bin/bash\necho manifests/from-sh.yml\n");
	my $kit = fake_kit();
	my $files = eval { $kit->run_hook('blueprint', env => bless({}, 'FakeEnv')) };
	is_deeply($files, ['manifests/plain.yml'], 'the plain script runs');
};

done_testing;
