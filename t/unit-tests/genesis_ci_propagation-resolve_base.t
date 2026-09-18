#!/usr/bin/env perl
# Proves T85 at the propagation base: the base a command reports for a
# deployment branch is read through the one marker reader, so a squash, a hand
# commit above the delivery, and a branch that was never delivered to each
# give the answer the branch actually holds rather than the answer a walk over
# subject lines would compose.
#
# This subtest stood in genesis_ci_propagation-pr_idempotency.t, beside six
# cases about an idempotency predicate that has since been replaced by
# Genesis::CI::PullRequest::settled.  Those six retired with the predicate.
# This one did not, because _resolve_propagation_base is live code: the status
# table's branch column is filled from it, and nothing else covers its marker
# arm, the depth it reports, or the body a squash leaves its marker in.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use_ok 'Genesis::Commands::Pipelines';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

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
