#!/usr/bin/env perl
# Proves T215, the stale-pipeline warning: a deploy whose pipeline no longer
# matches control says so, names every environment whose shape has changed and
# the reason each changed, and names genesis pipeline-apply as the way back
# into step.  The two reasons the one staleness query answers with are read
# here, one per subtest, because the warning prints whatever the query says
# and a file that only ever built one of them would not show that.
#
# The environment the warning names is the one being deployed, and that is a
# consequence of where the read is made rather than a choice of these rows.
# The deploy asks the query from the deployment branch, which the branch class
# has stood the tree on, and a delivery carries the deploying environment's own
# hierarchy and no sibling's.  So the roster the query walks on this path holds
# one name, and a row that changed a sibling's file would watch the warning say
# nothing.
#
# The ordering half of T215, that this warning prints ahead of the due-commits
# warning, is read in the due-commits file beside this one, where both
# messages stand in front of one run.
#
# Every run calls fixture_bosh, because each of these rows asserts that the
# deploy proceeded past the warning, and a deploy that reaches its end needs
# the director, the bosh, and the kit that builder puts up.
#
# Every run passes --no-propagate.  The auto-cascade hands off to a child
# genesis propagate, which fails today, and a row about what the deploy said
# should not be reading the child's failure as the deploy's.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a pipeline-defining path changed since the apply warns' => sub {
	plan tests => 5;

	# seeded_harness applies the pipeline at control's tip, delivers the
	# environment from that same commit and certifies it there, so the
	# repository starts in step with itself and the one thing below moves it
	# out of step.
	my $h = seeded_harness();
	fixture_bosh($h);

	# The environment's own file is a pipeline-defining path, and this writes
	# it on control alone: the branch still carries the file as the delivery
	# left it, so the change is one only a reader of control can see.  The
	# body is written through the harness rather than by hand, so what lands
	# on control is a file Genesis can still read, and the change is made to
	# the genesis.pipeline block, which is what D43 counts as defining the
	# pipeline's shape.
	write_env_file($h, 'qa', pipeline => {require_pr => 'true'});
	push_from($h, 'a', $h->control);

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the deploy proceeded past the warning');
	like(unfolded($err), qr/pipeline .*(?:stale|out of date)/i,
		'it warns that the pipeline no longer matches control')
		or diag("what the deploy said:\n$err");
	like(unfolded($err), qr/\bqa: configuration-changed\b/,
		'naming the environment that changed and why it changed')
		or diag("what the deploy said:\n$err");
	like(unfolded($err), qr/genesis pipeline-apply/,
		'and naming the apply that brings the pipeline back into step');
};

subtest 'a compiled dependency set the last deploy never read warns' => sub {
	plan tests => 4;

	# The other reason the query answers with, and it moves nothing on
	# control: the pipeline compiled a dependency for this environment that
	# its last deployment did not record reading, which is D77's fact
	# standing against the compile's prediction.  The warning is the same
	# warning and reads the reason off the query rather than deciding it.
	my $h = seeded_harness(dependencies => {qa => ['lab/bosh']});
	fixture_bosh($h);

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the deploy proceeded past the warning');
	like(unfolded($err), qr/pipeline .*(?:stale|out of date)/i,
		'it warns that the pipeline no longer matches control')
		or diag("what the deploy said:\n$err");
	like(unfolded($err), qr/\bqa: dependencies-changed\b/,
		'naming the environment and the reason the query gave for it')
		or diag("what the deploy said:\n$err");
};

subtest 'a sibling changed only on control is named as well' => sub {
	plan tests => 3;

	# This row could not stand while the staleness query
	# took its roster from the working tree.  A deploy stands on the
	# deployment branch, which carries the deploying environment's hierarchy
	# and no sibling's, so staging's file is nowhere in front of this command
	# and a roster read from that tree held one name.  The roster now comes
	# from control, and this is what that buys: D43 asks the deploy to name
	# the environments that changed, and staging is one of them.
	#
	# bosh => 1 stands the director and the kit up before the seeding, which
	# is what lets the deploy reach its end and what lets the walk read a
	# propagation set at the commit below.
	my $h = ready_harness(envs => ['qa', 'staging'], bosh => 1);

	# The change lands on staging's own file, so nothing is due to qa: the
	# commit routes to staging alone, and this row is about the roster.
	write_env_file($h, 'staging', pipeline => {require_pr => 'true'});
	push_from($h, 'a', $h->control);

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the deploy proceeded past the warning');
	like(unfolded($err), qr/\bstaging: configuration-changed\b/,
		'and the warning names the sibling this branch does not carry')
		or diag("what the deploy said:\n$err");
};

subtest 'an applied pipeline that nothing has changed warns nothing' => sub {
	plan tests => 3;

	# Green on arrival, and disclosed as the pair to the first subtest: the
	# same shape with its one change left out, so what separates the two is
	# the change and not the fixtures.  What it catches is a warning that
	# fires whenever a pipeline is applied at all, which is the wrong
	# implementation nearest to hand here, since the staleness query would
	# then never be asked and every deploy would be told to run the apply.
	my $h = seeded_harness();
	fixture_bosh($h);

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the deploy proceeded');
	unlike(unfolded($err // ''), qr/genesis pipeline-apply/,
		'and said nothing about an apply that is not owed')
		or diag("what the deploy said:\n$err");
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
