#!/usr/bin/env perl
# Proves T349's status half, as rewritten on 2026-10-11, and D115's note of
# that day: genesis pipeline-status reads R once, brings T up to it for
# control and the deployment branches, and creates no branch; it leaves a
# pull request branch's T alone, since that is the tip the next publish
# leases against; where a live propagate holds the lock it leaves T alone
# and says so; and where R cannot be reached it fails naming the network.
# Also D112's one control for status: each environment loaded from control's
# tree with a run's full load, never from the working tree, and the walk
# routed from the commit the shape was read at, never an unpushed one.
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
use JSON::PP qw/decode_json/;

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

subtest 'a status loads each environment from control, not the working tree' => sub {
	# Two rows, and the run's own restoration assertion.
	plan tests => 3;

	# The operator stands on a feature branch whose qa.yml names a kit the
	# repository does not hold.  Control's qa.yml is sound, and control is
	# what status reports, so qa loads, with the same full load a run makes
	# (D112; D115, noted 2026-10-07).
	my $h = moved_on_r();
	run({dir => $h->a}, 'git', 'checkout', '-q', '-b', 'feature/broken', $h->control);
	put_file($h->a . '/qa.yml', join("\n",
		'---', 'kit:', '  name:    ghost', '  version: 9.9.9', '  features: []',
		'genesis:', '  env: qa', '  pipeline:', '    prior_env: lab', ''));
	run({dir => $h->a}, 'git', 'commit', '-qam', 'break qa on a feature branch');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');

	is($exit, 0, 'the status renders') or diag($err);
	ok(!env_row(decode_json($out), 'qa')->{error},
		"qa loads from control's file, not the feature branch's");
};

subtest 'a status walks the control R holds, not an unpushed one' => sub {
	# Two rows, and the run's own restoration assertion.
	plan tests => 3;

	# An unpublished change to control is not in effect (D112), so the walk
	# routes from the commit the shape was read at, and the unpushed commit is
	# pending for nobody.
	my $h = ready_harness(envs => ['lab', 'qa'], kit => 'omega-v2.7.0',
		chained => 1, tracked => ['ops/shared.yml']);
	stand_on($h, $h->control);
	my $unpushed = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: unpushed\n"},
		message => 'an unpushed change', push => 0);

	my ($out, $err) = run_genesis($h, 'pipeline-status', '--json');
	my $record  = decode_json($out);
	my @pending = map {@{$_->{pending} || []}} @{$record->{environments}};

	is($record->{control}{commit}, $record->{control}{shape_commit},
		'the walk routes from the commit the shape was read at') or diag($err);
	is(scalar(grep {($_->{control_commit} // '') eq $unpushed} @pending), 0,
		'and the unpushed commit is pending for no environment');
};

subtest 'a status reads a branch the clone lacks at T' => sub {
	# Four rows, and the run's own restoration assertion.
	plan tests => 5;

	# Status creates no branch, so a deployment branch R has and the clone
	# lacks is read where the status brought it, at T, and the record names
	# the clone's want of it in its divergence.  A guard: a later change
	# that read the branch from L would read nothing at all.
	my $h = ready_harness(envs => ['lab', 'qa'], kit => 'omega-v2.7.0',
		chained => 1, tracked => ['ops/shared.yml']);
	commit_on_control($h, files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'Bump shared ops', push => 1);
	stand_on($h, $h->control);
	my $lab = $h->slug('lab');
	delete_local($h, 'a', $lab);

	my ($out, $err) = run_genesis($h, 'pipeline-status', '--json');
	my $row = env_row(decode_json($out), 'lab');

	is($row->{reading}, 'deployed', 'lab reads as R has it') or diag($err);
	is(scalar @{$row->{pending} || []}, 1, 'with the commit due to it pending');
	is($row->{divergence}{state}, 'no-local', 'its want in the clone recorded');
	ok(!defined ref_in($h->a, "refs/heads/$lab"), 'and no local branch created');
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
