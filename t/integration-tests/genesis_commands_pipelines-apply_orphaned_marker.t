#!/usr/bin/env perl
# Proves T135: a force push of control that drops a commit leaves every marker
# and every certified commit naming an object no fresh clone can fetch.
#
# Genesis never moves control, because control is the operator's own branch, so
# nothing in the product can stop that rewrite from happening.  The branch
# protection the apply asks for is what refuses the push, and this file holds
# the damage that protection prevents rather than the rule itself, which is
# read back beside the apply that sends it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

subtest 'the rewrite orphans every marker that named the dropped commit' => sub {
	# Four rows, and one more for the run's own restoration assertion, which
	# run_genesis makes unless a row turns it off.
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], github => 1);
	run_genesis($h, 'pipeline-apply');

	# The seed leaves control one commit deep, and a rewrite that drops the
	# commit behind the tip needs a tip above the one it is going to drop, so
	# control is given two commits of its own before the rewrite runs.
	commit_on_control($h, files => {'ops/one.yml' => "---\none: 1\n"},
		message => 'the commit the rewrite drops', push => 1);
	commit_on_control($h, files => {'ops/two.yml' => "---\ntwo: 2\n"},
		message => 'the commit the rewrite keeps', push => 1);

	my $dropped = rewrite_control($h);
	deliver($h, 'qa', control => $dropped);
	certify($h, 'qa', control_commit => $dropped);

	is(harness_marker($h, $h->slug('qa')), $dropped,
		'the branch tip carries a marker naming the dropped commit');
	is(secret($h->env_path('qa') . ':git.control_commit'), $dropped,
		'the certified commit in exodus equals it');

	# The clone is cut over file://, which is what clone_copy does and what a
	# plain local clone does not.  Git hardlinks the whole object store of a
	# path it is handed, so a clone made that way would arrive holding the
	# dropped commit and this row would pass for the wrong reason.
	my $key = clone_copy($h);
	my $reachable = run({dir => $h->{$key}, passfail => 1},
		'git', 'cat-file', '-e', "$dropped^{commit}");
	ok(!$reachable, 'a fresh clone cannot fetch the object either of them names');

	ok(!reachable_on_r($h, $dropped),
		'and no branch on the remote reaches the commit any longer');
};

done_testing;
