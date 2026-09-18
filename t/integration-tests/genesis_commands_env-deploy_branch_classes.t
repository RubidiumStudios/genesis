#!/usr/bin/env perl
# Proves T214, the three branch states and the one ref move; T216, the two D48
# refusals in the deploy's wording; T217, the awaiting pipeline-apply refusal
# at DATAERR under both providers; and T329, the divergence refusal printing
# before the prior-env one.
#
# Two subtests are about a branch with no repository on it, which answer alike
# from the local ref and are not alike at all.  The fourth is an environment
# nothing has been delivered to on either side: the gate declines to switch
# onto it and the deploy refuses, naming the propagation.  The fifth is a
# clone nobody has pulled since the apply cut the branch, which the gate
# brings forward for the deploy alone, so the deploy reads the delivered file
# while a read of the same branch leaves the ref where it found it.  Without
# the first, a deploy runs from wherever the operator is standing and
# certifies a commit no propagation routed anywhere; without the second, an
# operator one fetch away from a deploy is sent to a command that cannot help.
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

	# The operator is standing on control, so the move this row reads is the
	# gate's, made on the way to the switch because the deploy's
	# registration declares it.  The deploy's own move, which is the one
	# made for an operator already standing on the branch, is read by the
	# last subtest in this file.
	#
	# Green on arrival, and a guard rather than a discriminator: the deploy
	# already pulled --ff-only unconditionally.  What it catches is a branch
	# merely behind being refused, or being reset to the tracking ref
	# instead of fast-forwarded, which would discard a commit a deploy may
	# never discard.
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
	# delivery is the subtest below, and that one deploys, the gate having
	# brought the branch forward for it; what is refused here is an
	# environment nothing has been routed to yet, on either side, and what it
	# is told to run is the propagation.
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

subtest 'a stale clone deploys the branch, and a read moves no ref' => sub {
	plan tests => 8;

	# The operator's own copy of the branch sits where pipeline-apply cut it
	# while the remote carries the deliveries, which is a clone nobody has
	# pulled rather than an environment awaiting a delivery.  catch_up => 0
	# leaves it that way, which is the state every other row in this file has
	# the builder catch up for it.
	#
	# The branch is the working tree a command reads, and the checkout stands
	# that tree on the commit the local ref names, so the branch has to be
	# brought up before the switch or the deploy is stood on the init commit.
	# The move here is therefore the gate's, made ahead of the switch for a
	# command whose registration declares it, and the deploy's registration
	# is the only one that does.  That is what the two halves of this row
	# read: the gate brings the branch forward for the deploy, which then
	# reads the delivered file, and it moves nothing for info, which says
	# why it read where it stands.
	#
	# The environment file is the discriminator for both.  Control and the
	# branch disagree about it, and the kit's hooks print whichever the
	# command was reading.
	my $h    = seeded_harness();
	my $slug = $h->slug('qa');
	write_env_file($h, 'qa', params => {marker => 'control'}, commit => 0);
	# The file is written uncommitted and commit_on_control makes the commit
	# out of the set it is handed, so the body is read back and handed to it.
	my $on_control = helper::get_file($h->a . '/qa.yml');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => $on_control},
		message => 'mark qa on control',
		push    => 1);
	(my $delivered = $on_control) =~ s/marker: control/marker: delivered/;
	deliver($h, 'qa', control => $control, files => {'qa.yml' => $delivered});
	refresh($h, 'a', $h->control, $slug);
	fixture_bosh($h, catch_up => 0, hooks => {
		info      => "grep '^  marker:' \"\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml\"\n",
		blueprint =>
			"grep '^  marker:' \"\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml\" >&2\n"
			. "cat > manifest.yml <<'MANIFEST'\n---\nharness: deployed\nMANIFEST\n"
			. "echo manifest.yml\n"});
	stand_on($h, $h->control);

	my $stale  = tip_of($h, $slug);
	my $target = tip_of($h, $slug, remote => 1);

	# The read runs first, while the ref it must not move is still the stale
	# one.  Run after the deploy it would have nothing left to leave alone.
	my ($iout, $ierr) = run_genesis($h, 'qa', 'info');
	is(tip_of($h, $slug), $stale, 'a read of the same branch moves no ref');
	like(unfolded($iout, $ierr),
		qr/holds it \d+ commits? behind origin\/\Q$slug\E/,
		'and says how far behind the branch it read past stands');

	my ($out, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the stale clone deploys');
	like("$out$err", qr/marker:\s*delivered/,
		'reading the environment file the deployment branch carries');
	unlike("$out$err", qr/marker:\s*control/,
		'and not the one control carries');
	is(tip_of($h, $slug), $target,
		'and the branch was fast-forwarded to its counterpart');
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

subtest "a deploy from the branch makes the move the gate did not" => sub {
	plan tests => 4;

	# The gate returns before it moves anything where the operator is
	# already standing on the deployment branch, under D80, so the deploy's
	# own fast-forward is the one that runs and this is the only state that
	# reaches it.  The branch has to carry a repository before the run, or
	# the command would meet the refusal about a branch with no deployment
	# root rather than the delivery behind it, so the clone is brought up to
	# a first delivery and only then left behind a second.
	#
	# Green on arrival and a guard: the deploy's own pull landed with the
	# classification.  What it catches is that pull being dropped now that
	# the gate has one of its own, which would leave an operator standing on
	# their deployment branch deploying the delivery before the one waiting
	# for them, and recording it as the commit they shipped.
	my $h    = seeded_harness();
	my $slug = $h->slug('qa');

	# The environment file is the discriminator, and the blueprint prints
	# whichever of the two deliveries the deploy read.
	write_env_file($h, 'qa', params => {marker => 'first'}, commit => 0);
	my $body = helper::get_file($h->a . '/qa.yml');
	my $one  = commit_on_control($h,
		files   => {'qa.yml' => $body},
		message => 'mark qa first',
		push    => 1);
	deliver($h, 'qa', control => $one);
	refresh($h, 'a', $h->control, $slug);
	fixture_bosh($h, hooks => {
		blueprint =>
			"grep '^  marker:' \"\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml\" >&2\n"
			. "cat > manifest.yml <<'MANIFEST'\n---\nharness: deployed\nMANIFEST\n"
			. "echo manifest.yml\n"});

	# The second delivery, which this clone has fetched and not pulled.
	(my $next = $body) =~ s/marker: first/marker: second/;
	my $two = commit_on_control($h,
		files   => {'qa.yml' => $next},
		message => 'mark qa second',
		push    => 1);
	deliver($h, 'qa', control => $two);
	refresh($h, 'a', $h->control, $slug);
	stand_on($h, $slug);

	my $target = tip_of($h, $slug, remote => 1);

	# restore => 0 and no restoration assertion, because the whole subject
	# of the row is a ref this run is meant to move: the branch the operator
	# is standing on ends the run at its counterpart rather than where it
	# started.
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the deploy ran from the branch the operator stood on');
	like("$out$err", qr/marker:\s*second/,
		'reading the delivery this clone had not pulled');
	unlike("$out$err", qr/marker:\s*first/,
		'and not the one it was standing on');
	is(tip_of($h, $slug), $target,
		"and the deploy's own fast-forward moved L to T");
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
