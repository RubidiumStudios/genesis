#!/usr/bin/env perl
# Proves T214, the three branch states and the one ref move; T216, the two D48
# refusals in the deploy's wording; T217, the awaiting pipeline-apply refusal
# at DATAERR under both providers; and T329, the divergence refusal printing
# before the prior-env one.
#
# Two subtests are about a branch with no repository on it, which the gate
# declines to switch onto, and they are two different states that answer alike
# from the local ref.  The fourth is an environment nothing has been delivered
# to on either side, which waits for a propagation.  The fifth is a clone
# nobody has pulled since the apply cut the branch, which waits for a pull,
# and it reads the remedy rather than the propagation that cannot help it.
# Without either, a deploy runs from wherever the operator is standing and
# certifies a commit no propagation routed anywhere.
#
# Every row calls fixture_bosh where the branch has to carry a repository,
# because a seeded harness leaves the operator's own copy of the deployment
# branch at the commit the apply cut and every delivery is published from the
# teammate's copy.  The builder's catch-up is what a pull would have done, and
# the rows whose subject is a branch carrying nothing say so and either leave
# the builder out or pass catch_up => 0.
#
# Every run passes --no-propagate.  The auto-cascade hands off to a child
# genesis propagate, which writes to deployment branches on purpose and which
# M15 owns, and a row about what the deploy decided should not be reading the
# child's work as the deploy's own.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'behind fast-forwards, ahead and diverged refuse' => sub {
	plan tests => 13;

	my $behind = seeded_harness();
	my $slug   = $behind->slug('qa');

	# The catch-up first, so the branch this row is about carries the
	# delivery, and the teammate's move after it, so the operator's copy is
	# one commit behind what the remote holds.
	fixture_bosh($behind);
	move_on_r($behind, $slug);
	refresh($behind, 'a', $behind->control, $slug);
	my $target = tip_of($behind, $slug, remote => 1);

	# Green on arrival, and a guard rather than a discriminator: the deploy
	# already pulled --ff-only unconditionally.  What it catches is a
	# classification that refuses a branch that is merely behind, or that
	# resets it to the tracking ref instead of fast-forwarding it, which
	# would discard a commit a deploy may never discard.
	my (undef, undef, $exit) = run_genesis($behind,
		'qa', 'deploy', '--no-propagate', '-y', 'r');
	is($exit, 0, 'a behind branch deploys');
	is(tip_of($behind, $slug), $target,
		'and L was fast-forwarded to T, creating and discarding nothing');

	# One local commit makes the ahead case, and diverge adds a published
	# commit and a second local one, so the diverged case is two ahead and one
	# behind.  The counts are read with their nouns, because a refusal naming
	# a bare number leaves an operator guessing the unit, and the verb is read
	# with them, because the state's own name is not one: a branch is ahead of
	# its counterpart and has diverged from it.
	for my $case (
		['ahead',    'local_only',
		 qr{is ahead of origin/qa/bosh by 1 commit\b}],
		['diverged', 'both',
		 qr{has diverged from origin/qa/bosh, standing 2 commits ahead of it}],
	) {
		my ($state, $how, $counts) = @$case;
		my $h = seeded_harness();
		fixture_bosh($h);
		local_only_commit($h, $slug, marker => 0, message => 'a local commit');
		diverge($h, $slug) if $how eq 'both';
		# The commits above stand copy A on the branch they are made on, and
		# this row is about a deploy that meets the divergence on its way to
		# the branch rather than one made from it.
		stand_on($h, $h->control);
		my $before = tip_of($h, $slug);

		my (undef, $err, $code) = run_genesis($h,
			'qa', 'deploy', '--no-propagate', '-y', 'r');
		is($code, Genesis::Exit::DATAERR, "a $state branch is refused");
		like(unfolded($err), qr/genesis propagate/, 'naming genesis propagate');
		like(unfolded($err), $counts,
			"reading the state as a verb and both counts with their noun");
		is(tip_of($h, $slug), $before,
			'and no commit was created or discarded');
	}
};

subtest 'the two D48 refusals in the deploy wording' => sub {
	plan tests => 10;

	my $local_only = seeded_harness();
	my $slug       = $local_only->slug('qa');

	# A branch the remote has never had, which here is one the remote has
	# stopped having: it is taken off R, and off copy A's own tracking ref,
	# which no fetch prunes for us.  The catch-up runs first so that what is
	# left behind is a branch carrying the repository rather than one
	# carrying nothing, which is the state the subtest below is about.
	fixture_bosh($local_only);
	delete_on_r($local_only, $slug);
	run({dir => $local_only->a},
		'git', 'update-ref', '-d', "refs/remotes/origin/$slug");

	my (undef, $err1, $code1) = run_genesis($local_only,
		'qa', 'deploy', '--no-propagate', '-y', 'r');
	is($code1, Genesis::Exit::DATAERR, 'a local branch R lacks is refused');
	like(unfolded($err1), qr/Refusing to deploy\./, 'reading refusing to deploy');
	like(unfolded($err1), qr/Nothing was deployed\./, 'and nothing was deployed');
	ok(defined(tip_of($local_only, $slug)),
		'and the local branch is still there');

	# A branch of the right name sharing no ancestor with the remote's is an
	# orphan carrying one file, so the gate declines to switch onto it and
	# the deploy classifies it from control.  There is no catch-up here,
	# because the orphan replaces whatever the branch held.
	my $unrelated = seeded_harness();
	unrelated_branch($unrelated, 'qa');
	my (undef, $err2, $code2) = run_genesis($unrelated,
		'qa', 'deploy', '--no-propagate', '-y', 'r');
	is($code2, Genesis::Exit::DATAERR, 'a branch sharing no ancestor is refused');
	like(unfolded($err2), qr/shares no ancestor with/, 'naming the reason');
	like(unfolded($err2), qr/git branch -D \Q$slug\E/, 'giving the remedy in order');
	ok(defined(tip_of($unrelated, $slug)), 'and deleting nothing');
};

subtest 'no branch anywhere is awaiting pipeline-apply' => sub {
	plan tests => 10;

	for my $provider (qw/manual concourse/) {
		my $h    = seeded_harness(provider => $provider);
		my $slug = $h->slug('qa');

		# All three places the branch can be read from, because a fetch
		# prunes none of them and the tracking ref alone would write the
		# local branch back.
		delete_on_r($h, $slug);
		delete_local($h, 'a', $slug);
		run({dir => $h->a},
			'git', 'update-ref', '-d', "refs/remotes/origin/$slug");

		my (undef, $err, $exit) = run_genesis($h, {pipeline_task => 'deploy-qa'},
			'qa', 'deploy', '--no-propagate', '-y', 'r');

		is($exit, Genesis::Exit::DATAERR, "under $provider it exits DATAERR");
		like(unfolded($err), qr/awaiting pipeline-apply/,
			'saying it is awaiting the apply');
		like(unfolded($err), qr/genesis pipeline-apply.*genesis propagate/,
			'and naming the two commands in order');
		like(unfolded($err), qr/Nothing was deployed\./, 'and nothing was deployed');
	}
};

subtest 'a branch carrying no repository is awaiting its first delivery' => sub {
	plan tests => 5;

	# The apply cut the branch and no propagation has delivered to it on
	# either side, which is the staged shape: the branch holds the init
	# commit and so does its counterpart.  That is the arm of the gate that
	# declines to switch, and a classification that read the state alone
	# would call it in-sync and deploy from control.  A clone merely behind a
	# delivery is the subtest below, which is refused in words of its own;
	# what is refused here is an environment nothing has been routed to yet,
	# and what it is told to run is the propagation.
	#
	# There is no fixture_bosh here, because the branch carrying nothing is
	# the whole of the state and the deploy never reaches a director.
	my $h    = staged(envs => ['qa']);
	my $slug = $h->slug('qa');

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, Genesis::Exit::DATAERR, 'a branch with nothing on it is refused');
	# The refusal's own words carry the phrase, rather than the phrase alone.
	# The gate says the same thing about the same branch as it declines to
	# switch onto it, and a bare match would pass on that line while the
	# deploy went on to deploy from control.
	like(unfolded($err), qr/Refusing to deploy\..*carries no repository/,
		'saying what the branch holds, in the refusal');
	like(unfolded($err), qr/genesis pipeline-apply.*genesis propagate/,
		'and naming the two commands in order');
	like(unfolded($err), qr/Nothing was deployed\./, 'and nothing was deployed');
};

subtest 'a stale clone is sent to the pull, not to the propagation' => sub {
	plan tests => 6;

	# The operator's own copy of the branch sits where pipeline-apply cut it
	# while the remote carries a delivery, which is a clone nobody has pulled
	# rather than an environment awaiting one.  catch_up => 0 leaves it that
	# way, which is the state every other row in this file has the builder
	# catch up for it.
	#
	# The two states answer the same way from the local ref, and the branch is
	# the working tree the command reads, so Genesis cannot read this one
	# without moving a ref and the gate moves none: every other deployed-state
	# command reads, and a read moves no ref.  What the deploy owes the
	# operator here is therefore the remedy that works, which is the pull.
	# Nothing is deleted and nothing is moved.
	my $h    = seeded_harness();
	my $slug = $h->slug('qa');
	my $before = tip_of($h, $slug);
	fixture_bosh($h, catch_up => 0);
	stand_on($h, $h->control);

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, Genesis::Exit::DATAERR, 'the stale clone is refused');
	like(unfolded($err), qr/has not pulled it/,
		'saying the delivery is on the remote and unpulled');
	like(unfolded($err), qr/git fetch origin \Q$slug\E:\Q$slug\E/,
		'and naming the pull as the remedy');
	unlike(unfolded($err), qr/Refusing to deploy\..*genesis propagate/,
		'rather than a propagation that would find nothing due');
	is(tip_of($h, $slug), $before, 'and the branch was left where it was');
};

subtest 'the divergence refusal prints before the prior-env one' => sub {
	plan tests => 3;

	my $h    = seeded_harness();
	my $slug = $h->slug('qa');

	# Both refusals apply to this one deploy, which is the whole point of the
	# row: the environment gains a predecessor that has never deployed, the
	# delivery carries that file onto the branch, and only then is the branch
	# diverged.  Without the delivery the branch would carry an environment
	# file with no prior env in it and the second refusal could not apply.
	write_env_file($h, 'qa', pipeline => {prior_env => 'lab'});
	push_from($h, 'a', $h->control);
	my $control = tip_of($h, $h->control);
	deliver($h, 'qa', control => $control);
	fixture_bosh($h);
	local_only_commit($h, $slug, marker => 0, message => 'a local commit');
	diverge($h, $slug);
	stand_on($h, $h->control);

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	like(unfolded($err), qr/genesis propagate/, 'the divergence refusal printed');
	# The second row is green while the deploy has no classification at all,
	# because the unconditional pull bails on a diverged branch before the
	# prior-env check is reached.  What it catches is a classification placed
	# after that check, which is where the deploy's own order would have put
	# it: the operator would then be told to deploy lab first and would learn
	# about the divergence only on the run after that.
	unlike(unfolded($err), qr/never been successfully deployed/,
		'and the prior-env refusal did not');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
