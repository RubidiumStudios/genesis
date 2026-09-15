#!/usr/bin/env perl
# Proves T86, T87, and T109: a branch that is behind is fast-forwarded
# before the walk, the diff base stays the local ref, and a teammate's
# published delivery is no longer invisible to it.
#
# Every phrase is matched across the wrap.  An event line is wrapped to the
# terminal width before it reaches standard error, so a clause the reader
# sees on one line can arrive with a newline and an indent inside it.
#
# Genesis accounts for itself on standard error, which is where info writes,
# so every line the run reports is read out of the second value rather than
# the first.
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
use Genesis::Top;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a branch that is behind is fast-forwarded before the walk' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h  = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	# An ops file rather than a rewritten qa.yml.  The environment file is
	# where the pipeline metadata lives, so overwriting it empties the
	# topology and the run bails on that several steps before the
	# fast-forward this row is about.
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nfrom: control\n"}, push => 1);
	my $theirs = deliver($h, 'qa', control => $control, copy => 'b');
	refresh($h, 'a', $qa);

	is($h->git('a')->resolve_branch($qa)->{state}, 'behind',
		'copy A starts the run behind the remote');

	my (undef, $err) = run_genesis($h, 'propagate');

	is($h->git('a')->resolve_branch($qa)->{state}, 'in-sync',
		'the pre-flight moved it up to the tracking ref');
	like($err, qr{fast-forwarded\s+\Q$qa\E}, 'and reported the move');
	ok((grep { $_ eq $theirs } commits_on($h->a, "refs/heads/$qa")),
		"the teammate's commit is on the branch, not diffed around");
};

subtest 'the fast-forward discards no commit anywhere' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	plan tests => 4;

	my $h  = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nfrom: control\n"}, push => 1);
	my $theirs  = deliver($h, 'qa', control => $control, copy => 'b');
	my @on_r    = commits_on($h->r, $qa);

	run_genesis($h, 'propagate');

	is(ref_in($h->a, "refs/heads/$qa"), ref_in($h->a, "refs/remotes/origin/$qa"),
		'the local ref and the tracking ref agree afterwards');
	ok((grep { $_ eq $theirs } commits_on($h->a, "refs/heads/$qa")),
		"the teammate's delivery survived the run");
	is_deeply([grep { my $c = $_; grep { $_ eq $c } commits_on($h->r, $qa) } @on_r],
		[@on_r], 'and every commit that was on the remote is still there');
};

subtest 'a teammate delivery already on the branch is not delivered twice' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h  = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nfrom: control\n"}, push => 1);

	# The teammate has already delivered this very control commit, which on
	# the baseline the diff could not see, because it compared the local
	# ref to the source and the local ref had not moved.
	my $theirs = deliver($h, 'qa', control => $control, copy => 'b');
	my @before = commits_on($h->r, $qa);

	my (undef, $err) = run_genesis($h, 'propagate');

	# The walk is where the diff is taken, so a run that reaches its banner
	# is a run whose diff base is the branch the pre-flight settled.  The
	# guard between the two stages reads the deployment slug now, so a typed
	# repository no longer stops at it.
	like($err, qr{Propagating from}, 'the run reaches the walk');
	is(ref_in($h->a, "refs/heads/$qa"), $theirs,
		'the branch ends at the delivery the teammate published');
	is_deeply([commits_on($h->r, $qa)], \@before,
		'and nothing new was written for that environment');
	unlike($err, qr{\Q$qa\E.*propagated}, 'the run reports no delivery for it');
};

subtest 'an environment with no branch is reported as awaiting the apply' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	plan tests => 4;

	# The kit is here because the walk loads each environment before it
	# diffs, and an environment whose kit cannot be resolved never reaches
	# the report this row reads.
	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0', embed => 1);

	# No branch for qa on either side, which is the one state the pre-flight
	# records nothing for.  The run is a dry run because the creation guard
	# between the two stages writes nothing under one, so the walk is
	# reached with the environment still unsettled, which is the case D43
	# calls awaiting pipeline-apply.
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--dry-run', '-y');

	isnt($exit, Genesis::Top->PROPAGATE_NO_BRANCH_EXIT,
		'the run is not stopped by the creation guard');
	like($err, qr{Propagating from}, 'and it reaches the walk');
	like($err, qr{\bqa\b:\s+awaiting\s+\S*genesis\s+pipeline-apply},
		'where the environment with no branch is reported as awaiting it');
};

done_testing;
