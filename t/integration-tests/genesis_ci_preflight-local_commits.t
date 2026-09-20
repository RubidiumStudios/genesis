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

	# The kit is here because the walk loads the environment before it
	# prints an outcome for it, and the row below reads that outcome column.
	my $h  = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
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

	isnt($exit, Genesis::Exit::DATAERR, 'this stage did not refuse the run');
	like($err, qr{reset\s+\Q$qa\E\s+to\s+\S*origin/\Q$qa\E},
		'the reset is reported as an event line');
	# The walk's outcome column is the environment's name, a colon, and a
	# verb, and the environment it names is qa rather than the branch.  The
	# row forbids a reset appearing there, which is a shape the walk really
	# could print, so it goes red if the reset were ever made an outcome.
	unlike($err, qr{^\s*qa:.*\breset\b}mi,
		'and it is not reported as the environment outcome');
	isnt(ref_in($h->a, "refs/heads/$qa"), $stranded,
		'the stranded commit is gone from the branch');
	is($h->git('a')->resolve_branch($qa)->{behind}, 0,
		'and the branch stands where the remote stands');
};

subtest 'a dry run reports the reset and moves nothing' => sub {
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
	my $stranded = local_only_commit($h, $qa, marker => $control);
	stand_on($h, $h->control);

	my (undef, $err) = run_genesis($h, 'propagate', '--dry-run');

	is(ref_in($h->a, "refs/heads/$qa"), $stranded,
		'the dry run left the branch where it stood');
	is($h->git('a')->resolve_branch($qa)->{state}, 'ahead',
		'so the stranded commit is still there and still unpublished');
	# The caveat says only that the reset is assumed.  The sentence naming
	# what would be discarded is the event line, which the caller prints
	# under either kind of run, so the caveat does not repeat it.  It is
	# said by the report under the preview's own banner rather than by this
	# stage, because an operator meets a caveat printed above that banner
	# before they have been told they are reading a preview.
	like($err, qr/This\s+preview\s+assumes\s+\Q$qa\E\s+is\s+reset\s+first/,
		'and the report says it assumes the reset a real run would make');
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

subtest 'a stray branch and a hand commit are named in one refusal' => sub {
	# Six rows, and one more for the run's own restoration assertion.
	plan tests => 7;

	my $h   = make_harness(envs => ['qa', 'lab']);
	my $qa  = $h->slug('qa');
	my $lab = $h->slug('lab');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	# lab/bosh is a branch the remote has never had, which is one class,
	# and qa/bosh carries a commit no marker accounts for, which is another.
	local_branch_only($h, 'lab');
	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nfrom: the operator\n"},
		message => 'an operator commit to propagate',
		push    => 1);
	local_only_commit($h, $qa,
		marker => 0, message => 'patch the manifest by hand');
	stand_on($h, $h->control);

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR, 'the run exits DATAERR');
	like($err, qr/has\s+no\s+counterpart\s+on\s+\S*origin/,
		'the stray branch is named');
	like($err, qr/\Qlab\E\s*\/\s*bosh/,
		'by name, allowing for a wrap at the slash');
	like($err, qr/patch\s+the\s+manifest\s+by\s+hand/,
		'and the hand commit is named too');

	# The row that discriminates.  Against a shape where each class raises
	# its own bail, the first one fires and the operator never hears about
	# the second, so one opening and one closing is what says they arrived
	# together.
	my @openings = $err =~ /(Refusing\s+to\s+run)/g;
	is(scalar @openings, 1, 'the run is refused once and not twice');
	my @closings = $err =~ /(Nothing\s+was\s+written)/g;
	is(scalar @closings, 1, 'and the closing sentence is said once');
};

subtest 'no option adopts the remote over a hand commit' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	#
	# The claim is read from the product rather than from the absence of
	# three flags nobody ever wrote.  A run that drives three unbuilt
	# options is green whatever the refusal says, and says nothing about
	# what it offers.  So the refusal itself is driven, and the row reads
	# what it puts in front of the operator.
	plan tests => 5;

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
	like($err, qr{git\s+push\s+origin\s+\Q$qa\E.*git\s+branch\s+-f\s+\Q$qa\E}s,
		'it offers the two commands the operator runs by hand instead');
	# Read out of the paragraph that offers the two commands rather than out
	# of the whole of standard error, so an unrelated line that happened to
	# carry a long option could not fail this row for the wrong reason.
	my ($offer) = $err =~ m{(is\s+ahead\s+of.*?if\s+it\s+is\s+not\.)}s;
	ok($offer, 'the refusal carries that paragraph');
	unlike($offer // '', qr/--\w/,
		'and it offers no flag that would do the operator\'s half');
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
		'a marker-only commit reset itself rather than refusing the run');

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
