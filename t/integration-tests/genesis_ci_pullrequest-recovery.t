#!/usr/bin/env perl
# Proves T271: a rebase merge lands the aggregate with its marker intact, and
# where the site could not apply the setting a squash-merged tip takes its
# marker from the pull request's title or body and the run reports the
# recovery.  The last subtest is the drifted marker, which is why the marker
# is read twice.
#
# The first subtest is green before the recovery exists, and it is here as a
# guard rather than as a proof.  A rebase merge must go on answering off the
# branch, so nothing in the recovery may reach an environment that never lost
# its marker, and the row would go red if it did.
#
# Every row stands its environment up with nothing delivered on its branch, so
# the branch carries no marker of its own and the merge is the only thing that
# can say what it received.  A branch delivered to before would answer out of
# the commit under the merge, which is the hand-commit skip, and no row here
# would ever reach the recovery.
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

subtest 'a rebase merge keeps the marker on the branch' => sub {
	plan tests => 5;

	my $h   = ready(kit => 'omega-v2.7.0', delivered => []);
	my $gh  = $h->{gh};
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('prod');

	my $due = due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');

	my $number = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'none',
		title => sprintf('[pipeline] control@%s -> prod', substr($due, 0, 12)));
	gh_merge_pr($gh, $number, method => 'rebase');

	# A rebase replays the aggregate itself, so what lands on the deployment
	# branch is the commit Genesis wrote and its subject is still the marker.
	deliver($h, 'prod', control => $due);
	refresh($h, 'a', $h->slug('prod'));

	my ($subject) = $git->log_subjects('origin/'.$h->slug('prod'),
		limit => 1, format => '%s');
	like($subject, qr/\[pipeline\] control\@/, 'the marker is in the subject');
	is(harness_marker($h, 'origin/'.$h->slug('prod')), $due,
		'and names the control commit it carried');

	my ($out, $err) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);
	like($said, qr/prod.*idempotent/, 'so the next run has nothing to do');
	unlike($said, qr/recovered the marker/,
		'and nothing was recovered, because nothing was lost');
};

subtest 'a squash-merged tip recovers its marker from the pull request' => sub {
	plan tests => 6;

	my $h  = ready(kit => 'omega-v2.7.0', admin => 0, delivered => []);
	my $gh = $h->{gh};
	my $pr = $h->pr_branch('prod');

	my $due = due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');

	# The site could not be given the rebase-only merge method, so the
	# aggregate went in as a squash, which means the subject is the merger's
	# own and the marker the aggregate carried is nowhere on the branch.  The
	# pull request Genesis opened still says which control commit went in.
	my $number = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'none',
		title => sprintf('[pipeline] control@%s -> prod', substr($due, 0, 12)));
	gh_merge_pr($gh, $number, method => 'squash');
	squash_merge($h, 'prod', keep_marker => 0,
		subject => sprintf('Raise the cf instance count (#%d)', $number));

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the run succeeded');
	like($said, qr/recovered the marker for prod from #$number/,
		'the run reports the recovery and names where it came from');
	like($said, qr/prod.*idempotent/,
		'and treats the environment as caught up rather than re-delivering');

	is(scalar(grep {($_->{method} // '') eq 'POST'} gh_calls($gh)), 0,
		'no second pull request was opened for it');
	ok(!remote_sha($h, $pr), 'and no branch was cut for one');
};

subtest 'the newest merge answers, and its marker may be in the body' => sub {
	plan tests => 5;

	my $h  = ready(kit => 'omega-v2.7.0', admin => 0, delivered => []);
	my $gh = $h->{gh};
	my $pr = $h->pr_branch('prod');

	# The first delivery went in as a squash under its own marker, and the
	# environment then fell behind again, so the branch has two merged pull
	# requests behind it and only the newer one says where it stands now.
	my $first = due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	my $older = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'none',
		title => sprintf('[pipeline] control@%s -> prod', substr($first, 0, 12)));
	gh_merge_pr($gh, $older, method => 'squash');

	# The second went in through the squash form, which offers the merger a
	# title of its own and collects the aggregate's subject into the body as
	# a bulleted line, so the marker is in the body and the title carries
	# none at all.
	my $second = due_commit($h, 'prod', params => {instances => 3},
		message => 'Raise it again');
	my $newer = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'none',
		title => 'Raise it again',
		body  => sprintf("* [pipeline] control@%s -> prod\n",
			substr($second, 0, 12)));
	gh_merge_pr($gh, $newer, method => 'squash');
	squash_merge($h, 'prod', keep_marker => 0,
		subject => sprintf('Raise it again (#%d)', $newer));

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the run succeeded');
	like($said, qr/recovered the marker for prod from #$newer/,
		'the newest merged pull request is the one the marker comes from');
	# This one passes at base on silence rather than on the right answer,
	# because a run that aborts prints "not published, run aborted" in place
	# of the detail line, so no number is named at all and every unlike over
	# that line holds.  It tells the older merge from the newer only once the
	# run above it has succeeded, which is what the exit assertion fences.
	unlike($said, qr/recovered the marker for prod from #$older/,
		'and not the oldest, which would re-propose what the branch has');
	like($said, qr/prod.*idempotent/,
		'so the environment is caught up rather than delivered again');
};

subtest 'a marker naming another environment is not taken' => sub {
	plan tests => 5;

	my $h  = ready(kit => 'omega-v2.7.0', admin => 0, delivered => [],
		envs => ['qa', 'prod']);
	my $gh = $h->{gh};
	my $pr = $h->pr_branch('prod');

	my $due = due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');

	# The merged pull request carries a marker, but one naming qa, so a reader
	# that asked without the environment would take it for prod's.  What
	# landed on prod's branch is somebody else's work, which is why the row
	# lays a hand commit there rather than prod's own set.
	my $number = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'none',
		title => sprintf('[pipeline] control@%s -> qa', substr($due, 0, 12)));
	gh_merge_pr($gh, $number, method => 'squash');
	hand_commit($h, $h->slug('prod'),
		message => sprintf('Raise the cf instance count (#%d)', $number));

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the run succeeded');
	unlike($said, qr/recovered the marker for prod from #$number/,
		'the marker naming another environment is not taken for this one');
	like($said, qr/it names qa rather than prod/,
		'and the run says which environment the marker named');
	like($said, qr/prod.*propagated/,
		'so prod is delivered again rather than treated as caught up');
};

done_testing;
