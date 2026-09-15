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

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

subtest 'the applied record lands at the address D103 fixes' => sub {
	# Five rows, and one more for the run's own restoration assertion, which
	# run_genesis makes unless a row turns it off.
	plan tests => 6;

	my $h = make_harness(envs => ['qa']);
	my ($control) = run({dir => $h->a}, 'git', 'rev-parse', $h->control);
	chomp $control;

	my (undef, undef, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0');

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

done_testing;
