#!/usr/bin/env perl
# Proves T132 and T127: a successful apply writes the pipeline's own facts to
# <exodus mount>_pipelines/<type> through Genesis::Top's own accessors, and the
# record's `at` is an EXODUS_TIME_FORMAT value rather than an ISO form.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

subtest 'the applied record lands under exodus _pipelines' => sub {
	# Six rows, and one more for the run's own restoration assertion, which
	# run_genesis makes unless a row turns it off.
	plan tests => 7;

	my $h = make_harness(envs => ['qa']);
	my ($control) = run({dir => $h->a}, 'git', 'rev-parse', $h->control);
	chomp $control;

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0');

	like(unfolded($out, $err),
		qr{recorded the applied pipeline at \S*_pipelines/bosh},
		'the stage says it recorded the pipeline, and names the address');

	is($h->applied_path, '/secret/exodus/_pipelines/bosh',
		'the harness and the code agree on the address');
	have_secret($h->applied_path . ':control_commit',
		'the record carries the control commit it applied from');

	is(secret($h->applied_path . ':control_commit'), $control,
		'the recorded commit is control as the apply read it');
	is(secret($h->applied_path . ':provider'), 'manual',
		'the record carries the configured provider');
};

subtest 'the record times itself in EXODUS_TIME_FORMAT' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	my (undef, undef, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0');

	my $at = secret($h->applied_path . ':at');
	like($at, qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [-+]\d{4}$/,
		'`at` is the value format and carries no ISO T or Z');
};

subtest 'a run told to skip the vault skips the record' => sub {
	# Four rows, and one more for the run's own restoration assertion.  The
	# harness has a vault standing, so a record that goes missing here is the
	# flag being honoured rather than a vault that could not be reached.
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '--skip-vault');
	my $said = unfolded($out, $err);

	is($exit, 0, 'the apply exits 0 rather than refusing the run');
	# The warning names the record in words rather than by its vault address,
	# because composing that address is itself a read the flag says we cannot
	# make.  The first subtest asserts the line the writing path prints, so
	# the two lines are told apart by their own wording.
	like($said, qr{Not writing the applied record},
		'the warning names the record it did not write');
	like($said, qr/--skip-vault/,
		'and the flag that stopped it from writing one');
	no_secret($h->applied_path, 'and no applied record was written');
};

subtest 'an apply whose clone has no control branch is refused' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);

	# The copy is stood off control before the branch goes, because git will
	# not delete the branch its HEAD names.  The remote keeps its own copy,
	# so what this builds is a clone that has fallen behind rather than a
	# repository where control never existed.
	run({dir => $h->a, onfailure => 'Failed to stand off control'},
		'git', 'checkout', '-q', '--detach');
	run({dir => $h->a, onfailure => 'Failed to remove the control branch'},
		'git', 'branch', '-q', '-D', $h->control);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = unfolded($out, $err);

	is($exit, Genesis::Exit::CONFIG,
		'the refusal exits Genesis::Exit::CONFIG');
	like($said, qr{The branch control is not in this clone},
		'the refusal names the branch it could not find');
	like($said, qr{No branch was created and no record was written},
		'and says that neither half of the apply wrote anything');
	no_secret($h->applied_path, 'and no applied record was written');
};

done_testing;
