#!/usr/bin/env perl
# Proves T128 and T318: pipeline-apply refuses a disabled pipeline and an
# absent pipeline block alike, naming the key, creating no branch, writing no
# record, and exiting Genesis::Exit::CONFIG.
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

subtest 'a disabled pipeline is refused' => sub {
	# Six rows, and one more for the run's own restoration assertion, which
	# run_genesis makes unless a row turns it off.  A refusal that leaves the
	# copy exactly as it found it is part of what "nothing was written" means,
	# so the row is kept rather than switched off to make the count round.
	plan tests => 7;

	my $h = make_harness(envs => ['qa'], pipeline => 0);
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = unfolded($out, $err);

	is($exit, Genesis::Exit::CONFIG, 'the refusal exits Genesis::Exit::CONFIG');
	like($said, qr/pipeline\.enabled/,
		'the refusal names the key it read');
	like($said, qr/applies a configured pipeline and never enables one/,
		'the refusal says why the command will not enable it');
	like($said, qr/Nothing was written/,
		'the refusal says nothing was written');

	is_deeply(branches_on_r($h), [$h->control],
		'R carries the control branch alone, so no branch was created');
	no_secret($h->applied_path, 'no applied record was written');
};

subtest 'an absent pipeline block is refused the same way' => sub {
	plan tests => 7;

	my $h = make_harness(envs => ['qa'], pipeline => 'none');
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = unfolded($out, $err);

	is($exit, Genesis::Exit::CONFIG, 'the refusal exits Genesis::Exit::CONFIG');
	like($said, qr/pipeline\.enabled/,
		'the refusal names the key even though no block declares it');
	like($said, qr/is false or absent/,
		'the refusal says the key is false or absent');
	like($said, qr/Nothing was written/,
		'the refusal says nothing was written');

	is_deeply(branches_on_r($h), [$h->control],
		'R carries the control branch alone');
	no_secret($h->applied_path, 'no applied record was written');
};

done_testing;
