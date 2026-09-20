#!/usr/bin/env perl
# The two warnings that read a deployment branch's newest marker, driven
# against a clone that does not hold the branch.
#
# Both read the marker through Genesis::CI::Marker::newest and both answer
# with an `or return`, which says their authors expected a branch that is not
# there to be silent.  The walk underneath them refuses a ref git cannot
# resolve, so without a guard a clone holding only the remote-tracking ref
# takes a fatal exit out of a path that exists to print a warning.
#
# A fresh clone is exactly that shape.  git checks out one branch and leaves
# every other as a remote-tracking ref alone, so the first deploy an operator
# runs after cloning is the run these rows are about.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Output;

use Genesis;

use_ok 'Genesis::Env';
use_ok 'Genesis::Commands::Env';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# The kit is named because the environments are loaded here rather than
# deployed, and an environment whose root does not hold its kit will not load.
my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
fixture_vault($h);
init_branch($h, 'qa');

my $slug = $h->slug('qa');
my $git  = $h->git('a');

# The branch is fetched so the tracking ref is there, and then the local head
# is taken off.  That is what a clone looks like for every branch but the one
# git checked out, and it is the state both guards are about.
refresh($h, 'a', $slug);
delete_local($h, 'a', $slug);

subtest 'the fixture is a clone that holds only the tracking ref' => sub {
	plan tests => 2;

	ok(!$git->branch_exists($slug),
		'the deployment branch is not a local head here');
	ok($git->branch_exists("origin/$slug"),
		'and the remote-tracking ref is');
};

subtest 'the secrets warning says nothing where the branch is absent' => sub {
	plan tests => 2;

	# The record has to carry a certified commit, because the two returns
	# above the marker read answer first for an environment that never
	# deployed and this row is about the one below them.
	certify($h, 'qa', commit => 'abc1234', control_commit => 'def5678');
	my $env = top_for($h)->load_env('qa')->with_vault;

	my $answered;
	my $said = stderr_from {
		$answered = $env->warn_uncertified_secrets_target(undef, $git);
	};

	is($answered, 0, 'it answers the silent 0 its own return promises');
	is($said, '', 'and warns about nothing');
};

subtest 'the drift warning says nothing where the branch is absent' => sub {
	plan tests => 2;

	my $env = top_for($h)->load_env('qa')->with_vault;

	my $answered;
	my $said = stderr_from {
		$answered = Genesis::Commands::Env::_warn_drifted($env, $git);
	};

	is_deeply($answered, [], 'it answers the empty list its own return promises');
	is($said, '', 'and warns about nothing');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
