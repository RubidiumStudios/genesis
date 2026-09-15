#!/usr/bin/env perl
# Proves T92, T93, T94, T106, and T107: a marker-only local commit is reset
# to the tracking ref before the first write and reported as an event, a
# hand commit refuses the whole run by name, and no flag adopts the remote.
#
# Every phrase is matched across the wrap.  A refusal and an event line are
# both wrapped to the terminal width before they reach standard error, so a
# clause the reader sees on one line can arrive with a newline and an indent
# inside it.
#
# Genesis accounts for itself on standard error, which is where info writes,
# so the event line is read out of the second value rather than the first.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a marker-only local commit is reset and reported as an event' => sub {
	# Five rows, and one more for the run's own restoration assertion.
	plan tests => 6;

	my $h  = make_harness(envs => ['qa']);
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	# An ops file rather than a rewritten qa.yml.  The environment file is
	# where the pipeline metadata lives, so overwriting it empties the
	# topology and the run bails on that several steps before the reset
	# this row is about.
	my $control = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nfrom: the operator\n"},
		message => 'an operator commit to propagate',
		push    => 1);
	# No message, because the harness discards one whenever a marker is
	# asked for and the subject is the marker itself.
	my $stranded = local_only_commit($h, $qa, marker => $control);
	# The commit helper checks the branch out and leaves the copy there,
	# and the init tree carries no deployment root, so the copy stands back
	# on control before the command runs.
	stand_on($h, $h->control);

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	isnt($exit, Genesis::Exit::DATAERR, 'the run is not refused');
	like($err, qr{reset\s+\Q$qa\E\s+to\s+\S*origin/\Q$qa\E},
		'the reset is reported as an event line');
	unlike($err, qr{\Q$qa\E\s+reset\b},
		'and it is not reported as the environment outcome');
	isnt(ref_in($h->a, "refs/heads/$qa"), $stranded,
		'the stranded commit is gone from the branch');
	is($h->git('a')->resolve_branch($qa)->{behind}, 0,
		'and the branch is no longer behind what the walk then wrote');
};

subtest 'a hand commit refuses the whole run and writes nothing' => sub {
	# Nine rows, and one more for the run's own restoration assertion.
	plan tests => 10;

	my $h = make_harness(envs => ['qa', 'lab', 'prod', 'sandbox']);
	my $qa = $h->slug('qa');

	init_branch($h, $_) for qw/qa lab prod sandbox/;
	refresh($h, 'a', map { $h->slug($_) } qw/qa lab prod sandbox/);

	my %before = map { $_ => ref_in($h->a, "refs/heads/@{[$h->slug($_)]}") }
		qw/qa lab prod sandbox/;

	# An ops file, for the reason the first subtest gives.
	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nfrom: the operator\n"},
		message => 'an operator commit to propagate',
		push    => 1);
	my $hand = local_only_commit($h, $qa,
		marker => 0, message => 'patch the manifest by hand');
	stand_on($h, $h->control);

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR, 'the run exits DATAERR');
	like($err, qr/\Q$qa\E/, 'the refusal names the branch');
	like($err, qr/patch\s+the\s+manifest\s+by\s+hand/, 'and names the commit');
	like($err, qr/ahead\s+of\s+\S*origin\/\Q$qa\E\s+by\s+1\s+commit\s+and\s+behind\s+it\s+by\s+0\s+commits/,
		'and names both counts');
	like($err, qr/git\s+push\s+origin\s+\Q$qa\E/,
		'and gives the command to push it');
	like($err, qr{git\s+branch\s+-f\s+\Q$qa\E\s+origin/\Q$qa\E},
		'and the command to reset the branch');
	like($err, qr/Nothing\s+was\s+written/, 'and says nothing was written');

	is(ref_in($h->a, "refs/heads/$qa"), $hand, 'the hand commit is untouched');
	is_deeply(
		{map { $_ => ref_in($h->a, "refs/heads/@{[$h->slug($_)]}") } qw/lab prod sandbox/},
		{map { $_ => $before{$_} } qw/lab prod sandbox/},
		'and no other environment was written either');
};

subtest 'no option adopts the remote over a hand commit' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	#
	# The claim is read from the product rather than from the absence of
	# three flags nobody ever wrote: a run that drives three unbuilt
	# options is green before this task starts, and says nothing about
	# what the refusal offers.  So the refusal itself is driven, and the
	# row reads what it puts in front of the operator.
	plan tests => 4;

	my $h  = make_harness(envs => ['qa']);
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nfrom: the operator\n"},
		message => 'an operator commit to propagate',
		push    => 1);
	local_only_commit($h, $qa, marker => 0, message => 'a hand edit');
	stand_on($h, $h->control);

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR, 'the hand commit refuses the run');
	unlike($err, qr/--\w/,
		'and the refusal offers no flag that would do the operator\'s half');
	like($err, qr{git\s+push\s+origin\s+\Q$qa\E.*git\s+branch\s+-f\s+\Q$qa\E}s,
		'it offers the two commands the operator runs by hand instead');
};

subtest 'the straggler, reproduced' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	plan tests => 4;

	my $h  = make_harness(envs => ['qa']);
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	my $control = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nfrom: the operator\n"},
		message => 'an operator commit to propagate',
		push    => 1);

	# A run committed to the branch and died before its push, so the
	# commit is local only.  On the baseline the next run diffed against
	# it, found nothing to do, and never published it.
	my $stranded = local_only_commit($h, $qa, marker => $control);
	stand_on($h, $h->control);
	isnt(ref_in($h->r, $qa), $stranded, 'the remote never saw it');

	run_genesis($h, 'propagate');

	is(ref_in($h->a, "refs/heads/$qa"), ref_in($h->r, $qa),
		'the re-run reset the branch back onto what the remote holds');
	is($h->git('a')->resolve_branch($qa)->{state}, 'in-sync',
		'so the branch and the remote agree again');
};

subtest 'the divergence with no exit, reproduced' => sub {
	# Four rows, and one more for each of the two runs' restoration
	# assertions.
	plan tests => 6;

	my $h  = make_harness(envs => ['qa']);
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	my $control = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nfrom: the operator\n"},
		message => 'an operator commit to propagate',
		push    => 1);

	# A stale local commit meets a teammate's published one, which on the
	# baseline left the environment refused until somebody reset L by hand.
	diverge($h, $qa, local => 0, remote => 1);
	local_only_commit($h, $qa, marker => $control);
	stand_on($h, $h->control);
	is($h->git('a')->resolve_branch($qa)->{state}, 'diverged',
		'the branch really is diverged');

	run_genesis($h, 'propagate');
	is($h->git('a')->resolve_branch($qa)->{state}, 'in-sync',
		'a marker-only commit resets itself and the run carries on');

	my $h2  = make_harness(envs => ['qa']);
	my $qa2 = $h2->slug('qa');
	init_branch($h2, 'qa');
	refresh($h2, 'a', $qa2);
	commit_on_control($h2,
		files   => {'ops/shared.yml' => "---\nfrom: the operator\n"},
		message => 'an operator commit to propagate',
		push    => 1);
	diverge($h2, $qa2, local => 0, remote => 1);
	hand_commit($h2, $qa2, copy => 'a', push => 0, message => 'a hand edit');
	stand_on($h2, $h2->control);

	my (undef, $err, $exit) = run_genesis($h2, 'propagate');
	is($exit, Genesis::Exit::DATAERR, 'a hand commit refuses the run instead');
	like($err, qr/a\s+hand\s+edit/, 'naming the commit that has to be dealt with');
};

done_testing;
