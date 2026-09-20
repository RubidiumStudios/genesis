#!/usr/bin/env perl
# Proves T269: an unreachable GitHub API refuses the whole run, names what it
# could not read, quotes the reader in the reader's own words, writes nothing,
# and exits Genesis::Exit::UNAVAILABLE.  The second subtest proves the double
# answers the reviews route, without which every state below collapses to
# unreviewed and three of the review states cannot be driven at all.
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
use Genesis::CI::PullRequest;
use Service::Github;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'an unreadable review state refuses the run and writes nothing' => sub {
	plan tests => 10;

	my $h  = ready(kit => 'omega-v2.7.0', envs => ['qa', 'prod']);
	my $gh = $h->{gh};

	# The due commit is written through the harness rather than composed
	# here, because the run reads require_pr out of this very file and a body
	# written by hand that dropped the key would take the whole arm with it.
	# Both environments are given something due, so a run that read no state
	# would cut and publish a pull request branch for each of them and the
	# two branch assertions below discriminate.
	$h->write_env_file($_, params => {instances => 2}) for qw/qa prod/;
	$h->push_from('a', $h->control);
	$h->refresh('a');
	my $seed = $h->git('a')->sha($h->control);

	my $number = gh_pull_request($gh,
		env  => 'prod',
		head => $h->pr_branch('prod'),
		base => $h->slug('prod'),
	);
	$h->fixture_proposed('prod', control => $seed, pr => $number);
	local_branch($h, $h->pr_branch('prod'),
		at => $h->slug('prod'), push => 1);

	my $before_prod = remote_sha($h, $h->pr_branch('prod'));
	gh_unreachable($gh);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);

	is($exit, Genesis::Exit::UNAVAILABLE, 'the run exits UNAVAILABLE');
	like($said, qr/review state/i, 'it names the review state');
	like($said, qr/could not read|unreachable/i,
		'and says it could not read it');
	# Not "retry once the API answers again".  Every failure of the two
	# readers arrives at this one refusal, a rejected token and a renamed
	# repository among them, and a retry helps none of those.  What the
	# reader said is quoted instead, and that is what says which it was.
	like($said, qr/Failed to list pull requests/,
		'and quotes what the reader itself said');
	unlike($said, qr/\[FATAL\][\s\S]*\[FATAL\]/,
		'with the quote stripped of its own banner rather than nested');
	# The refusal stands ahead of the walk, so nothing was written and there
	# was nothing to undo.  A run that read the state inside its own walk
	# would deliver both environments first and come back through the abort,
	# which is the reading this row tells apart.
	unlike($said, qr/aborted/i,
		'it refused before writing, so no branch had to be reset');

	is(remote_sha($h, $h->pr_branch('prod')), $before_prod,
		"prod's pull request branch on R did not move");
	ok(!remote_sha($h, $h->pr_branch('qa')),
		'no pull request branch was created for qa either');

	my @writes = grep {($_->{method} // 'GET') ne 'GET'} gh_calls($gh);
	is(scalar @writes, 0, 'and the run made no write call to the API');
};

subtest 'the state comes back as the double declared it' => sub {
	plan tests => 5;

	my $h  = ready();
	my $gh = $h->{gh};

	my $approved = gh_pull_request($gh, env => 'prod',
		head => $h->pr_branch('prod'), base => $h->slug('prod'),
		review => 'approved', reviewer => 'dbell');
	gh_close_pr($gh, $approved, merged => 0);
	my $open = gh_pull_request($gh, env => 'prod',
		head => $h->pr_branch('prod'), base => $h->slug('prod'),
		review => 'changes_requested', reviewer => 'dbell',
		review_body => 'Wait for the capacity plan.');

	# The double is a curl first on the path, so an in-process reader reaches
	# it the way a spawned command does.
	local $ENV{PATH} = join(':', $gh->{bin}, $ENV{PATH});
	local $ENV{GITHUB_AUTH_TOKEN} = $gh->{token};

	my $github = Service::Github->new(org => 'owner');
	my $state  = Genesis::CI::PullRequest::pr_state($github, 'owner/repo', {
		env    => 'prod',
		branch => $h->slug('prod'),
		pr     => {branch => $h->pr_branch('prod')},
	});

	is($state->{state}, 'changes requested',
		'the open pull request reads as changes requested');
	is($state->{number}, $open, 'and by its own number');
	is($state->{review}{reviewer}, 'dbell', 'the reviewer comes back');
	like($state->{review}{body}, qr/capacity plan/, 'and their words with them');
	is_deeply($state->{superseded}, [$approved],
		'while the closed one is a prior attempt and not a state');
};

done_testing;
