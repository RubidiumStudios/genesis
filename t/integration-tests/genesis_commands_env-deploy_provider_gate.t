#!/usr/bin/env perl
# Proves T222, the refusal at NOPERM without --force; T224, the non-terminal
# rule and the two skips; T235, the H33 shape, which is that nothing here
# takes a lock at all; and the half of T239 a spawned run can show, which is
# that a deploy past the gate writes no shuttle event.
#
# The acknowledgement's own rows are in
# t/unit-tests/genesis_ci_preflight-deploy_gate.t, because the suite cannot
# give a spawned command a terminal to answer from: helper::set_stdin hands a
# spawned command a pipe, and Genesis::Term::in_controlling_terminal answers
# false for every run this file makes.
#
# make_harness defaults the provider to manual and a manual tree never meets
# the gate, so every harness here names its provider outright.
#
# Every run passes --no-propagate.  The auto-cascade hands off to a child
# genesis propagate, which M15 owns and which fails today, and a row about
# the gate should not be reading the child's work as the deploy's own.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'an automated provider refuses without --force' => sub {
	# Four rows, and one more for the restoration run_genesis asserts for
	# itself on every run a row does not turn it off for.
	plan tests => 5;

	my $h = gated_harness(provider => 'concourse');

	# Only fault_git arms the step log the child appends to, and this row
	# plans no fault: it wants the log and nothing else.  The log is emptied
	# first, because the seeding above ran through the same handle.
	my $git = fault_git($h);
	reset_steps($git);

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');
	my $said = unfolded($err);

	is($exit, Genesis::Exit::NOPERM, 'it exits NOPERM');
	like($said, qr/pipeline/, 'it names the pipeline that owns the deploy');
	like($said, qr/locks?\b/, 'and the locks a CLI deploy cannot take');

	# The switch is not among these.  The branch class stands the tree on
	# <env>/<type> before the command runs at all and puts it back after, so
	# a checkout here says nothing about the gate.  What the refusal has to
	# leave untouched is the record of the deploy, which is the commit the
	# deploy would make and the push that would deliver it.
	is_deeply([grep {$_->[0] eq 'commit' || $_->[0] eq 'push'} step_log($git)],
		[], 'and nothing was committed or pushed');
};

subtest 'outside a terminal, in a job, and under the manual provider' => sub {
	# Four rows, and one more for each of the three runs' own restoration
	# assertions.
	plan tests => 7;

	my $h = gated_harness(provider => 'concourse');
	my (undef, undef, $exit) = run_genesis($h,
		'qa', 'deploy', '--force', '--no-propagate', '-y', 'r');
	is($exit, Genesis::Exit::NOPERM,
		'an acknowledgement nobody reads is not one');

	my $job = gated_harness(provider => 'concourse');
	my (undef, $err2, $exit2) = run_genesis($job, {pipeline_task => 'deploy-qa'},
		'qa', 'deploy', '--no-propagate', '-y', 'r');
	isnt($exit2, Genesis::Exit::NOPERM, 'a pipeline job skips the gate');
	unlike(unfolded($err2 // ''), qr/owns deploys of/,
		'and is never told the pipeline owns what it is doing');

	my $manual = gated_harness(provider => 'manual');
	my (undef, $err3, undef) = run_genesis($manual,
		'qa', 'deploy', '--no-propagate', '-y', 'r');
	unlike(unfolded($err3 // ''), qr/owns deploys of/,
		'and the manual provider never meets the gate');
};

subtest 'a deploy past the gate writes no shuttle event' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	my $h = gated_harness(provider => 'concourse');
	# The three things a deploy has to reach before it finishes at all.
	fixture_bosh($h);
	my $spy = shuttle_spy($h);

	my (undef, undef, $exit) = run_genesis($h, {pipeline_task => 'deploy-qa'},
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the deploy succeeded');

	# An absence guard, and the half of T239 a spawned run can show.  The spy
	# writes an empty log rather than no log, so this reads an answer rather
	# than an absence.  What it catches is a deploy that wakes the
	# deployments reading this one the way a propagation does, which is the
	# fan-out the acknowledgement promises does not happen.
	is_deeply([shuttle_requests($spy)], [],
		'and no shuttle event was written, so no dependent was woken');
};

subtest 'the locks the gate stands for are taken nowhere' => sub {
	# An absence guard, stated as one.  It is green on arrival and it catches
	# a later step that gives the deploy a locker of its own, which would let
	# a CLI deploy run beside a pipeline job while each believed it held
	# something.  The gate exists because there is no lock to take, so the
	# absence is the claim.
	plan tests => 2;

	ok(!-e 'lib/Service/Locker.pm',
		'no locker client exists under lib/Service/');
	my $read = join('', map {helper::get_file($_) // ''}
		grep {-e $_} qw(lib/Genesis/Commands/Env.pm lib/Genesis/Env.pm));
	unlike($read, qr/pipeline\.locker/,
		'and nothing on the deploy path reads pipeline.locker');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
