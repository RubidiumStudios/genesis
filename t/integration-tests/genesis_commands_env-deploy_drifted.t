#!/usr/bin/env perl
# Proves T212, the drifted warning naming the file that differs and deploying
# anyway; and T211 and T213, the two hashes of the deployment record, which
# arrive green and guard against a step that restores the fallback to the
# control branch's head.
#
# Both trees are built with bosh => 1, which stands the director, the fake
# bosh, and the kit up before the seeding.  Each row asserts that the deploy
# proceeded, which needs the director, and each of them delivers a control
# commit, which needs the kit on control, because the kit source is a kind of
# the propagation set and reading that set at a commit carrying no kit refuses
# by name.
#
# Every run passes --no-propagate, for the reason the due-commits file gives:
# the auto-cascade hands off to a child genesis propagate that M15 owns and
# that fails today, and a row about what the deploy said should not be reading
# the child's failure as the deploy's.
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

subtest 'an ordinary deploy records a pair that is reachable on R' => sub {
	# Green on arrival, apart from the silence row.  It catches a step that
	# falls back to the control branch's head where a branch carries no
	# marker, which would record a certification that never happened.
	plan tests => 6;

	my $h      = ready_harness(envs => ['qa'], bosh => 1);
	my $tip    = tip_of($h, $h->slug('qa'));
	my $marker = harness_marker($h, $h->slug('qa'));

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');
	is($exit, 0, 'the deploy succeeded') or diag("what the deploy said:\n$err");

	my $record = newest_record($h, $h->env_path('qa').'/deployments');
	is($record->{git}{commit}, $tip, 'git.commit is the tip it stood on');
	is($record->{git}{control_commit}, $marker,
		"git.control_commit is what the branch's newest marker names");
	ok(reachable_on_r($h, $record->{git}{commit})
		&& reachable_on_r($h, $record->{git}{control_commit}),
		'and both are reachable on R');

	# The discriminator for the row below.  A warning that fired on every
	# deploy would name the hatch correctly and say nothing true, so the
	# branch that mirrors its snapshot has to go quietly.
	unlike(unfolded($err), qr/differs from the snapshot/,
		'and a branch that mirrors its snapshot draws no warning')
		or diag("what the deploy said:\n$err");
};

subtest 'a hand commit warns as drifted and deploys anyway' => sub {
	plan tests => 6;

	my $h       = ready_harness(envs => ['qa'], bosh => 1);
	my $marker  = harness_marker($h, $h->slug('qa'));
	# edited_file answers the one member of the set a row may safely edit,
	# which is the environment's own file, and the hatch keeps what that file
	# already said: an environment replaced wholesale is one no deploy can
	# read, and the row is about a deploy that goes ahead.
	my $drifted = edited_file($h, 'qa');
	my $was     = blob_at($h->a, $h->slug('qa'), $drifted);
	my $hand    = hand_commit($h, $h->slug('qa'),
		files   => {$drifted => $was."\n# opened by hand during the incident\n"},
		message => 'open the hatch');
	refresh($h, 'a', $h->control, $h->slug('qa'));

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the deploy went ahead') or diag("what the deploy said:\n$err");
	like(unfolded($err), qr/differs from/,
		'it warns that the branch differs from its snapshot')
		or diag("what the deploy said:\n$err");
	like(unfolded($err), qr{\Q$drifted\E}, 'naming the file that differs')
		or diag("what the deploy said:\n$err");

	my $record = newest_record($h, $h->env_path('qa').'/deployments');
	is($record->{git}{commit}, $hand, 'git.commit names the pushed hand commit');
	is($record->{git}{control_commit}, $marker,
		'and git.control_commit stays the control commit the marker names');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
