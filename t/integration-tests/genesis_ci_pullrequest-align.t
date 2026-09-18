#!/usr/bin/env perl
# The pull request branch is brought level with what the remote carries now,
# and not with what it carried the last time this clone looked.  Nothing but
# align_with_remote ever writes that remote-tracking ref, so from the second
# run for an environment onward the ref is present and stale, and an
# alignment that fetched only where the ref was missing would reset the
# branch to the previous run's tip and read the previous run's discard
# report off it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::CI::PullRequest;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a stale tracking ref does not survive the alignment' => sub {
	plan tests => 4;

	my $h   = ready();
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('prod');

	# The branch stands on R and this clone has fetched it once, which is
	# the state the run after a delivery finds.
	local_branch($h, $pr, at => $h->slug('prod'), push => 1);
	$h->refresh('a', $pr);
	my $stale = ref_in($h->a, "refs/remotes/origin/$pr");
	ok($stale, 'the tracking ref is here, as a second run would find it');

	# Somebody else moves the branch on R, and this clone is told nothing.
	my $moved = publish_from_b($h,
		branch  => $pr,
		files   => {'moved.yml' => "---\nmoved: true\n"},
		message => 'Move the pull request branch on R',
	);
	isnt($moved, $stale, 'and the branch on R has moved under this clone');

	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($pr);

	is(Genesis::CI::PullRequest::align_with_remote($git, $pr), 1,
		'the alignment says the remote carries the branch');
	is($git->sha($pr), $moved,
		"and the local branch stands at the remote's current tip");

	$session->finish;
};

done_testing;
