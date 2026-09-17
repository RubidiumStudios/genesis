#!/usr/bin/env perl
# Proves T182: a preview warns where its answer rests on something it did
# not do.  One run stands on a control branch nobody has pushed, and the
# preview says its result assumes that push.  The other stands on a
# deployment branch carrying a marker-only local commit, and the preview
# says its result assumes the reset that a real run makes before it walks.
# Both caveats are said under the preview's own banner, because an operator
# who meets one above it has not yet been told they are reading a preview,
# and each names how many commits it is about.  Neither run writes anything
# to L or to R.  A control that is behind is refused as it is for a run that
# writes, because the one divergence a preview is let past is the one it can
# warn about.
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

# The banner and the caveats go to the same stream, so their order in it is
# the order the operator reads them in.  It reads what a run printed and
# builds nothing, so it stays beside the rows that use it.
sub said_under_the_banner {
	my ($report, $caveat) = @_;
	my $banner = index($report, 'This is a preview');
	my $said   = index($report, $caveat);
	return $banner >= 0 && $said > $banner;
}

subtest 'a control ahead of its remote warns that the result assumes a push' => sub {
	# Five rows, and one more for the run's own restoration assertion.
	plan tests => 6;

	# A kit the environment can actually be loaded against, because a run
	# whose environment will not load records a failure and exits partial,
	# and what this row is about is the status a preview leaves behind.
	my $h = ready_harness(envs => ['lab'], kit => 'omega-v2.7.0');
	# Two of them, because the number governs the noun and the verb and a
	# caveat that reads "the 1 commits ... are pushed" is read past rather
	# than read.
	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: eighteen\n"},
		message => 'an op nobody has pushed yet',
		push    => 0,
	);
	commit_on_control($h,
		files   => {'ops/second.yml' => "---\nops: nineteen\n"},
		message => 'a second op nobody has pushed yet',
		push    => 0,
	);

	my $r_before = refs_in($h->r);
	# Both streams are read from the second value, because the run speaks
	# through info and everything Genesis says about itself goes to standard
	# error, so the banner and the caveat arrive in one stream in order.
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');

	like($err, qr/assumes.*pushed/i,
		'the preview says its result assumes the pending commits are pushed');
	like($err, qr/the\s+2\s+commits\s+on\s+\Q@{[$h->control]}\E\s+are\s+pushed/,
		'and names how many there are, with the verb agreeing');
	ok(said_under_the_banner($err, 'are pushed'),
		'and says it under the banner, not above it');
	is($exit, 0, 'and it still runs, because a preview refuses nothing');
	is_deeply(refs_in($h->r), $r_before, 'R is untouched');
};

subtest 'a marker-only local commit warns that the result assumes the reset' => sub {
	# Six rows, and one more for the run's own restoration assertion.
	plan tests => 7;

	my $h = ready_harness(envs => ['lab'], kit => 'omega-v2.7.0');
	# A local commit carrying a marker, which is one the walk reproduces and
	# so one the pre-flight resets rather than refusing.  The commit leaves
	# copy A standing on the deployment branch, and the run reads its
	# environment files off the working tree, so the operator goes back on
	# control before the command is spawned.
	my $control = $h->git('a')->sha($h->control);
	local_only_commit($h, $h->slug('lab'), marker => $control);
	stand_on($h, $h->control);

	my $l_before = refs_in($h->a);
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');

	like($err, qr/assumes.*reset/i,
		'the preview says its result assumes the reset');
	# Matched inside the caveat's own sentence rather than loose in the
	# output, because the stage's event line names the same count above the
	# banner and a loose pattern would find that one and pass regardless.
	like($err, qr/resets\s+it\s+to\s+\Qorigin\E\/\Q@{[$h->slug('lab')]}\E\s+before\s+it\s+walks,\s+discarding\s+1\s+commit\b/,
		'and names how many the reset would discard');
	ok(said_under_the_banner($err, 'is reset first'),
		'and says it under the banner, not above it');
	# The pre-flight said this above the banner before the caveat existed,
	# and an implementation that added the caveat and left that sentence
	# standing would say it twice, once too early.
	unlike($err, qr/This report assumes the reset/,
		'and the stage no longer says it above the banner');
	is($exit, 0, 'and it still runs');
	is_deeply(refs_in($h->a), $l_before,
		'L is untouched, so the reset did not happen');
};

subtest 'a control that is behind is refused, preview or not' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h = ready_harness(envs => ['lab'], kit => 'omega-v2.7.0');
	my $before = ref_in($h->a, "refs/heads/@{[$h->control]}");
	publish_from_b($h,
		files   => {'ops/shared.yml' => "---\nfrom: the teammate\n"},
		message => 'a teammate publishes onto control');

	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');

	# The one divergence a preview is let past is the one it can warn
	# about.  A stale control makes the topology the preview reports on the
	# wrong one, so there is nothing true to say about it and the run
	# refuses instead.  Widen the guard past ahead and these three go red.
	is($exit, Genesis::Exit::DATAERR, 'the preview is refused too');
	like($err, qr/\bbehind\b/, 'the refusal names the state');
	unlike($err, qr/This is a preview/,
		'and no report was printed, because the run stopped before it');
	is(ref_in($h->a, "refs/heads/@{[$h->control]}"), $before,
		'control was not moved in either direction');
};

done_testing;
