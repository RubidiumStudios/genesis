#!/usr/bin/env perl
# Proves T182: a preview warns where its answer rests on something it did
# not do.  One run stands on a control branch nobody has pushed, and the
# preview says its result assumes that push.  The other stands on a
# deployment branch carrying a marker-only local commit, and the preview
# says its result assumes the reset that a real run makes before it walks.
# Both caveats are said under the preview's own banner, because an operator
# who meets one above it has not yet been told they are reading a preview.
# Neither run writes anything to L or to R.
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
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	# A kit the environment can actually be loaded against, because a run
	# whose environment will not load records a failure and exits partial,
	# and what this row is about is the status a preview leaves behind.
	my $h = ready_harness(envs => ['lab'], kit => 'omega-v2.7.0');
	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: eighteen\n"},
		message => 'an op nobody has pushed yet',
		push    => 0,
	);

	my $r_before = refs_in($h->r);
	# Both streams are read from the second value, because the run speaks
	# through info and everything Genesis says about itself goes to standard
	# error, so the banner and the caveat arrive in one stream in order.
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');

	like($err, qr/assumes.*pushed/i,
		'the preview says its result assumes the pending commit is pushed');
	ok(said_under_the_banner($err, 'is pushed'),
		'and says it under the banner, not above it');
	is($exit, 0, 'and it still runs, because a preview refuses nothing');
	is_deeply(refs_in($h->r), $r_before, 'R is untouched');
};

subtest 'a marker-only local commit warns that the result assumes the reset' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

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
	ok(said_under_the_banner($err, 'is reset first'),
		'and says it under the banner, not above it');
	is($exit, 0, 'and it still runs');
	is_deeply(refs_in($h->a), $l_before,
		'L is untouched, so the reset did not happen');
};

done_testing;
