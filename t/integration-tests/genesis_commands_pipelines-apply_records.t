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

# _unfolded - what the run said, put back on one line
#
# A warning is folded to the terminal's width on its way out, so a phrase a
# row is looking for arrives with a newline and an indent somewhere in the
# middle of it.  The two streams are joined on a newline, so that no phrase
# can match across the seam where one ends and the other begins, and their
# whitespace is collapsed before anything is matched.
sub _unfolded {
	my $said = join("\n", map {$_ // ''} @_);
	$said =~ s/\s+/ /g;
	return $said;
}

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

subtest 'a run told to skip the vault skips the record' => sub {
	# Four rows, and one more for the run's own restoration assertion.  The
	# harness has a vault standing, so a record that goes missing here is the
	# flag being honoured rather than a vault that could not be reached.
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '--skip-vault');
	my $said = _unfolded($out, $err);

	is($exit, 0, 'the apply exits 0 rather than refusing the run');
	# The phrase and the address are matched together, because the stage says
	# the same address when it does write the record and a row reading for
	# the address alone would pass on that line instead.
	like($said, qr{Not writing the applied record at \S*_pipelines/bosh},
		'the warning names the record it did not write');
	like($said, qr/--skip-vault/,
		'and the flag that stopped it from writing one');
	no_secret($h->applied_path, 'and no applied record was written');
};

done_testing;
