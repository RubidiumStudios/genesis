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

use Genesis::CI::PullRequest;

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

	# The qualifier is the environment's own held reading, which is the run
	# delivering nothing new to it, so it is read off a second run that finds
	# the gate already delivered and the commit behind it held.
	my (undef, $again) = run_genesis($h, {answers => ['y']}, 'propagate');
	like($again, qr/held, awaiting deployment \(qa at control\@[0-9a-f]+\)/,
		'the environment waits on its own certification of the gate');
};

subtest 'a gate stands until the environment certifies it' => sub {
	# Three: one row, and one restoration assertion for each of the two runs.
	plan tests => 3;

	# qa was delivered at the seeding commit and has certified nothing, so
	# the first run delivers up to the gate and leaves the branch's marker
	# standing on it.  A second run that read the gate over the range from
	# that marker would start at the gate itself and so find no gate at all,
	# and the commit the gate holds would go out on a run nobody deployed
	# anything between.
	my ($h, @shas) = gated_harness(stage => 'schema change',
		kit => 'omega-v2.7.0', certified => []);

	run_genesis($h, {answers => ['y']}, 'propagate');
	my (undef, $again) = run_genesis($h, {answers => ['y']}, 'propagate');

	like($again, qr/\Q@{[substr($shas[3], 0, 7)]}\E.*gate: schema change/s,
		'the fourth commit is still held on the second run');
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

	run_genesis($h, {answers => ['y']}, 'propagate');
	is(harness_marker($h, $h->slug('qa')), $revert,
		'everything behind the gate was delivered');
	isnt(harness_marker($h, $h->slug('qa')), $shas[2],
		'the branch moved past the gate with no deploy');
};

# A release only counts where it sits after the gate it names, and no row
# here proves the refusal, because the harness cannot cheaply build one.  A
# trailer has to carry the gate's own sha, a sha is derived from the commit
# it names, and a commit that stands in front of the gate cannot carry a sha
# that does not exist yet.  Rewriting control to swap the two afterwards
# rewrites both shas, so the trailer no longer names the gate at all.  What
# the guard really answers is a name that resolves to a commit off this
# range, and the reading it fixes is written into released_gates itself.
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

	run_genesis($h, {answers => ['y']}, 'propagate');
	is(harness_marker($h, $h->slug('qa')), $release,
		'the release trailer let the held commits through');
};

subtest 'a gate whose trailer carries no reason names no reason' => sub {
	# Three: two rows, and one restoration assertion for the run.
	plan tests => 3;

	# The hold form of the stage trailer is `hold: <reason>`, so a trailer
	# written with the prefix and nothing after it leaves no reason at all.
	# The commit still gates, because the trailer is there, and the line an
	# operator reads names the gate and stops rather than printing a colon
	# with nothing behind it.
	my ($h, @shas) = gated_harness(stage => 'hold:', kit => 'omega-v2.7.0');

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	like($err, qr/\Q@{[substr($shas[3], 0, 7)]}\E.*\bgate\b/s,
		'the commit behind it still reads as gated');
	unlike($err, qr/gate:\s*$/m,
		'and the reason is left off rather than printed empty');
};

# The other reader of the same answer is the pull request body, which says
# the gate in a sentence of its own, so it is asked here beside the report.
subtest 'the pull request line leaves an absent reason out too' => sub {
	plan tests => 2;

	my $line = Genesis::CI::PullRequest::gate_line({}, {});
	unlike($line, qr/:\s*\./,
		'a gate with no reason writes no empty sentence');
	like(Genesis::CI::PullRequest::gate_line(
			{gate_reason => 'rotate the signing key first'}, {}),
		qr/^Gate: rotate the signing key first\.$/,
		'while a gate that carries one still says it');
};

done_testing;
