#!/usr/bin/env perl
# Proves T299, that `genesis prod pipeline-release` deletes the hold record,
# writes no released-by fields, logs the release with the identity of whoever
# ran it, and that a `genesis prod deploy -y` before the release leaves the
# record standing.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Sys::Hostname ();

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the release deletes the record and keeps no fields' => sub {
	# Six rows, one of which is this row's own restoration assertion, and
	# one more for the hold run, which asserts its restoration for itself.
	plan tests => 7;

	my $h    = held_prod_delivered();
	run_genesis($h, 'prod', 'pipeline-hold', 'waiting on the capacity report');
	my $path = $h->env_path('prod').'/hold';
	have_secret "$path:reason";

	# The time is read off the record before the release deletes it, so the
	# row below compares the two halves of one contract rather than matching
	# a phrase the sentence happens to carry.
	my $at = secret("$path:at");

	my $w = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'prod', 'pipeline-release');
	assert_w_restored($w, 'the release restored working state');
	is($exit, 0, 'the command succeeded');

	no_secret $path;

	# The second sentence is the half of the release's output that carries
	# the record, and it is written as its own info call, guarded on the
	# record having come back.  This row is what keeps a later reader from
	# folding the two calls back into one and printing two uninitialised
	# values where clear_hold answers an unreadable path as cleared.
	like(unfolded($out, $err),
		qr/held since \Q$at\E: waiting on the capacity report/,
		'and says when the hold had been set and what for');

	# The record is gone by the no_secret row above, so what is left to
	# watch for is a released-by field spoken rather than written.  The line
	# the release prints names who ran it, and a field of that name in it
	# would be the first sign that the record had grown one.
	#
	# This row was green before the command existed, since the run then
	# printed "Unrecognized command" and nothing else, so it is a guard over
	# what the output must go on not saying rather than a driver.  It is
	# weaker than it reads, too: a released-by field written to vault would
	# be caught by the no_secret row above, so what this one adds is the
	# watch on the output alone.
	unlike(unfolded($out, $err), qr/released.by|released_by/i,
		'no released-by field was written anywhere');
};

subtest 'the release is logged with the identity that ran it' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	#
	# T299 asks for the identity of whoever ran the release, and a record
	# written by the same process on the same host cannot tell that from the
	# identity of whoever took the hold.  So the hold is planted through the
	# fixture under an identity no run here can compose, and the two rows
	# below pull the readings apart: an implementation that read the record
	# back at the operator would name the planter and fail both of them.
	# The exit row is neither of those, and it is green on arrival, because
	# a release of a standing hold succeeds whichever identity it prints.
	# It is a guard, and what it guards is the reading of the three rows
	# under it, which say nothing about a run that never got as far as a
	# log line.
	plan tests => 5;

	my $h = held_prod_delivered();
	$h->fixture_hold('prod',
		reason   => 'waiting on the capacity report',
		user     => 'quartermaine',
		hostname => 'another.example.com');

	# The identity the release should print is composed here the way the
	# command composes it, through the same Sys::Hostname call rather than
	# through the shell, which can answer a fully qualified name where the
	# module answers a short one and fail the row on the host and not the
	# code.
	# USER carries the same fallback the command gives it, so a worker that
	# runs with the variable unset fails this row on the code rather than on
	# its environment, and the sprintf has no undefined value to warn about.
	my $who = sprintf('%s@%s',
		($ENV{USER} // 'unknown'), Sys::Hostname::hostname());

	my ($out, $err, $exit) = run_genesis($h, 'prod', 'pipeline-release');
	is($exit, 0, 'the command succeeded');
	like(unfolded($out, $err), qr/\Q$who\E/,
		'the log line names who released it');
	unlike(unfolded($out, $err), qr/quartermaine|another\.example\.com/,
		'and not who had held it, which the record still carried');
	like(unfolded($out, $err), qr/prod/, 'and names the environment it released');
};

subtest 'releasing where nothing stands says so' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	my $h = held_prod_delivered();

	my ($out, $err, $exit) = run_genesis($h, 'prod', 'pipeline-release');
	is($exit, 0, 'the command succeeded');
	like(unfolded($out, $err), qr/no propagation hold/i,
		'it says that nothing was on hold rather than claiming a release');
};

subtest 'more than one environment is a usage error' => sub {
	# Three rows, and one more for each of the two runs' own restoration
	# assertions.
	#
	# The second row is the one that discriminates.  An unrecognised command
	# exits 2 as well, so the code alone was already 2 before this command
	# existed, and what says the refusal is this command's own is the usage
	# block it answers with, which carries this command's summary and its
	# one argument rather than the whole command list.  The sentence
	# command_usage is given cannot be read here at all, because it is
	# printed only outside a test run.  The third row is a guard: a refused
	# release leaves the record where it was, and it could only stop being
	# true if the refusal moved after the delete.
	plan tests => 5;

	my $h = held_prod_delivered();
	run_genesis($h, 'prod', 'pipeline-hold', 'waiting on the capacity report');

	my ($out, $err, $exit) = run_genesis($h,
		'pipeline-release', 'prod', 'lab');
	is($exit, 2, 'the command refused with the usage code');
	like(unfolded($out, $err), qr/Usage: genesis pipeline-release \[<env>\]/,
		'and answered with this command\'s own usage, not the command list');
	have_secret $h->env_path('prod').'/hold:reason';
};

subtest 'a deploy with -y leaves the hold standing' => sub {
	# Five rows, one of which is this row's own restoration assertion, and
	# one more for each of the two runs that assert their restoration for
	# themselves.
	#
	# The last two rows are what makes this subtest discriminate.  Every row
	# above them passes before `pipeline-release` exists, because the deploy
	# leaving the record alone is a property the record already had.  The
	# release that follows is the other half of D50: the record the deploy
	# would not touch is cleared the moment a human asks for it, so the two
	# together say that clearing a hold is something only the release does.
	#
	# The deploy is the real one, taken to success, which deployable_prod
	# owns the recipe for.  The pipeline is off, because a pipeline-managed
	# deploy looks for a branch the harness does not stand up, and the
	# applied record goes with it, since a disabled pipeline that still
	# carries one is the state D64 has both hold commands refuse.
	plan tests => 7;

	my $h    = deployable_prod(pipeline => 0, applied => 0);
	run_genesis($h, 'prod', 'pipeline-hold', 'waiting on the capacity report');
	my $path = $h->env_path('prod').'/hold';

	my $w = snapshot_w($h);
	my (undef, $err, $exit) = run_genesis($h, {restore => 0},
		'prod', 'deploy', '-y');
	assert_w_restored($w, 'the deploy restored working state');
	is($exit, 0, 'the deploy succeeded')
		or diag($err);
	is(secret("$path:reason"), 'waiting on the capacity report',
		'the hold the deploy ran under is still standing afterwards');

	my (undef, undef, $released) = run_genesis($h, 'prod', 'pipeline-release');
	is($released, 0, 'the release succeeded');
	no_secret $path;
};

done_testing;
