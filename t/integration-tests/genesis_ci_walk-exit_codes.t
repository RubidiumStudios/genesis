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
	# to qa, which is the failure D96 lets the run walk past.
	my $h = ready_harness(envs => ['lab', 'qa'], kit => 'broken-blueprint');
	write_env_file($h, 'qa', genesis => {kit_blueprint_fails => 1});
	push_from($h, 'a', $h->control);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, Genesis::Exit::TEMPFAIL, 'the run exits TEMPFAIL');
	like($err, qr/qa.*failed/s, 'the report says which environment failed');
};

subtest 'an environment the run never attempted exits TEMPFAIL' => sub {
	plan tests => 3;

	# qa asks for delivery by pull request, which is the one stage of the
	# publish the run does not build yet, so the run reaches qa, writes
	# nothing for it, and records that it was not attempted.  Nothing about
	# qa is broken and no other environment lost anything, so the status is
	# the only place the run can say that it was partial.
	my $h = ready_harness(envs => ['lab', 'qa'], kit => 'omega-v2.7.0');
	write_env_file($h, 'qa', pipeline => {require_pr => 'true'});
	push_from($h, 'a', $h->control);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, Genesis::Exit::TEMPFAIL, 'the run exits TEMPFAIL');
	like($err, qr/qa: not attempted/, 'qa records that it was not attempted');
};

done_testing;
