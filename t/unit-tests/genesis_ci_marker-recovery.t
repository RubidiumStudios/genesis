#!/usr/bin/env perl
# Proves T81's reader half: where the site could not grant the rebase-only
# merge method and a squash merge took the marker with it, the reader takes
# it from the pull request's body and says where it came from.  The event
# line the run prints is M16's, because the run is M16's.
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
	plan tests => 5;

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

	my (undef, undef, $plain) = Genesis::CI::Marker::newest($git, $ref,
		recover_from => 'no marker in this body either');
	is($plain, undef, 'while a body carrying no marker recovers nothing');
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

done_testing;
