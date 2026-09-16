#!/usr/bin/env perl
# Proves T148, T149, and T150: a gate travels with its predecessors and ends
# the delivery, certification at or past it releases it, and a revert or a
# Genesis-Release-Stage trailer releases it with no deploy.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the gate travels with its predecessors and ends the delivery' => sub {
	# One more than the rows for each run the subtest makes, because
	# run_genesis asserts the restoration of the working state in its own
	# words and those assertions are counted here.  Every subtest in this
	# file is counted the same way.
	plan tests => 5;

	my ($h, @shas) = gated_harness(stage => 'schema change', kit => 'omega-v2.7.0');

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	is(harness_marker($h, $h->slug('qa')), $shas[2],
		'the delivery ends at the gate itself');
	like($err, qr/\Q@{[substr($shas[3], 0, 7)]}\E.*gate: schema change/s,
		'the fourth commit is held with the gate\'s reason');

	# The qualifier is the environment's own held reading, which under D54 is
	# the run delivering nothing new to it, so it is read off a second run
	# that finds the gate already delivered and the commit behind it held.
	my (undef, $again) = run_genesis($h, {answers => ['y']}, 'propagate');
	like($again, qr/held, awaiting deployment \(qa at control\@[0-9a-f]+\)/,
		'the environment waits on its own certification of the gate');
};

subtest 'certification at the gate releases what waits behind it' => sub {
	plan tests => 4;

	my ($h, @shas) = gated_harness(stage => 'schema change', kit => 'omega-v2.7.0');
	run_genesis($h, {answers => ['y']}, 'propagate');

	certify($h, 'qa', control_commit => $shas[2]);
	my (undef, undef, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit, 0, 'the second run succeeded');
	is(harness_marker($h, $h->slug('qa')), $shas[3],
		'the fourth commit was delivered');
};

subtest 'a revert releases the gate with no deploy' => sub {
	plan tests => 4;

	my ($h, @shas) = gated_harness(stage => 'schema change', kit => 'omega-v2.7.0');
	run_genesis($h, {answers => ['y']}, 'propagate');

	my $revert = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit:\n  name:    dev\n  version: latest\n"
		           . "  features: []\ngenesis:\n  env: qa\nn: 5\n"},
		message => "Revert \"Change the credentials schema\"\n\n".
		           "This reverts commit $shas[2].",
		push    => 1);
	certify($h, 'lab', control_commit => $revert);

	run_genesis($h, {answers => ['y']}, 'propagate');
	is(harness_marker($h, $h->slug('qa')), $revert,
		'everything behind the gate was delivered');
	isnt(harness_marker($h, $h->slug('qa')), $shas[2],
		'the branch moved past the gate with no deploy');
};

subtest 'a release trailer naming a short hash releases the gate' => sub {
	plan tests => 3;

	my ($h, @shas) = gated_harness(stage => 'schema change', kit => 'omega-v2.7.0');
	run_genesis($h, {answers => ['y']}, 'propagate');

	my $release = commit_on_control($h,
		files    => {'qa.yml' => "---\nkit:\n  name:    dev\n  version: latest\n"
		           . "  features: []\ngenesis:\n  env: qa\nn: 6\n"},
		message  => 'Finish the schema migration',
		trailers => {'Genesis-Release-Stage' => substr($shas[2], 0, 7)},
		push     => 1);
	certify($h, 'lab', control_commit => $release);

	run_genesis($h, {answers => ['y']}, 'propagate');
	is(harness_marker($h, $h->slug('qa')), $release,
		'the release trailer let the held commits through');
};

done_testing;
