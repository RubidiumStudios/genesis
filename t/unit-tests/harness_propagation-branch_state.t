#!/usr/bin/env perl
# Proves the setup half of T2 and T4: the nine branch-state helpers each
# leave the shape the rows below read, which are a hand commit with no
# marker, a commit that never leaves copy A, a squash that keeps the
# marker in the body alone, an unrelated branch, a divergence in both
# directions, an advance on R, the two deletions, and the rewrite.
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

subtest 'a hand commit carries no marker and a local commit never leaves A' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	refresh($h, 'a', $h->control, $h->slug('qa'));

	my $hand = hand_commit($h, $h->slug('qa'),
		files => {'by-hand.yml' => "---\nfixed: true\n"},
		message => 'Fix the outage by hand');
	is(harness_marker($h, $h->slug('qa')), undef,
		'the hand commit leaves the branch with no marker');
	is(ref_in($h->r, 'refs/heads/' . $h->slug('qa')), $hand, 'and it is on R');

	refresh($h, 'a', $h->slug('qa'));
	my $local = local_only_commit($h, $h->slug('qa'), marker => 0,
		files => {'local.yml' => "---\nlocal: true\n"});
	is(ref_in($h->a, 'refs/heads/' . $h->slug('qa')), $local,
		"copy A's local ref moved");
	is(ref_in($h->r, 'refs/heads/' . $h->slug('qa')), $hand, 'and R did not');
};

subtest 'a squash keeps the marker in the body alone' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], mode => 'pr', vault => 0);
	init_branch($h, 'qa');
	my $control = $h->git('a')->sha($h->control);

	my $sha = squash_merge($h, 'qa',
		subject => 'Merge pull request #7 from pr/qa/bosh',
		control => $control);

	my ($subject) = run({dir => $h->r}, 'git', 'log', '-1', '--format=%s', $sha);
	chomp $subject;
	is($subject, 'Merge pull request #7 from pr/qa/bosh',
		"the tip's subject is the merger's");
	unlike($subject, qr/\[pipeline\]/, 'and it carries no marker');
	is(harness_marker($h, $h->slug('qa')), $control,
		'while the marker survives in the body');
};

subtest 'an unrelated branch shares no ancestor with R' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	refresh($h, 'a', $h->slug('qa'));
	my $sha = unrelated_branch($h, 'qa');

	isnt($sha, ref_in($h->r, 'refs/heads/' . $h->slug('qa')),
		'copy A and R hold different commits under one name');
	my $shared = run({dir => $h->a, passfail => 1}, 'git', 'merge-base',
		$sha, "origin/" . $h->slug('qa'));
	ok(!$shared, 'and the two share no ancestor at all');
};

subtest 'diverge, move_on_r, the deletions, and the rewrite' => sub {
	plan tests => 7;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	# The rewrite drops a commit from the middle of control, so control needs
	# a middle: the seed commit alone leaves nothing to take away.
	my $dropped = commit_on_control($h, files => {'ops/one.yml' => "---\none: 1\n"},
		message => 'the commit the rewrite drops', push => 1);
	commit_on_control($h, files => {'ops/two.yml' => "---\ntwo: 2\n"},
		message => 'the commit the rewrite keeps', push => 1);

	refresh($h, 'a', $h->slug('qa'));

	diverge($h, $h->slug('qa'), local => 2, remote => 1);
	my ($counts) = run({dir => $h->a}, 'git', 'rev-list',
		'--left-right', '--count',
		$h->slug('qa') . '...origin/' . $h->slug('qa'));
	chomp $counts;
	is($counts, "2\t1", 'L is two ahead and T is one ahead');

	my $moved = move_on_r($h, $h->slug('qa'));
	is(ref_in($h->r, 'refs/heads/' . $h->slug('qa')), $moved,
		'R moved under copy A');
	isnt(ref_in($h->a, 'refs/remotes/origin/' . $h->slug('qa')), $moved,
		"and copy A's remote-tracking ref has not caught up");

	my $unreachable = rewrite_control($h);
	is($unreachable, $dropped, 'the rewrite dropped the middle commit');
	my $gone = run({dir => $h->r, passfail => 1},
		'git', 'merge-base', '--is-ancestor', $unreachable, $h->control);
	ok(!$gone, 'the dropped control commit is unreachable on R');

	delete_local($h, 'a', $h->slug('qa'));
	is(ref_in($h->a, 'refs/heads/' . $h->slug('qa')), undef,
		"the branch is gone from copy A's local refs");

	delete_on_r($h, $h->slug('qa'));
	is(ref_in($h->r, 'refs/heads/' . $h->slug('qa')), undef, 'and gone from R');
};

subtest 'a fetch that names no branch is refused' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $control = ref_in($h->a, $h->control);

	ok(!eval {Harness::Propagation::_fetch_commit($h, 'b', $control); 1},
		'a call that names no branch is refused rather than guessing one');
	like($@, qr/needs the branch/, 'and the refusal says what is missing');
};

done_testing;
