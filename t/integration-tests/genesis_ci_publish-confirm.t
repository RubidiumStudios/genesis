#!/usr/bin/env perl
# Proves the half of T185 that does not depend on a terminal, which is that the
# showing is unconditional.  A run with no controlling terminal writes every
# environment's verified delta to the log and publishes, and a run given -y
# writes the same delta, because -y answers the ask and nothing else.
#
# No row here asks for a terminal.  The suite spawns its commands and a spawned
# command has no controlling terminal, so the three terminal behaviours are
# proved by calling the sub directly in t/unit-tests/genesis_ci_publish-confirm.t.
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

subtest 'without a terminal the delta is shown and the run publishes' => sub {
	# Six rather than five, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 6;

	my $h = make_harness(envs => ['lab', 'qa'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	ready_envs($h);

	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: twelve\n"},
		message => 'share an op with every environment',
		push    => 1,
	);

	my ($out, $err, $exit) = run_genesis($h, 'propagate');
	my $said = unfolded($out, $err);

	is($exit, 0, 'the run published');
	like($said, qr{lab/bosh: 1 commit,}, "lab's delta was shown");
	like($said, qr{qa/bosh: 1 commit,}, "qa's delta was shown");
	unlike($said, qr{Publish these branches\?},
		'and nothing was asked, because there was nobody to ask');

	# The showing is what this row is about, so the publish behind it is
	# read off the remote rather than off the run's own exit status.
	is(ref_in($h->r, 'refs/heads/lab/bosh'),
		ref_in($h->a, 'refs/heads/lab/bosh'), 'lab published');
};

subtest '-y is shown the same delta' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['lab', 'qa'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	ready_envs($h);

	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: thirteen\n"},
		message => 'share another op with every environment',
		push    => 1,
	);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);

	is($exit, 0, 'the run published');
	like($said, qr{lab/bosh: 1 commit,}, "lab's delta was shown anyway");
	like($said, qr{qa/bosh: 1 commit,}, "qa's delta was shown anyway");
	unlike($said, qr{Publish these branches\?}, 'and nothing was asked');
};

done_testing;
