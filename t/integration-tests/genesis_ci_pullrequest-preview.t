#!/usr/bin/env perl
# Proves T334 and T335: --dry-run reports the marker title with its supersedes
# list, makes read-only calls only, and pushes nothing, and with no token it
# still runs, says the review state is unread, and marks its prediction
# unverified rather than refusing.
#
# The asymmetry is the point.  Only a writing run refuses on a state it cannot
# read under D55, and writing nothing does not forbid reading, so the preview
# reads everything it can and says plainly what it could not.
#
# Each row's due commit is laid through due_commit, because the only file that
# routes to an environment is that environment's own file at the deployment
# root and a path under the environment's name is in no propagation set at all.
#
# A run says what it did through the logger, which writes to standard error, so
# every assertion on the run's own words reads unfolded($out, $err), as every
# other row in this area does.
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

subtest 'the preview reports the title and touches nothing' => sub {
	plan tests => 7;

	my $h   = ready(kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('prod');

	my $first  = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'none');
	gh_close_pr($gh, $first, merged => 0);
	my $second = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'none');
	gh_close_pr($gh, $second, merged => 0);

	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');

	is($exit, 0, 'the preview succeeded');
	# The two closed attempts are named in whichever order the listing gave
	# them, as the title row already reads them, because which of them the
	# API answers first is its business and this row is about both being
	# named under the marker the run would use.
	like(unfolded($out, $err),
		qr/\[pipeline\] control\@\w+ -> prod \(supersedes (?:#$first, #$second|#$second, #$first)\)/,
		'it reports the marker title with the supersedes list');

	my @writes = grep {($_->{method} // 'GET') ne 'GET'} gh_calls($gh);
	is(scalar @writes, 0, 'every call it made was read-only');
	cmp_ok(scalar gh_calls($gh), '>', 0, 'though it read the state');

	ok(!remote_sha($h, $pr), 'it created no branch on R');
	ok(!$git->branch_exists($pr), 'and none locally');
};

subtest 'a preview with no token says what it could not read' => sub {
	plan tests => 7;

	my $h  = ready(kit => 'omega-v2.7.0');
	my $gh = $h->{gh};
	gh_pull_request($gh, env => 'prod', head => $h->pr_branch('prod'),
		base => $h->slug('prod'), review => 'approved');

	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');

	my ($out, $err, $exit) = run_genesis($h, {no_token => 1},
		'propagate', '--dry-run');

	my $said = unfolded($out, $err);
	is($exit, 0, 'it runs to the end and refuses nothing');
	like($said, qr/review state.*unread.*token/i,
		'it reports the review state as unread because the token is missing');
	like($said, qr/unverified/,
		'and marks its pull request branch prediction unverified');
	like($said, qr/\[pipeline\] control\@\w+ -> prod/,
		'while still printing the marker title');
	unlike($said, qr/supersedes/,
		'and claims no supersedes list, having read none');

	is(scalar gh_calls($gh), 0, 'it made no call at all');
};

done_testing;
