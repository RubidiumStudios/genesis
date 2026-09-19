#!/usr/bin/env perl
# What withholds the propagate child, and what catches up afterwards.
# Proves T252 and T256 of the test matrix.
#
# The flag is D35's, and it withholds the child and nothing else.  The gate
# the hand-off is spawned behind already refuses on it, so nothing here makes
# a row go red against the tree as it stands.  What these rows catch is a
# later change that drops the clause, whether by removing it or by reordering
# the gate so that something answers before it.  Such a change would leave the
# first subtest looking at a child it should never have seen, with R moved
# beneath it, and it would leave the hand run in the second subtest with
# nothing left to carry.
#
# The two halves sit in one file because neither can be asserted without the
# other.  The flag is only half an answer, and the other half is D37's hand
# run, which has to reach the same branches and the same markers the child
# would have produced.  A run that spawned the child anyway would leave that
# hand run nothing to deliver, and a hand run that delivered nothing would say
# nothing about whether the flag had withheld anything.
#
# The fixture is the chained shape rather than the step file's bare
# make_harness, for the reason Task 14.6 recorded against the same rows.  A
# harness that stands up no director, no bosh, and no kit deploys nothing, and
# a deploy that never succeeds hands off to no child at all, so every row here
# would read a silence it had built itself.  ready_harness with bosh names qa
# as prod's predecessor through chained, delivers and certifies both of them,
# and commits the kit on control before the seeding.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

use Genesis;

plan tests => 2;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# One control commit that both environments are due, delivered to qa alone, so
# that the deploy under test certifies it and there is exactly one commit for
# prod to be given.  The bodies come from the harness's own writer rather than
# being spelled out here, since an environment file the walk reads a topology
# out of is the harness's to shape.
sub due_on_control {
	my ($h) = @_;
	write_env_file($h, 'qa', params => {n => 2}, commit => 0);
	write_env_file($h, 'prod', genesis => {pipeline => {prior_env => 'qa'}},
		params => {n => 2}, commit => 0);
	run({dir => $h->a}, 'git', 'add', '--', 'qa.yml', 'prod.yml');
	run({dir => $h->a, onfailure => 'Failed to commit the due change'},
		'git', 'commit', '-q', '-m', 'A change both environments are due');
	push_from($h, 'a', $h->control);

	my $control = $h->git('a')->sha($h->control);
	deliver($h, 'qa', control => $control);
	refresh($h, 'a', $h->control, $h->slug('qa'), $h->slug('prod'));
	return $control;
}

subtest '--no-propagate deploys and spawns nothing' => sub {
	plan tests => 5;

	my $h = ready_harness(envs => ['qa', 'prod'], chained => 1, bosh => 1);
	due_on_control($h);
	my $before = $h->git('a')->sha('refs/remotes/origin/'.$h->slug('prod'));

	child_recorder($h);
	stand_on($h, $h->control);
	my $w = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '-y', '--no-propagate');

	is($exit, 0, 'the deploy command succeeded')
		or diag("what the deploy said:\n$err");
	is_deeply([child_runs($h)], [], 'no child was spawned');
	like($out.$err, qr/deployed successfully/,
		'the deploy reported itself done');

	refresh($h, 'a', $h->slug('prod'));
	is($h->git('a')->sha('refs/remotes/origin/'.$h->slug('prod')), $before,
		'nothing on R moved');
	assert_w_restored($w,
		'the operator is back on the branch they started from');
};

subtest 'the hand run delivers what the child would have' => sub {
	plan tests => 9;

	my $h = ready_harness(envs => ['qa', 'prod'], chained => 1, bosh => 1);
	my $control = due_on_control($h);

	child_recorder($h);
	stand_on($h, $h->control);
	# This run spawns nothing, so the runner takes its own snapshot and
	# makes the one restoration assertion for it.
	my (undef, $said, $exit) = run_genesis($h, 'qa', 'deploy', '-y',
		'--no-propagate');
	is($exit, 0, 'the deploy command succeeded')
		or diag("what the deploy said:\n$said");

	my ($out, $err, $run) = run_genesis($h, {restore => 0}, 'propagate', '-y');
	is($run, 0, 'the hand run succeeded')
		or diag("what the hand run said:\n$err");
	like($out.$err, qr/\bprod\b.*\bpropagated\b/,
		'the hand run delivered to prod');

	refresh($h, 'a', $h->slug('prod'));
	is(harness_marker($h, 'origin/'.$h->slug('prod')), $control,
		'prod carries the marker naming the certified commit');
	assert_snapshot_invariant($h, 'prod',
		name => 'prod mirrors control over its propagation set');

	my ($again, $again_err, $second) = run_genesis($h, {restore => 0},
		'propagate', '-y');
	is($second, 0, 'the second hand run succeeded')
		or diag("what the second hand run said:\n$again_err");
	like($again.$again_err, qr/\bprod\b.*\bidempotent\b/,
		'the second run found nothing left to do');
	unlike($again.$again_err, qr/\bpropagated\b/,
		'the second run delivered nothing, so the run is level triggered');
};

# vim: ts=2 sw=2 sts=2 noet
