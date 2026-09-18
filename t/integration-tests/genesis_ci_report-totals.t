#!/usr/bin/env perl
# A run whose one branch the remote refused published nothing, so the totals
# line counts none of its commits and says nothing about changes to
# propagate, while the same run with nothing in its way counts the one commit
# it published.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

subtest 'a refused branch contributes none of its commits' => sub {
	# Three assertions and one restoration.
	plan tests => 4;

	my ($h) = due_harness(envs => ['lab'], count => 1, kit => 'omega-v2.7.0');
	move_on_r_at($h, 'lab/bosh', at => 'push', nth => 1);

	my ($out, $err) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);

	like($said, qr/publish rejected/, 'the environment records the rejection');
	unlike($said, qr/Delivered 1 commit/,
		'the totals line counts no commit the remote refused');
	unlike($said, qr/No changes to propagate/,
		'and it does not read as a quiet run either');
};

subtest 'a run that published its commit counts it' => sub {
	# One assertion and one restoration.
	plan tests => 2;

	my ($h) = due_harness(envs => ['lab'], count => 1, kit => 'omega-v2.7.0');

	my ($out, $err) = run_genesis($h, 'propagate', '-y');
	like(unfolded($out, $err), qr/Delivered 1 commit/,
		'the one published commit is the one the totals line counts');
};

done_testing;
