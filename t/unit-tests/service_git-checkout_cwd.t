#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Cwd qw/getcwd/;

use Genesis;
use_ok 'Service::Git';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# These exercise the real chdir behaviour, so run() is deliberately not
# stubbed: the defect being covered is that a checkout removing the current
# directory left the process with nowhere to return to.
sub make_repo {
	my $root = workdir() . '/repo-' . $$ . '-' . int(rand(1_000_000));
	mkdir_or_fail($root);

	my @git = ('git', '-C', $root);
	run({ dir => $root }, 'git', 'init', '-q', '-b', 'control', '.');
	run({ dir => $root }, 'git', 'config', 'user.email', 'test@example.com');
	run({ dir => $root }, 'git', 'config', 'user.name',  'Test');

	# control carries a deployment root; the env branch never has one.
	put_file("$root/README", "seed\n");
	run({ dir => $root }, 'git', 'add', '-A');
	run({ dir => $root }, 'git', 'commit', '-q', '-m', 'seed');
	run({ dir => $root }, 'git', 'branch', 'env-branch');

	mkdir_or_fail("$root/doomsday");
	put_file("$root/doomsday/env.yml", "---\nkit: {}\n");
	run({ dir => $root }, 'git', 'add', '-A');
	run({ dir => $root }, 'git', 'commit', '-q', '-m', 'add doomsday root');

	return $root;
}

subtest 'checkout survives losing the current directory' => sub {
	# Adding a deployment root to a repository whose environment branches
	# predate it: the branch being checked out has no doomsday/, so the
	# directory vanishes mid-checkout.  Returning to it afterwards is not
	# possible, and dying there blocks propagation from ever creating the
	# root on that branch.
	plan tests => 3;

	my $root = make_repo();
	my $git  = Service::Git->new($root);

	my $origin = getcwd();
	chdir("$root/doomsday") or die "cannot enter doomsday/: $!";

	eval { $git->checkout('env-branch'); 1 }
		or do { chdir($origin); fail("checkout died: $@"); return };
	pass('checkout did not die');

	is($git->current_branch, 'env-branch', 'the branch actually switched');

	my $landed = getcwd();
	ok(-d $landed, "left in a directory that exists ($landed)");

	chdir($origin);
};

subtest 'checkout keeps the current directory when it survives' => sub {
	# The ordinary case must be unchanged: a directory present on both
	# branches is still where the caller stands afterwards.
	plan tests => 2;

	my $root = make_repo();
	my $git  = Service::Git->new($root);

	my $origin = getcwd();
	mkdir_or_fail("$root/shared");
	chdir("$root/shared") or die "cannot enter shared/: $!";
	my $before = getcwd();

	$git->checkout('env-branch');
	is($git->current_branch, 'env-branch', 'the branch switched');
	is(getcwd(), $before, 'still in the same directory');

	chdir($origin);
};

done_testing;
