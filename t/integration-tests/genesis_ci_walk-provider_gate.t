#!/usr/bin/env perl
# Proves T156, T169, T170, T171, and T179: the disowned pipeline's refusal
# and the behaviours of the propagate provider gate that a spawned command
# can show.  The three that turn on a controlling terminal are proved in
# t/unit-tests/genesis_commands_pipelines-provider_gate.t, because the suite
# cannot give a spawned command a terminal to answer from.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the applied record with the pipeline disabled refuses' => sub {
	# Five rows, and one more for the restoration the run asserts for
	# itself, which run_genesis makes unless a row turns it off.
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], pipeline => 0);
	# The record names the commit rather than the branch, because nothing
	# resolves a name written here and every staleness read behind it would
	# be answered from a string git never gave.
	my $applied = fixture_applied($h, control => $h->git('a')->sha($h->control));

	# Both the refusal and everything else Genesis says about itself go to
	# standard error, so the message comes back in the second value.  It is
	# read unfolded, because the refusal is wrapped to the terminal's width
	# on its way out and a phrase a row looks for can arrive with a newline
	# and an indent in the middle of it.
	my ($out, $err, $exit) = run_genesis($h, 'propagate');
	my $said = unfolded($err);
	is($exit, Genesis::Exit::CONFIG, 'it exits CONFIG');
	like($said, qr/\Q$applied\E|applied record|pipeline-apply applied it/,
		'it names the applied record');
	like($said, qr/pipeline\.enabled/, 'it names the key');
	like($said, qr/tear the pipeline down/, 'it gives the second remedy');
	like($said, qr/Nothing was written/, 'it says nothing was written');
};

subtest 'a bare run under an automated provider refuses' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h = make_harness(envs => ['lab', 'qa'], provider => 'concourse');
	fixture_applied($h,
		control  => $h->git('a')->sha($h->control),
		provider => 'concourse');
	certify($h, 'lab', control_commit => $h->git('a')->sha($h->control));

	my ($out, $err, $exit) = run_genesis($h, 'propagate');
	my $said = unfolded($err);
	is($exit, Genesis::Exit::NOPERM, 'it exits NOPERM');
	like($said, qr/pipeline/, 'it names the pipeline that owns the work');
	like($said, qr/--force/, 'it names the one way past');
	unlike($out, qr/control\@/, 'it refused before it walked');
};

subtest 'what a spawned run can show of the gate' => sub {
	# Five rows, and one more for each of the three runs' own restoration
	# assertions.  No run here has a controlling terminal, because nothing
	# the suite spawns does, so --force alone can only be refused.
	plan tests => 8;

	my $h = make_harness(envs => ['lab', 'qa'], provider => 'concourse');
	fixture_applied($h,
		control  => $h->git('a')->sha($h->control),
		provider => 'concourse');
	certify($h, 'lab', control_commit => $h->git('a')->sha($h->control));

	my (undef, undef, $force_exit) = run_genesis($h, 'propagate', '--force');
	is($force_exit, Genesis::Exit::NOPERM,
		'force alone keeps the refusal with no terminal');

	my (undef, undef, $task_exit) =
		run_genesis($h, {pipeline_task => 'propagate'}, 'propagate');
	isnt($task_exit, Genesis::Exit::NOPERM,
		'GENESIS_PIPELINE_TASK skips the gate');

	# The warning is a warning, so it goes to standard error with everything
	# else Genesis says about itself, and a row reading standard output for
	# it would pass on an empty string.
	my ($dry_out, $dry_err, $dry_exit) =
		run_genesis($h, 'propagate', '--dry-run');
	isnt($dry_exit, Genesis::Exit::NOPERM, '--dry-run passes the gate');
	like(unfolded($dry_err), qr/by hand/,
		'--dry-run still prints the warning');
	unlike(unfolded($dry_out, $dry_err), qr/Proceed anyway\?/,
		'--dry-run does not ask');
};

subtest 'the locks the run cannot take are what the gate stands for' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	my $h = make_harness(envs => ['lab', 'qa'], provider => 'concourse');
	fixture_applied($h,
		control  => $h->git('a')->sha($h->control),
		provider => 'concourse');
	my $git = fault_git($h);
	reset_steps($git);

	my (undef, undef, $exit) = run_genesis($h, 'propagate');
	is($exit, Genesis::Exit::NOPERM, 'the run refuses rather than writing');
	is(scalar(grep {$_->[0] eq 'push'} step_log($git)), 0,
		'nothing was pushed while the pipeline held its locks');
};

done_testing;
