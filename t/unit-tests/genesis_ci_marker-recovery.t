#!/usr/bin/env perl
# Proves T81's reader half: where the site could not grant the rebase-only
# merge method and a squash merge took the marker with it, the reader takes
# it from the pull request's body and says where it came from.  The event
# line a run prints over that recovery belongs to the propagate command
# rather than to this reader.
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

subtest 'a squash that lost the marker recovers from the pull request' => sub {
	plan tests => 6;

	my $h  = make_harness(envs => ['qa'], vault => 0);
	my $gh = github_double($h);
	init_branch($h, 'qa');

	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	my $marker = sprintf('[pipeline] control@%s -> qa', substr($control, 0, 12));

	my $number = gh_pull_request($gh,
		env   => 'qa',
		head  => $h->pr_branch('qa'),
		base  => $h->slug('qa'),
		title => $marker,
		body  => join("\n",
			'Carries one control commit.',
			'',
			$marker,
		),
	);

	# The body the recovery reads is the body the double holds, rather than
	# the string this row composed, because a scene nobody reads back proves
	# nothing about the recovery.  gh_merge_pr hands the double's whole state
	# over as it merges, and the pull request is in it.
	my $state = gh_merge_pr($gh, $number, method => 'squash');
	my ($pr)  = grep {$_->{number} == $number} @{$state->{prs}};
	my $body  = $pr->{body};

	squash_merge($h, 'qa',
		control     => $control,
		subject     => sprintf('Merge pull request #%s from %s',
			$number, $h->pr_branch('qa')),
		keep_marker => 0,
	);
	refresh($h, 'a', $h->slug('qa'));

	my $git = $h->git('a');
	my $ref = 'origin/' . $h->slug('qa');

	is(harness_marker($h, $ref), undef,
		'the squash left no marker in the subject or the body');
	is(Genesis::CI::Marker::newest($git, $ref), undef,
		'so the branch walk alone answers nothing');

	is(Genesis::CI::Marker::newest($git, $ref, recover_from => $body), $control,
		"the reader takes the marker from the pull request's body");

	my (undef, undef, $source) =
		Genesis::CI::Marker::newest($git, $ref, recover_from => $body);
	is($source, 'pull-request',
		'and says where it came from, so the run can report the recovery');

	my ($none, undef, $plain) = Genesis::CI::Marker::newest($git, $ref,
		recover_from => 'no marker in this body either');
	is($none, undef, 'while a body carrying no marker recovers nothing');
	is($plain, undef, 'and says it came from nowhere rather than from a body');
};

subtest 'the branch still wins where it carries a marker' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	# The delivery is written in copy A, because copy A is the copy every
	# read below is taken from.
	deliver($h, 'qa', control => $control, copy => 'a');
	refresh($h, 'a', $h->slug('qa'));

	my $git = $h->git('a');
	my $ref = 'origin/' . $h->slug('qa');

	my ($sha, undef, $source) = Genesis::CI::Marker::newest($git, $ref,
		recover_from => '[pipeline] control@0000000 -> qa');
	is($sha, $control, 'the branch answers and the body is never consulted');
	is($source, 'branch', 'and the source says so');
};

subtest 'a body carrying two markers answers the newer' => sub {
	plan tests => 2;

	# A pull request that collected two deliveries carries both markers in
	# its body, for the reason a squashed commit message carries both, and
	# GitHub lists the newest commit last.  The recovery weighs them by
	# ancestry exactly as the branch walk weighs them, so the order the body
	# happens to list them in decides nothing.
	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	my $newer = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\nsecond: true\n"},
		message => 'change qa again',
		push    => 1,
	);
	squash_merge($h, 'qa',
		control     => $newer,
		subject     => 'Merge pull request #3 from ' . $h->pr_branch('qa'),
		keep_marker => 0,
	);
	refresh($h, 'a', $h->slug('qa'));

	my $body = sprintf(
		"Carries two control commits.\n\n".
		"* [pipeline] control\@%s -> qa\n\n* [pipeline] control\@%s -> qa\n",
		substr($control, 0, 12), substr($newer, 0, 12));

	my ($sha, undef, $source) = Genesis::CI::Marker::newest($h->git('a'),
		'origin/' . $h->slug('qa'), recover_from => $body);
	is($sha, $newer, "the recovery weighs the body's markers by ancestry");
	is($source, 'pull-request', 'and still says where the answer came from');
};

subtest 'a walk capped at nothing recovers from the body' => sub {
	plan tests => 3;

	# A cap of nothing reads no commit, so the branch says no marker, and a
	# branch saying no marker is the whole condition the recovery answers.
	# A cap that suppressed the recovery would make the recovery turn on how
	# far the caller let the walk read rather than on what the branch holds.
	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	refresh($h, 'a', $h->slug('qa'));

	my $git  = $h->git('a');
	my $ref  = 'origin/' . $h->slug('qa');
	my $body = sprintf('[pipeline] control@%s -> qa', substr($control, 0, 12));

	my ($sha, undef, $source) = Genesis::CI::Marker::newest($git, $ref,
		limit => 0, recover_from => $body);
	is($sha, $control, 'the reader still takes the marker from the body');
	is($source, 'pull-request', 'and says the body is where it came from');

	is(Genesis::CI::Marker::newest($git, $ref, limit => 0), undef,
		'while a cap of nothing with no body answers nothing, as it did');
};

subtest 'a marker naming another environment is not recovered' => sub {
	plan tests => 7;

	# A pull request body is text a person can edit after Genesis wrote it,
	# and it is the only place the reader takes a marker from that is not a
	# commit on the environment's own branch.  A caller that knows which
	# environment it is asking about says so, and a marker addressed
	# elsewhere is then no answer at all.
	#
	# The bodies below are shaped like the ones the run will hand over.  A
	# body says more after the marker, because Genesis writes a sentence
	# above it and a person may add a note below it, and the GitHub API
	# commonly hands a body back with its lines ending in a carriage return
	# and a newline.  A marker is therefore rarely the last thing in the
	# text and rarely followed by a bare newline.
	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	my $newer = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\nsecond: true\n"},
		message => 'change qa again',
		push    => 1,
	);
	refresh($h, 'a', $h->slug('qa'));

	my $git   = $h->git('a');
	my $ref   = 'origin/' . $h->slug('qa');
	my $short = substr($control, 0, 12);
	my $late  = substr($newer, 0, 12);

	my ($sha, undef, $source) = Genesis::CI::Marker::newest($git, $ref,
		env          => 'qa',
		recover_from => "Carries one control commit.\n\n".
		                "[pipeline] control\@$short -> qa\n\n".
		                "Please review before merging.\n",
	);
	is($sha, $control, 'a marker with more of the body under it is recovered');
	is($source, 'pull-request', 'and the answer says the body is where it came from');

	is(Genesis::CI::Marker::newest($git, $ref,
		env          => 'qa',
		recover_from => "Carries one control commit.\r\n\r\n".
		                "[pipeline] control\@$short -> qa\r\n",
		), $control, 'and so is one in a body whose lines end in a carriage return');

	# Git's own squash lists the newest commit first, so a reader that took
	# the last marker it could match would answer the older one here.
	is(Genesis::CI::Marker::newest($git, $ref,
		env          => 'qa',
		recover_from => "Squashed commit of the following:\n\n".
		                "    [pipeline] control\@$late -> qa\n\n".
		                "    [pipeline] control\@$short -> qa\n",
		), $newer, 'a body carrying two of them still answers the newer');

	my ($wrong, undef, $none) = Genesis::CI::Marker::newest($git, $ref,
		env          => 'qa',
		recover_from => "[pipeline] control\@$short -> prod\n\n".
		                "Raised against prod by hand.\n",
	);
	is($wrong, undef, 'while a body naming another environment recovers nothing');
	is($none, undef, 'and the answer says it came from nowhere');

	is(Genesis::CI::Marker::newest($git, $ref,
		env          => 'qa',
		recover_from => "[pipeline] control\@$short -> qa-west\n",
		), undef, 'and neither does one naming a name qa is only the start of');
};

done_testing;
