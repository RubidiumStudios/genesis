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
# nothing.  The report of this task carries that as a concern.
#
# The ordering half of T215, that this warning prints ahead of the due-commits
# warning, is Task 13.9's, which builds _warn_commits_due.  Nothing prints a
# due-commits warning yet, so a row reading the order here would be reading one
# message against another that is not there.
#
# Every run calls fixture_bosh, because each of these rows asserts that the
# deploy proceeded past the warning, and a deploy that reaches its end needs
# the director, the bosh, and the kit that builder puts up.
#
# Every run passes --no-propagate.  The auto-cascade hands off to a child
# genesis propagate, which M15 owns and which fails today, and a row about what
# the deploy said should not be reading the child's failure as the deploy's.
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
	# on control is a file Genesis can still read, and params carries the
	# change because it names nothing the pipeline reads and so cannot pass
	# for a second reason the warning might be firing on.
	write_env_file($h, 'qa', params => {shape => 'changed'});
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

subtest 'an applied pipeline that nothing has changed warns nothing' => sub {
	plan tests => 3;

	# The same shape as the first subtest with its one change left out, so
	# what separates the two is the change and not the fixtures.
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
