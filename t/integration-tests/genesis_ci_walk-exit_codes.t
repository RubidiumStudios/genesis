#!/usr/bin/env perl
# Proves T172: a run in which every environment ended published or held
# exits 0, and one in which any environment failed, was not attempted, or
# had its publish rejected exits TEMPFAIL.
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

subtest 'every environment published or held exits 0' => sub {
	# Four rather than three, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	# Every subtest in this file is counted the same way.
	plan tests => 4;

	# The three stages stand in a chain and all three track the shared ops
	# file, so one commit on that file is due to every one of them and the
	# ancestor that has not deployed it holds the stage below.
	my $h = ready_harness(
		envs    => ['lab', 'qa', 'prod'],
		kit     => 'omega-v2.7.0',
		chained => 1,
		tracked => ['ops/shared.yml'],
	);
	my $due = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'Bump shared ops', push => 1);
	certify($h, 'lab', control_commit => $due);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, 0, 'the run exits 0');
	like($err, qr/qa.*propagated/s, 'qa was propagated');
	like($err, qr/^\s*prod: held, \S/m, 'prod was held with its reason');
};

subtest 'one failed environment exits TEMPFAIL' => sub {
	plan tests => 3;

	# qa's file asks the suite's broken-blueprint kit to refuse, so the set
	# qa would receive cannot be enumerated and the walk confines the error
	# to qa, which is the kind of failure the run walks past.
	my $h = ready_harness(envs => ['lab', 'qa'], kit => 'broken-blueprint');
	write_env_file($h, 'qa', genesis => {kit_blueprint_fails => 1});
	push_from($h, 'a', $h->control);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, Genesis::Exit::TEMPFAIL, 'the run exits TEMPFAIL');
	like($err, qr/qa.*failed/s, 'the report says which environment failed');
};

subtest 'an environment the run never attempted exits TEMPFAIL' => sub {
	plan tests => 2;

	# The record is composed here rather than driven out of a run.  The one
	# run that ended normally with an environment recorded as not attempted
	# was the one that met the pull request guard, and that guard has gone
	# with the arm that replaced it, so the word is written by the abort
	# alone now, for the environments a run that ended early never reached.
	# An abort spends its own status, so the mapping this row is about is
	# the one thing a run can no longer show, and the sub that decides it is
	# asked directly.  The abort's own two statuses are proved end to end in
	# t/integration-tests/genesis_ci_walk-run_failures.t.
	require Genesis::Commands::Pipelines;

	is(Genesis::Commands::Pipelines::run_status({environments => [
		{env => 'lab', outcome => 'propagated'},
		{env => 'qa',  outcome => 'not attempted'},
	]}), Genesis::Exit::TEMPFAIL,
		'a run carrying an environment it never attempted is partial');

	is(Genesis::Commands::Pipelines::run_status({environments => [
		{env => 'lab', outcome => 'propagated'},
		{env => 'qa',  outcome => 'idempotent'},
	]}), 0, 'and one where every environment ended well is not');
};

done_testing;
