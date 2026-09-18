#!/usr/bin/env perl
# Proves T264: an approved pull request freezes, so the run neither rebuilds
# nor pushes the branch, holds the new due commit with the reason
# awaiting-merge, and records the environment held with the number beside it.
#
# The row needs a pull request branch that R already carries and a reviewer who
# has approved what is on it, so the first run is what builds and publishes
# that branch.  The pull request that run opens is unreviewed, and the double
# has no way to add a review to a pull request it already holds, so the row
# closes that one and declares the approved one in its place.  Leaving both
# open would put the several-pull-requests warning in the middle of a row about
# a freeze, and which of two open ones a run acts on is another row's subject.
#
# The due commits are laid through the environment file at the deployment root
# rather than under prod/, because a path under prod/ is in no propagation set
# and a commit written there would route nowhere and leave nothing due.
#
# What the run says is read off standard error, where the report is written,
# and the patterns cross the fold the way the hold rows in
# genesis_ci_walk-holds.t do, so each one names the axis it is asserting.
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

# One due control commit, written through the harness and committed by hand,
# because the run reads require_pr out of that very file and a body composed
# here that dropped the key would take the whole arm with it, while the
# harness's own commit carries a message the rows below cannot name.
sub due_commit {
	my ($h, %opts) = @_;
	my $path = $h->write_env_file('prod', params => $opts{params},
		commit => 0);
	return commit_on_control($h,
		files   => {$path => slurp($h->a."/$path")},
		message => $opts{message},
		push    => 1,
	);
}

subtest 'an approved pull request freezes' => sub {
	plan tests => 10;

	my $h   = ready(kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $pr  = $h->pr_branch('prod');

	my $proposed = due_commit($h, params => {instances => 2},
		message => 'Raise the cf instance count');
	run_genesis($h, 'propagate', '-y');
	refresh($h, 'a', $pr);
	my $frozen_at = remote_sha($h, $pr);

	# The pull request that run opened, taken off the pointer the run wrote
	# rather than guessed at, and closed so that the approved one below is the
	# only one open on the branch.
	my $opened = record_at($h, $h->env_path('prod').'/proposed')->{number};
	gh_close_pr($gh, $opened, merged => 0);

	my $number = gh_pull_request($gh, env => 'prod', head => $pr,
		base => $h->slug('prod'), review => 'approved', reviewer => 'dbell');
	fixture_proposed($h, 'prod', control => $proposed, pr => $number);

	my $later = due_commit($h, params => {instances => 3},
		message => 'Raise it again');

	# How much of the call log belongs to the run that stood the fixture up,
	# so what is counted below is what the frozen run itself sent.
	my $already = scalar(() = gh_calls($gh));

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');
	is(remote_sha($h, $pr), $frozen_at, 'the branch on R did not move');

	like($err, qr/^\s*prod: held, awaiting merge \(#$number\)$/m,
		'the environment is recorded held, awaiting merge with the number');
	like($err, qr/control\@\Q@{[substr($later, 0, 7)]}\E[^\n]*\bheld\b/,
		'the new due commit is held');
	like($err, qr/control\@\Q@{[substr($later, 0, 7)]}\E[^\n]*\n\s*H awaiting merge \(#$number\)/,
		'and its reason names the merge it is waiting for');
	unlike($err, qr/^\s*prod: propagated\b/m, 'and never propagated');

	my @sent = gh_calls($gh);
	splice(@sent, 0, $already);
	my @writes = grep {($_->{method} // 'GET') ne 'GET'} @sent;
	is(scalar @writes, 0, 'the run touched the pull request not at all');
	is(record_at($h, $h->env_path('prod').'/proposed')->{control_commit},
		$proposed, 'and left the proposed record naming what is open');
};

done_testing;
