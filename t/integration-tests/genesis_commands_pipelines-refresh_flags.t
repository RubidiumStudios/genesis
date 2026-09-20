#!/usr/bin/env perl
# Proves T88, T95, T96, T104, and T317: the refresh is unconditional, the
# one surviving flag is --no-refresh on pipeline-status, the old spellings
# are usage errors, and a remote we cannot reach fails at pre-flight.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit qw/TEMPFAIL/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the old spellings are usage errors with no alias' => sub {
	# Seven rows, and one more for each run's own restoration assertion.
	#
	# --no-pull is in the list because Getopt spells the negation of a `pull!`
	# option that way, so retiring the option retires both halves and both
	# halves are worth reading from the product.
	#
	# The last of the seven drives a flag nobody has written yet.  It is here
	# so that --reconcile cannot arrive quietly.  The day it does this row
	# goes red and whoever added it has to say so.
	plan tests => 14;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	for my $argv (['pipeline-status', '--no-fetch'],
	              ['propagate', '--no-fetch'],
	              ['pipeline-apply', '--no-fetch'],
	              ['new', 'staging', '--no-fetch'],
	              ['qa', 'deploy', '--pull'],
	              ['qa', 'deploy', '--no-pull'],
	              ['qa', 'deploy', '--reconcile']) {
		my (undef, undef, $exit) = run_genesis($h, @$argv);
		is($exit, 2, "@$argv is a usage error");
	}
};

subtest 'only pipeline-status takes the flag that survived' => sub {
	# Five rows, and one more for each run's own restoration assertion.
	plan tests => 10;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	my (undef, undef, $status_exit) = run_genesis($h, 'pipeline-status', '--no-refresh');
	is($status_exit, 0, 'pipeline-status accepts --no-refresh');

	for my $argv (['propagate', '--no-refresh'],
	              ['qa', 'deploy', '--no-refresh'],
	              ['pipeline-apply', '--no-refresh'],
	              ['new', 'staging', '--no-refresh']) {
		my (undef, undef, $exit) = run_genesis($h, @$argv);
		is($exit, 2, "@$argv is a usage error");
	}
};

subtest 'pipeline-status under the flag reads and writes nothing' => sub {
	# The run takes restore => 0 so the restoration is asserted below in
	# this row's own words, which is the fifth of the five.
	plan tests => 5;

	my $h    = make_harness(envs => ['qa']);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	my $before_l = ref_in($h->a, "refs/heads/$slug");
	my $before_t = ref_in($h->a, "refs/remotes/origin/$slug");
	my $before_r = ref_in($h->r, $slug);
	my $w        = snapshot_w($h);

	# A severed remote proves the command made no network call, because a
	# refresh would have failed on it.
	sever_remote($h);
	my (undef, undef, $exit) = run_genesis($h, {restore => 0},
		'pipeline-status', '--no-refresh');
	restore_remote($h);

	is($exit, 0, 'the stale report comes back without touching the network');
	is(ref_in($h->a, "refs/heads/$slug"), $before_l, 'L did not move');
	is(ref_in($h->a, "refs/remotes/origin/$slug"), $before_t, 'T did not move');
	assert_w_restored($w, 'pipeline-status --no-refresh leaves W alone');
	is(ref_in($h->r, $slug), $before_r, 'R did not move');
};

subtest 'a run that cannot reach the remote fails at pre-flight' => sub {
	# Five rows, and one more for the run's own restoration assertion.
	plan tests => 6;

	my $h    = make_harness(envs => ['qa', 'prod']);
	my $slug = $h->slug('qa');
	init_branch($h, $_) for qw/qa prod/;
	refresh($h, 'a', $slug);

	my $before_l = ref_in($h->a, "refs/heads/$slug");
	commit_on_control($h, files => {'ops/shared.yml' => "---\nfrom: the operator\n"},
		message => 'the operator has something to propagate', push => 1);

	sever_remote($h);
	my (undef, $err, $exit) = run_genesis($h, 'propagate');
	restore_remote($h);

	is($exit, TEMPFAIL, 'the run exits TEMPFAIL');
	# The refusal is wrapped to the terminal width on its way to stderr, so
	# every phrase below is matched across whatever whitespace the wrap put
	# inside it rather than against one unbroken line.
	like($err, qr/Failed\s+to\s+reach/, 'the refusal names the reach as the failure');
	like($err, qr/origin/, 'and it names the remote it could not reach');
	like($err, qr/Nothing\s+was\s+written/, 'and it says nothing was written');
	is(ref_in($h->a, "refs/heads/$slug"), $before_l, 'no branch was written');
};

subtest 'the deploy meets the same refusal' => sub {
	# The run takes restore => 0 so the restoration is asserted below in
	# this row's own words, which is the fourth of the four.
	plan tests => 4;

	my $h    = make_harness(envs => ['qa']);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	my $w = snapshot_w($h);

	sever_remote($h);
	my (undef, $err, $exit) = run_genesis($h, {restore => 0}, 'qa', 'deploy');
	restore_remote($h);

	is($exit, TEMPFAIL, 'the deploy exits TEMPFAIL too');
	like($err, qr/Failed\s+to\s+reach/, 'naming the reach as the failure');
	like($err, qr/Nothing\s+was\s+deployed/, 'and saying nothing was deployed');
	assert_w_restored($w, 'the refused deploy leaves W alone');
};

done_testing;
