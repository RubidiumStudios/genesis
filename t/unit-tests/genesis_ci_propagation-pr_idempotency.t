#!/usr/bin/env perl
# Proves T85 at the call sites: the PR idempotency check and the propagation
# base both answer through the one reader, so a squash, an amend, and a
# coincidental short sha give the same answer that the tip's subject used to
# decide on its own.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use_ok 'Genesis::CI::Propagation';
use_ok 'Genesis::Commands::Pipelines';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;


subtest 'the idempotency check reads the marker, not the subject' => sub {
	plan tests => 3;

	# The delivery is written into copy A, because every read below is taken
	# from copy A's own branch rather than from the ref R holds.
	my ($h, $control) = seeded(copy => 'a');
	my $git = $h->git('a');
	my $short = $git->sha($control, short => 1);

	ok(!Genesis::CI::Propagation::_pr_branch_has_control_sha(
			$git, $h->pr_branch('qa'), $short),
		'a branch that does not exist is not idempotent');

	ok(Genesis::CI::Propagation::_pr_branch_has_control_sha(
			$git, $h->slug('qa'), $short),
		'a branch whose newest marker names this control commit is');

	my $other = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\nmore: true\n"},
		message => 'change qa again',
		push    => 1,
	);
	ok(!Genesis::CI::Propagation::_pr_branch_has_control_sha(
			$git, $h->slug('qa'), $git->sha($other, short => 1)),
		'and a branch whose marker names another commit is not');
};

subtest 'a squash, an amend, and a hand commit leave it idempotent' => sub {
	plan tests => 3;

	{
		# The squash's parent is the branch R holds, so the push that
		# follows it fast-forwards rather than being refused.
		my ($h, $control) = seeded(copy => 'a');
		my $git = $h->git('a');
		squash_merge($h, 'qa', control => $control,
			subject => 'Merge pull request #11 from pr/qa/bosh');
		ok(Genesis::CI::Propagation::_pr_branch_has_control_sha(
				$git, $h->slug('qa'), $git->sha($control, short => 1)),
			'after a squash that left the marker in the body alone');
	}

	{
		my ($h, $control) = seeded(copy => 'a');
		my $git = $h->git('a');
		amend_tip($h, $h->slug('qa'), copy => 'a',
			subject => 'tidy the delivered files');
		# The amend checks the branch out in copy A, so the copy is put
		# back on control before the row reads anything.
		stand_on($h, $h->control);
		ok(Genesis::CI::Propagation::_pr_branch_has_control_sha(
				$git, $h->slug('qa'), $git->sha($control, short => 1)),
			'after an amend that rewrote the subject');
	}

	{
		my ($h, $control) = seeded(copy => 'a');
		my $git = $h->git('a');
		hand_commit($h, $h->slug('qa'), copy => 'a',
			files   => {'notes.txt' => "see the incident\n"},
			message => 'note that a1b2c3d4e5f6 broke the build',
		);
		stand_on($h, $h->control);
		ok(Genesis::CI::Propagation::_pr_branch_has_control_sha(
				$git, $h->slug('qa'), $git->sha($control, short => 1)),
			'and under a hand commit naming a short sha in passing');
	}
};

subtest 'the propagation base answers through the same reader' => sub {
	plan tests => 5;

	my ($h, $control) = seeded(copy => 'a');
	my $git = $h->git('a');

	# A branch cut off control and never delivered to, so the row below can
	# read the merge-base arm rather than meeting its zero by accident.
	local_branch($h, $h->slug('prod'), at => $h->control);

	my ($base, $depth) = Genesis::Commands::Pipelines::_resolve_propagation_base(
		$h->slug('qa'), $git, $h->control);
	is($base, $control, 'the base is the control commit the marker names');
	is($depth, 0, 'with nothing standing above it');

	hand_commit($h, $h->slug('qa'), copy => 'a',
		files   => {'qa.yml' => "---\nkit: dev\nhotfix: true\n"},
		message => 'raise the instance count for the incident',
	);
	stand_on($h, $h->control);
	my (undef, $after) = Genesis::Commands::Pipelines::_resolve_propagation_base(
		$h->slug('qa'), $git, $h->control);
	is($after, 1, 'and the hand commit above it is counted, not followed');

	my (undef, $fallback) = Genesis::Commands::Pipelines::_resolve_propagation_base(
		$h->slug('prod'), $git, $h->control);
	is($fallback, 0, 'while the merge-base fallback counts nothing at all');

	{
		# The squash leaves its marker in the body alone, and the delivery
		# underneath it carries an older control commit in its subject, so a
		# resolver reading subject lines answers with the older commit and
		# only the reader answers with the one the branch now holds.
		my ($g) = seeded(copy => 'a');
		my $newer = commit_on_control($g,
			files   => {'qa.yml' => "---\nkit: dev\nsecond: true\n"},
			message => 'change qa again',
			push    => 1,
		);
		squash_merge($g, 'qa',
			control => $newer,
			subject => 'Merge pull request #7 from pr/qa/bosh',
		);
		my ($squashed) = Genesis::Commands::Pipelines::_resolve_propagation_base(
			$g->slug('qa'), $g->git('a'), $g->control);
		is($squashed, $newer,
			'and a squash is read from its body rather than from the subject');
	}
};

done_testing;
