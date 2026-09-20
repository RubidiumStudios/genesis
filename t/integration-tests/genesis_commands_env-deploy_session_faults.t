#!/usr/bin/env perl
# Proves T233, the refusal on a tracked modification before the first write;
# T234, the unswitched deploy that opens no session and tolerates the edit;
# T231, the failed restore that dies naming what it could not restore; and
# T232, the SIGINT between the switch and the BOSH step.
#
# Three of the four arrive green, because the session and the gate are
# already in place.  T234 is the one that drives code, and what it drives is
# D80's "will switch" trigger in the gate.
#
# The first two rows make the same edit to the same file and differ only in
# the branch the operator is standing on, because that is the whole of what
# D80 settles: a deploy from control is about to leave the branch and refuses
# to carry an uncommitted change across, and a deploy from the environment's
# own branch is leaving nothing and has no reason to object.
#
# Every row here calls fixture_bosh, even the two whose deploys never reach a
# director.  It is the builder that catches the operator's own copy of the
# deployment branch up to what the remote carries, and a branch still sitting
# at the commit pipeline-apply cut carries no repository, which the gate
# declines to switch onto.  Without it the first row would be asserting a
# refusal that never ran.
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

subtest 'a switching deploy refuses on a tracked modification' => sub {
	# Green on arrival.  It catches a deploy that keeps a cleanliness check
	# of its own, which bailed with a message naming no file.
	plan tests => 4;

	my $h = seeded_harness();
	fixture_bosh($h);
	stand_on($h, $h->control);

	# Armed with nothing planned, because the step log the last row of this
	# subtest reads is only written where fault_git has armed it.
	fault_git($h);

	my $edited = edited_file($h, 'qa');
	mkfile_or_fail($h->a.'/'.$edited,
		slurp($h->a.'/'.$edited)."# edited in place\n");

	my ($out, $err, $exit) = run_genesis($h, 'qa', 'deploy', '-y', 'a reason');

	isnt($exit, 0, 'the deploy refused');
	# The session's own wording carries the name, rather than the name alone.
	# A deploy has many ordinary reasons to print the environment's file name
	# on stderr, and the guard's whole subject is a refusal that named no
	# file, so the name has to be read where the refusal put it.  The words
	# are matched across whitespace, because the message is wrapped to the
	# terminal width before an operator sees it.
	my $refusal =
		qr/uncommitted\s+changes,\s+and\s+this\s+command\s+switches/;
	like($err, qr/$refusal.*\Q$edited\E/s,
		'naming the modified file in the session\'s own refusal');
	my @writes = grep {$_->[0] =~ /^(checkout|commit|push)$/} step_log($h->git('a'));
	is_deeply(\@writes, [], 'it refused before its first write');
};

subtest 'an unswitched deploy opens no session and keeps the edit' => sub {
	plan tests => 4;

	my $h = seeded_harness();
	fixture_bosh($h);
	stand_on($h, $h->slug('qa'));

	my $edited = edited_file($h, 'qa');
	my $body = slurp($h->a.'/'.$edited)."# edited in place\n";
	mkfile_or_fail($h->a.'/'.$edited, $body);

	# --no-propagate for the reason the rows in the neighbouring files give:
	# the auto-cascade hands off to a child genesis propagate, which writes
	# to deployment branches on purpose, and a row about what this deploy did
	# should not be reading the child's work as its own.
	my ($out, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'a reason');

	is($exit, 0, 'the deploy succeeded');
	is(slurp($h->a.'/'.$edited), $body,
		'the file is as the operator wrote it');
	ok(!-e $h->a.'/.git/genesis-session.lock',
		'no session opened, so no switch lock was taken');
};

subtest 'a restore that cannot run dies naming what it could not restore' => sub {
	# Green on arrival.  It catches a restore run under passfail with its
	# exit swallowed, which leaves the operator on the wrong branch quietly.
	# The run ends somewhere else on purpose, so it asserts nothing back.
	plan tests => 3;

	my $h = seeded_harness();
	fixture_bosh($h);
	stand_on($h, $h->control);
	my $git = fault_git($h);

	# The switch is the first checkout of the run and the restore is the
	# second, and everything from the second onward is made to report and not
	# land.  A fault that died here would die in the checkout's own words and
	# the session would never reach the sentence this row is about, and
	# skipping from the second call rather than at it leaves the row reading
	# the same sentence if a later step ever checks something out in between.
	skip_on($git, 'checkout', 2, from => 1);

	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '--no-propagate', '-y', 'a reason');

	isnt($exit, 0, 'the command failed loudly');
	like($err, qr/Failed to return to/, 'and said so in the session\'s words');
	like($err, qr/\Q@{[$h->control]}\E/, 'naming the branch it could not return to');
};

subtest 'an interrupt between the switch and BOSH restores what it can' => sub {
	# The restoration was green on arrival, and it catches a session whose
	# signal handler was never installed, which would leave the operator on
	# the deployment branch.  The sentence below it is what tells the
	# interrupt from an ordinary failed deploy: bin/genesis routes SIGINT to
	# a bail that says "Genesis halted due to user interrupt", and no other
	# path says it, so a run that reached the same two answers by failing
	# rather than by being interrupted proves nothing and is caught here.
	plan tests => 3;

	my $h = seeded_harness();
	fixture_bosh($h);
	stand_on($h, $h->control);
	# Scoped rather than set and deleted, so a death below cannot leave the
	# signal armed for a later row in this file.
	local $ENV{GENESIS_HARNESS_SIGINT_BEFORE_BOSH} = 1;

	# bin/genesis installs its interrupt handler only where GENESIS_TESTING
	# is unset, and the suite sets that for every run, so a row whose whole
	# subject is the handler has to hand the command an environment without
	# it.  Nothing else about the run changes, and the command is interrupted
	# before it reaches the director either way.
	delete local $ENV{GENESIS_TESTING};

	my $w = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '--no-propagate', '-y', 'a reason');
	isnt($exit, 0, 'the failure is reported');
	like($err, qr/Genesis halted due to user interrupt/,
		'genesis acted on the interrupt and not on a failed deploy');

	assert_w_restored($w, 'the signal path');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
