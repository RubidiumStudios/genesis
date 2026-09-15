#!/usr/bin/env perl
# Proves T77, the hand commit the walk skips; T79, the squash whose marker
# survives in the body alone; T84, the marker read from R and resolved
# against it; and T85, the same answer after a squash, after an amend, and
# under a coincidental short sha.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use_ok 'Genesis::CI::Marker';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the walk skips a hand commit and keeps the certified commit' => sub {
	plan tests => 3;

	my ($h, $control) = seeded();
	hand_commit($h, $h->slug('qa'),
		files   => {'qa.yml' => "---\nkit: dev\nhotfix: true\n"},
		message => 'raise the instance count for the incident',
	);
	refresh($h, 'a', $h->slug('qa'));

	my $git = $h->git('a');
	my $ref = 'origin/' . $h->slug('qa');

	is(Genesis::CI::Marker::newest($git, $ref), $control,
		'the reader skips the commit carrying no marker');
	is(harness_marker($h, $ref), $control,
		"and agrees with the harness's own read");

	my (undef, $depth) = Genesis::CI::Marker::newest($git, $ref);
	is($depth, 1, 'and counts the one hand commit standing above the marker');
};

subtest 'a squash keeps the marker in the body alone' => sub {
	plan tests => 2;

	# The delivery is written in copy A so the squash's parent is the commit
	# R holds and the push that follows it fast-forwards.  A squash written
	# onto a copy that never saw the delivery has no parent at all, and the
	# push is refused rather than replacing what the merge replaced.
	my ($h, $control) = seeded(copy => 'a');
	my $newer = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\nsecond: true\n"},
		message => 'change qa again',
		push    => 1,
	);
	squash_merge($h, 'qa',
		control => $newer,
		subject => 'Merge pull request #7 from pr/qa/bosh',
	);
	refresh($h, 'a', $h->slug('qa'));

	my $git = $h->git('a');
	my $ref = 'origin/' . $h->slug('qa');

	my ($subject) = run({dir => $h->a}, 'git', 'log', '-1', '--format=%s', $ref);
	chomp $subject;
	unlike($subject, qr/\Q[pipeline] control@\E/,
		'the tip subject is the merger\'s, with no marker in it');

	is(Genesis::CI::Marker::newest($git, $ref), $newer,
		'and the reader finds the marker in the body');
};

subtest 'a squash, an amend, and a coincidental sha give one answer' => sub {
	plan tests => 3;

	{
		my ($h, $control) = seeded(copy => 'a');
		squash_merge($h, 'qa', control => $control,
			subject => 'Merge pull request #11 from pr/qa/bosh');
		refresh($h, 'a', $h->slug('qa'));
		is(Genesis::CI::Marker::newest($h->git('a'), 'origin/' . $h->slug('qa')),
			$control, 'after a squash');
	}

	{
		my ($h, $control) = seeded();
		amend_tip($h, $h->slug('qa'), subject => 'tidy the delivered files');
		refresh($h, 'a', $h->slug('qa'));
		is(Genesis::CI::Marker::newest($h->git('a'), 'origin/' . $h->slug('qa')),
			$control, 'after an amend that pushed the old subject into the body');
	}

	{
		my ($h, $control) = seeded();
		hand_commit($h, $h->slug('qa'),
			files   => {'notes.txt' => "see a1b2c3d4e5f6 for the cause\n"},
			message => 'note that a1b2c3d4e5f6 broke the build',
		);
		refresh($h, 'a', $h->slug('qa'));
		is(Genesis::CI::Marker::newest($h->git('a'), 'origin/' . $h->slug('qa')),
			$control, 'and under a subject that names a short sha in passing');
	}
};

subtest 'the marker resolves against R and outruns a lagging L' => sub {
	plan tests => 4;

	# Copy A is both the copy the delivery is written in and the copy every
	# read below is taken from, so the branch the assertions walk is the
	# branch they wrote.
	my ($h, $control, $delivered) = seeded(copy => 'a');
	my $git = $h->git('a');

	assert_snapshot_invariant($h, 'qa',
		name => 'the delivery mirrors the control commit its marker names');

	# The walk is read into a scalar first, because the reader answers with
	# three values in list context and is_ancestor takes its arguments in
	# list context, which would read the markerless depth as the descendant.
	my $named = Genesis::CI::Marker::newest($git, $h->slug('qa'));
	ok($git->is_ancestor($named, $h->control),
		'the marker names a control commit the repository can reach');

	my $newer = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\nteammate: true\n"},
		message => 'change qa from the teammate',
		push    => 1,
	);
	# No refresh of copy B stands here.  Copy B was cloned before the
	# deployment branch existed and the delivery went in copy A, so copy B
	# has never held the branch, and publish_from_b is now the helper that
	# gives it one before it commits.
	publish_from_b($h,
		branch  => $h->slug('qa'),
		files   => {'qa.yml' => "---\nkit: dev\nteammate: true\n"},
		message => sprintf('[pipeline] control@%s -> qa', substr($newer, 0, 12)),
	);
	refresh($h, 'a', $h->slug('qa'), $h->control);

	is(Genesis::CI::Marker::newest($git, 'origin/' . $h->slug('qa')), $newer,
		"the read from R names the teammate's control commit");
	is(Genesis::CI::Marker::newest($git, $h->slug('qa')), $control,
		'while L still names the older one, which is the lag H18 describes');
};

subtest 'a marker a squash bulleted is still a marker' => sub {
	plan tests => 2;

	# A squash that collects more than one commit writes each subject as a
	# bulleted line, so the marker reaches the body with a bullet in front
	# of it and nothing else about it changed.  The bulleted marker names a
	# newer control commit than the delivery underneath it, so a reader that
	# walked past the bullet answers the older one rather than this one.
	my ($h, $control) = seeded(copy => 'a');
	my $newer = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\nsecond: true\n"},
		message => 'change qa again',
		push    => 1,
	);
	squash_merge($h, 'qa',
		keep_marker => 0,
		subject     => sprintf(
			"Merge pull request #9 from pr/qa/bosh\n\n* [pipeline] control@%s -> qa\n",
			substr($newer, 0, 12)),
	);
	refresh($h, 'a', $h->slug('qa'));

	is(Genesis::CI::Marker::newest($h->git('a'), 'origin/' . $h->slug('qa')),
		$newer, 'the reader takes the bullet off the front of the line');
	is(Genesis::CI::Marker::in_text("* [pipeline] control\@a1b2c3d -> qa\n"),
		'a1b2c3d', 'and so does the one regex');
};

subtest 'the newest marker wins whichever order the squash lists them' => sub {
	plan tests => 4;

	# The two tools disagree.  GitHub bullets each subject and lists the
	# newest commit last, and git's own squash indents each subject and
	# lists the newest first, so a reader that took the marker by position
	# would answer the older control commit for one of them.
	{
		my ($h, $control) = seeded(copy => 'a');
		my $newer = commit_on_control($h,
			files   => {'qa.yml' => "---\nkit: dev\nsecond: true\n"},
			message => 'change qa again',
			push    => 1,
		);
		squash_merge($h, 'qa',
			keep_marker => 0,
			subject     => sprintf(
				"Merge pull request #13 from pr/qa/bosh\n\n".
				"* [pipeline] control@%s -> qa\n\n* [pipeline] control@%s -> qa\n",
				substr($control, 0, 12), substr($newer, 0, 12)),
		);
		refresh($h, 'a', $h->slug('qa'));

		is(Genesis::CI::Marker::newest($h->git('a'), 'origin/' . $h->slug('qa')),
			$newer, 'where the merger listed the newest delivery last');
	}

	{
		my ($h, $control) = seeded(copy => 'a');
		my $newer = commit_on_control($h,
			files   => {'qa.yml' => "---\nkit: dev\nsecond: true\n"},
			message => 'change qa again',
			push    => 1,
		);
		squash_merge($h, 'qa',
			keep_marker => 0,
			subject     => sprintf(
				"Squashed commit of the following:\n\n".
				"    [pipeline] control@%s -> qa\n\n    [pipeline] control@%s -> qa\n",
				substr($newer, 0, 12), substr($control, 0, 12)),
		);
		refresh($h, 'a', $h->slug('qa'));

		is(Genesis::CI::Marker::newest($h->git('a'), 'origin/' . $h->slug('qa')),
			$newer, 'and where it listed the newest delivery first');
	}

	# A marker naming a commit this repository cannot reach is weighed
	# against nothing, so it has to be set aside before the comparison
	# starts.  Left in, it arrives first, holds the answer, and loses every
	# ancestry question that follows it, and the reachable marker below it
	# could never take the answer back.
	{
		my ($h, $control) = seeded(copy => 'a');
		my $newer = commit_on_control($h,
			files   => {'qa.yml' => "---\nkit: dev\nsecond: true\n"},
			message => 'change qa again',
			push    => 1,
		);
		squash_merge($h, 'qa',
			keep_marker => 0,
			subject     => sprintf(
				"Merge pull request #17 from pr/qa/bosh\n\n".
				"* [pipeline] control@%s -> qa\n\n* [pipeline] control@%s -> qa\n",
				'dead0beef123', substr($newer, 0, 12)),
		);
		refresh($h, 'a', $h->slug('qa'));

		my (undef, $reached) =
			Genesis::CI::Marker::_resolved($h->git('a'), 'dead0beef123');
		ok(!$reached,
			'the sha the first marker names is one this repository cannot reach');

		is(Genesis::CI::Marker::newest($h->git('a'), 'origin/' . $h->slug('qa')),
			$newer, 'and where an unreachable marker was listed ahead of it');
	}
};

subtest 'the cap on the walk means the number it was given' => sub {
	plan tests => 2;

	my ($h, $control) = seeded();
	hand_commit($h, $h->slug('qa'),
		message => 'raise the instance count for the incident');
	refresh($h, 'a', $h->slug('qa'));

	my $git = $h->git('a');
	my $ref = 'origin/' . $h->slug('qa');

	is(Genesis::CI::Marker::newest($git, $ref, limit => 1), undef,
		'a cap of one reads the hand commit alone and finds no marker');
	is(Genesis::CI::Marker::newest($git, $ref, limit => 0), undef,
		'and a cap of nothing reads nothing rather than everything');
};

subtest 'a branch with no marker anywhere answers nothing' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	refresh($h, 'a', $h->slug('qa'));

	my $git = $h->git('a');
	is(Genesis::CI::Marker::newest($git, 'origin/' . $h->slug('qa')), undef,
		'the reader returns nothing rather than a control tip');
	is(Genesis::CI::Marker::in_text("no marker here\n\nnor here\n"), undef,
		'and the one regex says nothing about text that carries no marker');
};

done_testing;
