#!/usr/bin/env perl
# Proves T303, that a delivered commit carrying `Genesis-Stage: hold: <reason>`
# makes the run write the hold record at delivery, so the deploy of that commit
# finds the hold already standing; and T304, that in a run where R rejects one
# environment's push the hold is written for the environment whose push landed
# and not for the one whose branch was reset to T.
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

subtest 'a delivered hold trailer writes the record' => sub {
	# Five rows, one of which is this row's own restoration assertion, and
	# one more for the deploy run, which asserts its restoration for itself.
	#
	# The third row is the one that discriminates.  Nothing before this task
	# writes a hold out of a trailer, so a run that delivered the gated
	# commit and wrote no record reads the reason back as the empty string.
	#
	# The last row is weaker than D53's claim, and it says so in its own
	# name.  A pipeline-enabled deploy cannot succeed against the harness
	# here, because the deploy looks its branch up by the environment's
	# basename where the harness names every branch by its slug, so the two
	# never meet.  The pipeline-enabled form of this row is re-armed once
	# that lookup reads the slug.  What the row can say until then is that
	# the record the delivery wrote survives the deploy command, rather
	# than that a deploy of the gated commit met it.
	plan tests => 6;

	my $h = held_prod_delivered();

	commit_on_control($h,
		files    => {'prod.yml' => env_body('prod', 1)},
		message  => 'raise the instance count',
		trailers => {'Genesis-Stage' => 'hold: run the capacity report'},
		push     => 1);

	my $w = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'propagate', '-y');
	assert_w_restored($w, 'the run restored working state');
	is($exit, 0, 'the run finished')
		or diag(unfolded($out, $err));

	my $path = $h->env_path('prod').'/hold';
	is(secret("$path:reason"), 'run the capacity report',
		'the trailer set the hold with its own reason');
	assert_snapshot_invariant($h, 'prod');

	fake_bosh();
	run_genesis($h, 'prod', 'deploy', '-y');
	is(secret("$path:reason"), 'run the capacity report',
		'the record the delivery wrote survives the deploy command');
};

subtest 'a rejected push takes no hold' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	#
	# The second and third rows are the pair that discriminates.  A writer
	# that walked every environment the run planned to deliver to, rather
	# than the ones the remote accepted, would hold prod as well, and a
	# writer that did nothing at all would hold neither.  The fourth counts
	# the sentences the report wrote, because both roots of this run carry
	# the same commit and a report naming the rejected environment as held
	# would say the sentence twice.
	plan tests => 5;

	my $h = held_prod_delivered(envs => ['lab', 'prod'],
		delivered => ['lab', 'prod'], certified => ['lab', 'prod']);

	commit_on_control($h,
		files    => {'lab.yml'  => env_body('lab', 1),
		             'prod.yml' => env_body('prod', 1)},
		message  => 'raise both instance counts',
		trailers => {'Genesis-Stage' => 'hold: run the capacity report'},
		push     => 1);

	# Copy B advances prod's branch on R between copy A's refresh and its
	# first push, which is how a row makes one of the run's pushes fail
	# without the run's own refresh absorbing the move first.
	move_on_r_at($h, $h->slug('prod'), at => 'push', nth => 1);

	my ($out, $err) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);
	like($said, qr/publish rejected, \Q${\($h->slug('prod'))}\E moved on R/,
		"prod's push was rejected");

	is(secret($h->env_path('lab').'/hold:reason'), 'run the capacity report',
		'the environment whose push landed took the hold');
	no_secret $h->env_path('prod').'/hold';

	my @sentences = $said =~ /a hold was set by the commit just delivered/g;
	is(scalar(@sentences), 1,
		'and the run says a hold was set once, for the one delivery that landed');
};

subtest 'a gate control has released takes no hold' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	#
	# The delivery row is what keeps the last row from passing for the wrong
	# reason, since a run that delivered nothing would write no hold either.
	# The last row is the one that discriminates.  A writer that reads the
	# trailer a second time, without the set of gates the control branch has
	# released, holds prod over a gate that control itself already took
	# back, and the operator has to clear by hand a hold nothing accounts
	# for.
	plan tests => 4;

	my $h = held_prod_delivered();

	my $gate = commit_on_control($h,
		files    => {'prod.yml' => env_body('prod', 1)},
		message  => 'raise the instance count',
		trailers => {'Genesis-Stage' => 'hold: run the capacity report'},
		push     => 1);

	# git's own revert body line is one of the two things released_gates
	# reads, and it names the full sha of the commit it takes back, so this
	# releases the gate with no deploy and no trailer of its own.
	my $revert = commit_on_control($h,
		files   => {'prod.yml' => env_body('prod', 2)},
		message => "Revert \"raise the instance count\"\n\n".
		           "This reverts commit $gate.",
		push    => 1);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run finished')
		or diag(unfolded($out, $err));
	is(harness_marker($h, $h->slug('prod')), $revert,
		'both commits were delivered, since the revert released the gate');
	no_secret $h->env_path('prod').'/hold';
};

subtest 'a gate without the hold form takes no hold' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	#
	# The hold form is the only one that sets a hold, and every other
	# subtest here uses it, so an implementation that wrote the reason for
	# any gate at all would pass this file without this subtest.  The guard
	# it makes explicit is the one genesis_ci_walk-gates.t keeps by
	# accident, where a second run has to deliver the commit behind the gate
	# and would instead find the environment wrongly held.
	plan tests => 4;

	my $h = held_prod_delivered();

	my $gate = commit_on_control($h,
		files    => {'prod.yml' => env_body('prod', 1)},
		message  => 'raise the instance count',
		trailers => {'Genesis-Stage' => 'run the capacity report'},
		push     => 1);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run finished')
		or diag(unfolded($out, $err));
	is(harness_marker($h, $h->slug('prod')), $gate,
		'the gated commit was delivered');
	no_secret $h->env_path('prod').'/hold';
};

done_testing;
