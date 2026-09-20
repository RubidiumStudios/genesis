#!/usr/bin/env perl
# Every refusal the pre-publish re-check can raise, and the one answer that
# lets the push go out.  The integration row proves behind, because behind is
# what a teammate pushing during a walk leaves, and each of the other six
# answers earns words of its own that no run in the suite reaches.
#
# The state is stubbed rather than built, because building six repositories to
# read six sentences says nothing about the sentences.  The query itself is
# proved where it lives, in t/unit-tests/service_git-divergence.t, and the
# stub stands in for it here so each branch of the refusal is read on its own.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::CI::Publish;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# A real handle, because the sub takes one and calls two of its methods.  The
# repository behind it is never read, since both methods are stubbed for the
# length of each call.
my $h   = make_harness(envs => ['lab'], mode => 'direct', vault => 0);
my $git = $h->git('a');

# The sentence is returned rather than printed, so each row reads what came
# back.  The refusal carries its own colour markup, because the caller renders
# it, and the patterns below match around that markup rather than past it.
sub refusal_for {
	my ($state) = @_;
	no warnings 'redefine';
	local *Service::Git::fetch_branches = sub {1};
	local *Service::Git::resolve_branch = sub {$state};
	return Genesis::CI::Publish::_recheck_control($git, 'control', 'origin');
}

subtest 'in-sync is the one answer that lets the push go out' => sub {
	plan tests => 1;
	is(refusal_for({state => 'in-sync', ahead => 0, behind => 0}), undef,
		'a control nobody moved refuses nothing');
};

subtest 'a control that is on neither side names both' => sub {
	plan tests => 3;
	# resolve_branch answers nothing at all where neither ref exists, which
	# is the one state the design gives no name to.
	my $said = refusal_for(undef);
	like($said, qr/is neither here nor on #C\{origin\} any more/,
		'the refusal says control is gone from both sides');
	like($said, qr/the environment files live on it/,
		'and says what was lost with it');
	like($said, qr/Put it back, then run/, 'and what to do about it');
};

subtest 'a control the remote has never had is pushed, not rebased' => sub {
	plan tests => 2;
	my $said = refusal_for({state => 'no-remote', ahead => 0, behind => 0});
	like($said, qr/is here and no longer on #C\{origin\}/,
		'the refusal says the remote does not hold control');
	like($said, qr/Push it with #C\{git push origin control\}/,
		'and the step that repairs it is a push');
};

subtest 'a control this repository lost is written back from the remote' => sub {
	plan tests => 2;
	my $said = refusal_for({state => 'no-local', ahead => 0, behind => 0});
	like($said, qr/has gone from this repository since the run started/,
		'the refusal says the local ref went during the run');
	like($said, qr/Write the ref with #C\{git checkout -B control origin\/control\}/,
		'and the step that repairs it writes the ref back');
};

subtest 'a control carrying unpushed commits is pushed' => sub {
	plan tests => 3;
	my $said = refusal_for({state => 'ahead', ahead => 2, behind => 0});
	like($said, qr/carries 2 commits that are not on #C\{origin\/control\}/,
		'the refusal counts what the remote has never seen');
	like($said, qr/which are unpushed/, 'and says what that makes them');
	like($said, qr/Push them with #C\{git push origin control\}/,
		'and the step that repairs it is a push');
};

subtest 'a control that is behind is stale, and its count governs its noun' => sub {
	plan tests => 2;
	my $said = refusal_for({state => 'behind', ahead => 0, behind => 1});
	like($said, qr/is behind #C\{origin\/control\} by 1 commit,/,
		'one commit is one commit and not one commits');
	like($said, qr/so everything this run computed is stale/,
		'and the refusal says what that costs the run');
};

subtest 'a diverged control is both, and earns both steps' => sub {
	plan tests => 3;
	my $said = refusal_for({state => 'diverged', ahead => 2, behind => 3});
	like($said, qr/is ahead of #C\{origin\/control\} by 2 commits and behind it by 3 commits/,
		'the refusal counts both sides');
	like($said, qr/so it is both unpushed and stale/,
		'and says what that makes control');
	like($said,
		qr/Rebase with #C\{git pull --rebase origin control\} and push with #C\{git push origin control\}/,
		'and the step that repairs it does both');
};

subtest 'a state this run does not know is named, not dressed up' => sub {
	plan tests => 3;

	# The divergence arm used to be the fall-through, so a seventh answer
	# the query grew would have been rendered as divergence and would have
	# read its two counts out of a record carrying neither.
	my $said = refusal_for({state => 'unrelated'});
	like($said, qr/unrelated/,
		'the refusal names the state it was given');
	unlike($said, qr/both unpushed and stale/,
		'and does not call it divergence');
	unlike($said, qr/by 0 commits|by  commits/,
		'and invents no counts for it');
};

subtest 'every refusal says the same three things about the run' => sub {
	plan tests => 3;
	# Whichever answer the query gives, the operator is told that Genesis
	# did not move control, that nothing reached the remote, and that the
	# branches the run wrote are back where the remote has them.
	for my $state (
		{state => 'no-remote', ahead => 0, behind => 0},
		{state => 'ahead',     ahead => 1, behind => 0},
		{state => 'diverged',  ahead => 1, behind => 1},
	) {
		my $said = refusal_for($state);
		like($said,
			qr/Genesis never moves control\.\s+Nothing was pushed, and every branch this run wrote has been put back\./,
			"the $state->{state} refusal says what the run did and did not do");
	}
};

done_testing;
