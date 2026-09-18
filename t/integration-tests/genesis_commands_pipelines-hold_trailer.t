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

subtest 'a delivered hold trailer writes the record' => sub {
	# Five rows, one of which is this row's own restoration assertion, and
	# one more for the deploy run, which asserts its restoration for itself.
	#
	# The third row is the one that discriminates.  Nothing before this task
	# writes a hold out of a trailer, so a run that delivered the gated
	# commit and wrote no record reads the reason back as the empty string.
	# The last row says the record the delivery wrote is still standing when
	# the deploy of that same commit runs, which is what D53 moves the write
	# forward for.
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
		'the deploy of the gated commit finds the hold already standing');
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

	my @said = $said =~ /a hold was set by the commit just delivered/g;
	is(scalar(@said), 1,
		'and the run says a hold was set once, for the one delivery that landed');
};

done_testing;
