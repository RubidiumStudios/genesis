#!/usr/bin/env perl
# Proves T349's status half, as rewritten on 2026-10-11, and D115's note of
# that day: genesis pipeline-status reads R once, brings T up to it for
# control and the deployment branches, and creates no branch; it leaves a
# pull request branch's T alone, since that is the tip the next publish
# leases against; where a live propagate holds the lock it leaves T alone
# and says so; and where R cannot be reached it fails naming the network.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# lab then qa, with qa moved on R by a teammate the clone has not seen.
sub moved_on_r {
	my $h  = ready_harness(
		envs    => ['lab', 'qa'],
		kit     => 'omega-v2.7.0',
		chained => 1,
	);
	hand_commit($h, $h->slug('qa'), copy => 'b', push => 1,
		message => 'qa moves on R');
	stand_on($h, $h->control);
	return $h;
}

sub heads_of {
	my ($h) = @_;
	my ($out) = run({dir => $h->a}, 'git', 'for-each-ref',
		'--format=%(refname) %(objectname)', 'refs/heads');
	return $out;
}

subtest 'a status brings T up to R and creates no branch' => sub {
	# Five rows, and the run's own restoration assertion.
	plan tests => 6;

	my $h   = moved_on_r();
	my $qa  = $h->slug('qa');
	my $lab = $h->slug('lab');
	my $pr  = $h->pr_branch('qa');
	delete_local($h, 'a', $lab);
	run({dir => $h->b, onfailure => 'Failed to publish a pull request branch'},
		'git', 'push', '-q', 'origin', "refs/heads/$qa:refs/heads/$pr");
	my $heads = heads_of($h);

	my (undef, $err, $exit) = run_genesis($h, 'pipeline-status');

	is($exit, 0, 'the status renders') or diag($err);
	is(ref_in($h->a, "refs/remotes/origin/$qa"), ref_in($h->r, "refs/heads/$qa"),
		'T holds what R holds for a deployment branch');
	is(heads_of($h), $heads, 'no local branch moved, and none was created');
	ok(!defined ref_in($h->a, "refs/remotes/origin/$pr"),
		"a pull request branch's T is left as it was");
	my ($left) = run({dir => $h->a}, 'git', 'for-each-ref', 'refs/genesis');
	is($left // '', '', 'and nothing is left under refs/genesis');
};

subtest 'a status reads R once' => sub {
	# One row, and the run's own restoration assertion.
	plan tests => 2;

	# The remote is severed from its second call onward, so a status that
	# read R a second time would meet it.
	my $h = moved_on_r();
	sever_remote($h, after => 2);
	my (undef, $err, $exit) = run_genesis($h, 'pipeline-status');
	restore_remote($h);

	is($exit, 0, 'one read of R is all it makes') or diag($err);
};

subtest 'a status leaves T alone while a propagate holds the lock' => sub {
	# Three rows, and the run's own restoration assertion.
	plan tests => 4;

	my $h  = moved_on_r();
	my $qa = $h->slug('qa');
	my $t  = ref_in($h->a, "refs/remotes/origin/$qa");

	my $holder = hold_session_lock($h);
	my (undef, $err, $exit) = run_genesis($h, 'pipeline-status');
	release_session_lock($h, $holder);
	my $said = unfolded($err);

	is($exit, 0, 'the status renders') or diag($err);
	is(ref_in($h->a, "refs/remotes/origin/$qa"), $t,
		'and leaves T where the running propagate left it');
	like($said, qr/genesis propagate.*\b$holder\b.*in progress|in progress.*\b$holder\b/,
		'naming the propagate in progress');
};

subtest 'a status that cannot reach R fails naming the network' => sub {
	# Two rows, and the run's own restoration assertion.
	plan tests => 3;

	my $h = moved_on_r();
	sever_remote($h);
	my (undef, $err, $exit) = run_genesis($h, 'pipeline-status');
	restore_remote($h);

	is($exit, Genesis::Exit::TEMPFAIL, 'it exits TEMPFAIL');
	like(unfolded($err), qr/Failed to reach/, 'naming the remote it could not reach');
};

done_testing;
