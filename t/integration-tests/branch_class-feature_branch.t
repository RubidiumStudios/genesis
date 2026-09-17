#!/usr/bin/env perl
# Proves T196, T197, and T198: a feature branch is permitted only when it
# descends from control's tip as observed through T after a refresh, is no
# derived branch, and is named for no environment, and propagate switches
# to control rather than refusing.
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

# The refusals are read back as whole sentences, so the width they fold at
# is the file's to fix rather than the terminal's to decide.
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], type => 'bosh', kit => 'omega-v2.7.0');
init_branch($h, 'qa');
refresh($h, 'a');
my $git = $h->git('a');

subtest 'a stale feature branch is refused, a rebased one is accepted' => sub {
	# The feature branch is cut from the control tip copy A can see now.
	$git->create_branch('add-prod', $h->control);

	# The teammate then publishes a commit to control, so the feature
	# branch no longer descends from control's tip on R.
	publish_from_b($h, files => {'lab.yml' => "kit:\n  name: bosh\n"},
		message => 'Add environment lab');

	stand_on($h, 'add-prod');
	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod', '--no-commit');

	is($exit, Genesis::Exit::DATAERR(),
		'the stale feature branch is refused');
	like($err, qr/does not descend/i,
		'the refusal names the descent condition');
	like($err, qr/\Q@{[ $h->control ]}\E/,
		'and names the control branch it is measured against');

	# The refused run already refreshed control into T, so rebasing onto
	# that ref is what makes the same branch permitted.
	Genesis::run({dir => $h->a, onfailure => 'rebase failed'},
		'git', 'rebase', 'refs/remotes/origin/' . $h->control, 'add-prod');

	($out, $err, $exit) = run_genesis($h, {restore => 0},
		'new', 'prod', '--no-commit');
	is($exit, 0, 'the rebased feature branch is accepted');
	ok(-f $h->a . '/prod.yml', 'and the environment file was written');

	# The accepted run left the environment file staged, so the index is
	# put back before the next row reads a branch state of its own.
	Genesis::run({dir => $h->a}, 'git', 'reset', '-q');
	unlink $h->a . '/prod.yml';
};

subtest 'a branch named for the environment being added is refused' => sub {
	$git->create_branch('prod2', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'prod2');

	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod2', '--no-commit');

	is($exit, Genesis::Exit::DATAERR(),
		'the collision with the environment being added is refused');
	like($err, qr/named for an environment/i,
		'the refusal names the condition');
	like($err, qr/\Q@{[ $h->slug('prod2') ]}\E/,
		'and names the branch that could never be created');
	like($err, qr/rename/i,
		'and gives renaming the feature branch as the remedy');
};

subtest 'a branch named for an existing environment is refused' => sub {
	# Git will not hold refs/heads/qa beside refs/heads/qa/bosh, which is
	# the very collision this row is about, so the branch is cut in the
	# clone that knows qa's deployment branch through the remote alone.
	# That is an ordinary clone: nothing makes an operator check a
	# deployment branch out before they cut a feature branch.
	delete_local($h, 'a', $h->slug('qa'));
	$git->create_branch('qa', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'qa');

	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod3', '--no-commit');

	is($exit, Genesis::Exit::DATAERR(),
		'the collision with an existing environment is refused');
	like($err, qr/named for an environment/i,
		'the refusal names the same condition');
	like($err, qr/\Q@{[ $h->slug('qa') ]}\E/,
		'and names the deployment branch the collision blocks');

	# The local ref goes back before the rows below read the repository,
	# so nothing after this one runs against a clone this row narrowed.
	stand_on($h, $h->control);
	Genesis::run({dir => $h->a}, 'git', 'branch', '-q', '-D', 'qa');
	$git->create_branch($h->slug('qa'),
		'refs/remotes/origin/' . $h->slug('qa'));
};

subtest 'a branch that satisfies all three is permitted' => sub {
	$git->create_branch('add-prod4', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'add-prod4');

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'new', 'prod4');
	is($exit, 0, 'genesis new runs on the permitted feature branch');
	is($git->current_branch, 'add-prod4',
		'and writes on that branch');
	my ($subject) = $git->log_subjects('add-prod4', limit => 1);
	like($subject, qr/prod4/, 'the commit landed there');
};

subtest 'propagate switches to control rather than refusing' => sub {
	# prod4 exists on this branch and on no other, because the row above
	# committed it here.  Control carries qa and lab and knows nothing of
	# it, so what the preview names is evidence of the tree the run read.
	stand_on($h, 'add-prod4');

	# The teammate's commit above left copy A's own control ref a commit
	# behind the remote, and propagate refuses a stale control for its own
	# reasons and before it ever reads a class.  The operator's pull is
	# made here so that what this row reads is the gate's exemption.
	Genesis::run({dir => $h->a, onfailure => 'could not advance control'},
		'git', 'branch', '-q', '-f', $h->control,
		'refs/remotes/origin/' . $h->control);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '--dry-run', '-y');

	is($exit, 0, 'propagate runs from the feature branch rather than refusing');
	like("$out$err", qr/\bqa\b/,
		'the preview names an environment the control branch carries');
	unlike("$out$err", qr/\bprod4\b/,
		'and none of the one that exists only on the branch we stood on, '.
		'so the topology was read from control');
};

subtest 'control_requires_pr moves the expectation to a feature branch' => sub {
	# Proves T201: when control_requires_pr is set, genesis new expects a
	# feature branch and says so, naming the key, while the feature branch
	# itself proceeds.
	#
	# The key is committed on control and then published, because the branch
	# below is cut from the remote-tracking ref and a key that never left
	# copy A would not be on it.  Without the push the second half proves
	# nothing about whether the code reads the key there.
	stand_on($h, $h->control);
	set_repo_config($h, 'pipeline.source_control.control_requires_pr', 1);
	push_from($h, 'a', $h->control);
	refresh($h, 'a', $h->control);

	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod5', '--no-commit');

	is($exit, Genesis::Exit::DATAERR(),
		'the run on control is refused rather than warned');
	like($err . $out, qr/feature branch/i,
		'the refusal says a feature branch is expected');
	like($err . $out, qr/control_requires_pr/,
		'and names the key that decided it');

	# add-prod and prod are both taken by the first row of this file, which
	# shares one harness and one fixture vault with every row below it, so
	# the branch and the environment are named afresh here.  Re-using prod
	# would meet the secrets that row already wrote, and genesis new asks
	# before it removes them.
	$git->create_branch('add-prod5', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'add-prod5');
	($out, $err, $exit) = run_genesis($h, {restore => 0},
		'new', 'prod5', '--no-commit');

	is($exit, 0, 'the run on the feature branch proceeds');
	unlike($err . $out, qr/control_requires_pr/,
		'and says nothing about the key');

	# --no-commit left the environment file staged, so the index is put
	# back here.  A row below rebases, and a rebase refuses over a dirty
	# index, so a leftover here would stop a red run at this row instead of
	# letting it report every one of them.
	Genesis::run({dir => $h->a}, 'git', 'reset', '-q');
	unlink $h->a . '/prod5.yml';
};

subtest 'a detached HEAD behind control is let through' => sub {
	# The guard above the predicate is what this row reads.  A detached
	# HEAD is no branch, so neither remedy the predicate offers could be
	# carried out on it, and the pre-flight and the apply own the state
	# instead.  The commit stood on is one control has moved past, so a run
	# that reached the predicate would be refused on the descent condition,
	# and that is what makes the guard provable here.
	Genesis::run({dir => $h->a, onfailure => 'could not detach HEAD'},
		'git', 'checkout', '-q', '--detach',
		'refs/remotes/origin/' . $h->control . '~1');

	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'new', 'prod9', '--no-commit');

	is($exit, 0, 'the run on a detached HEAD is let through');
	unlike(unfolded($out, $err), qr/does not descend/i,
		'and is not refused on the descent condition');

	# The index and the branch both go back, so the rows below read the
	# clone this row was handed.
	Genesis::run({dir => $h->a}, 'git', 'reset', '-q');
	unlink $h->a . '/prod9.yml';
	stand_on($h, 'add-prod5');
};

subtest 'a clone that has never fetched control is told so' => sub {
	# This is the single-branch clone, where origin holds control and this
	# clone holds neither the local branch nor the remote-tracking ref.
	# resolve_branch reads local refs alone, so it answers nothing here,
	# and the remote is what settles that control is somewhere and that a
	# fetch is the remedy.  Told it exists nowhere, an operator would be
	# sent to create a branch that is already on the remote.
	#
	# The refresh above the predicate stands aside, because a clone with no
	# local control branch is the pre-flight's repair to make and to
	# report, so both refs really are still missing when the predicate
	# runs.  Both go back at the end, and R is never touched.
	my $control_sha = $git->sha($h->control);
	$git->create_branch('add-prod6', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'add-prod6');
	delete_local($h, 'a', $h->control);
	Genesis::run({dir => $h->a, onfailure => 'could not drop the ref'},
		'git', 'update-ref', '-d', 'refs/remotes/origin/' . $h->control);

	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod6', '--no-commit');

	is($exit, Genesis::Exit::DATAERR(),
		'the run is refused');
	like($err . $out, qr/has not been fetched/i,
		'the refusal says control has not arrived in this clone');
	unlike($err . $out, qr/exists\s+neither/,
		'and not that it exists nowhere, because origin holds it');

	$git->create_branch($h->control, $control_sha);
	refresh($h, 'a', $h->control);
	is_deeply([
			ref_in($h->a, 'refs/heads/' . $h->control),
			ref_in($h->a, 'refs/remotes/origin/' . $h->control),
		], [$control_sha, $control_sha],
		'and the refs this row dropped are back where it found them');
};

subtest 'a control that lives in this clone alone is refused too' => sub {
	# The other way the tracking ref goes missing.  Control is here and
	# the remote has lost it, which resolve_branch answers by itself, so
	# the remote is never asked and the refusal is the same one.  Control
	# has to go from R as well as from the tracking ref, because the
	# refresh fetches whenever the local branch is here and a control the
	# remote still held would simply come back.
	my $control_sha = $git->sha($h->control);
	$git->create_branch('add-prod7', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'add-prod7');
	delete_on_r($h, $h->control);
	Genesis::run({dir => $h->a, onfailure => 'could not drop the ref'},
		'git', 'update-ref', '-d', 'refs/remotes/origin/' . $h->control);

	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod7', '--no-commit');

	is($exit, Genesis::Exit::DATAERR(),
		'the run is refused at the same exit');
	like($err . $out, qr/has not been fetched/i,
		'and with the same condition, since control is not nowhere');

	# R takes control back from the copy that still holds it, and the
	# tracking ref comes back with the fetch.  Both are measured against
	# the commit this row found control on rather than against each other,
	# because ref_in answers undef for a ref that is absent and two absent
	# refs would agree.
	push_from($h, 'a', $h->control);
	refresh($h, 'a', $h->control);
	is_deeply([
			ref_in($h->a, 'refs/remotes/origin/' . $h->control),
			ref_in($h->r, 'refs/heads/' . $h->control),
		], [$control_sha, $control_sha],
		'and the refs this row dropped are back where it found them');
};

subtest 'a clone with control nowhere is refused at CONFIG' => sub {
	# Neither place the predicate can look has control, and neither does
	# the remote when it is asked, so there is nothing to fetch and
	# nothing for the branch to be measured against.  That state belongs
	# to the pre-flight, which creates control from the remote, and to the
	# apply, which declines a clone that never had one.  This gate speaks
	# before either of them, so it says the sentence the pre-flight says
	# and exits where the pre-flight exits.
	my $control_sha = $git->sha($h->control);
	$git->create_branch('add-prod8', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'add-prod8');
	delete_on_r($h, $h->control);
	delete_local($h, 'a', $h->control);
	Genesis::run({dir => $h->a, onfailure => 'could not drop the ref'},
		'git', 'update-ref', '-d', 'refs/remotes/origin/' . $h->control);

	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod8', '--no-commit');

	is($exit, Genesis::Exit::CONFIG(),
		'the run is refused at CONFIG, where the pre-flight refuses it');
	like($err . $out, qr/exists\s+neither\s+on\s+\S*origin\S*\s+nor\s+locally/,
		'and names the branch and both of the places it is not in');
	unlike($err . $out, qr/git fetch/,
		'and offers no fetch, because there is nothing anywhere to fetch');

	# All three refs go back, so nothing below this row reads a clone it
	# narrowed.
	$git->create_branch($h->control, $control_sha);
	push_from($h, 'a', $h->control);
	refresh($h, 'a', $h->control);
	is_deeply([
			ref_in($h->a, 'refs/heads/' . $h->control),
			ref_in($h->a, 'refs/remotes/origin/' . $h->control),
			ref_in($h->r, 'refs/heads/' . $h->control),
		], [$control_sha, $control_sha, $control_sha],
		'and all three refs this row dropped are back at the commit it '.
		'found them on');
};

subtest 'a command that promised no fetch is told to fetch' => sub {
	# pipeline-describe answers out of the repository's own files, so the
	# gate allows it no refresh, and the predicate below the gate may ask
	# the remote no more than the gate did.  Control is in neither ref
	# here and the remote's address is one nothing can reach, so a
	# predicate that asked would die in ls-remote's own words instead of
	# refusing with the fetch this clone really does need.
	my $control_sha = $git->sha($h->control);
	$git->create_branch('add-prod9', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'add-prod9');
	delete_local($h, 'a', $h->control);
	Genesis::run({dir => $h->a, onfailure => 'could not drop the ref'},
		'git', 'update-ref', '-d', 'refs/remotes/origin/' . $h->control);
	Genesis::run({dir => $h->a, onfailure => 'could not move the remote'},
		'git', 'remote', 'set-url', 'origin', $h->r . '-is-not-here');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-describe');
	my $said = unfolded($out, $err);

	is($exit, Genesis::Exit::DATAERR(),
		'the run is refused at DATAERR');
	like($said, qr/has not been fetched/i,
		'the refusal says control has not arrived in this clone');
	like($said, qr/git fetch/,
		'and the remedy is the fetch that brings it');
	unlike($said, qr/ls-remote/,
		'and the remote was never asked, because no refresh was allowed');

	# The remote's address and both refs go back, so the row below reads
	# the clone this one was handed.
	Genesis::run({dir => $h->a, onfailure => 'could not restore the remote'},
		'git', 'remote', 'set-url', 'origin', $h->r);
	$git->create_branch($h->control, $control_sha);
	refresh($h, 'a', $h->control);
	is_deeply([
			ref_in($h->a, 'refs/heads/' . $h->control),
			ref_in($h->a, 'refs/remotes/origin/' . $h->control),
		], [$control_sha, $control_sha],
		'and the refs this row dropped are back where it found them');
};

subtest 'a repository with no remote names the bare control branch' => sub {
	# With no remote configured the predicate reads control's tip off the
	# local branch, so the rebase it offers has no remote to prefix and
	# names the branch itself.  The feature branch is cut from the tip and
	# control is moved on afterwards, so the branch really is behind what
	# it is measured against.
	#
	# The remote is named in the repository's own configuration first,
	# because source_control.remote is otherwise derived from the one
	# configured remote, and a repository with none is refused for that
	# before it ever reaches a branch class.
	my $control_sha = $git->sha($h->control);
	stand_on($h, $h->control);
	set_repo_config($h, 'pipeline.source_control.remote', 'origin');
	$git->create_branch('add-prod10', $h->control);
	helper::put_file($h->a . '/notes10.txt', "a commit on control\n");
	Genesis::run({dir => $h->a, onfailure => 'could not stage the file'},
		'git', 'add', '--', 'notes10.txt');
	Genesis::run({dir => $h->a, onfailure => 'could not move control on'},
		'git', 'commit', '-q', '-m', 'Move control on');
	stand_on($h, 'add-prod10');
	Genesis::run({dir => $h->a, onfailure => 'could not drop the remote'},
		'git', 'remote', 'remove', 'origin');

	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod10', '--no-commit');
	my $said = unfolded($out, $err);
	my $remedy = 'git rebase ' . $h->control;

	is($exit, Genesis::Exit::DATAERR(),
		'the stale feature branch is refused');
	like($said, qr/does not descend/i,
		'on the descent condition');
	like($said, qr/\Q$remedy\E/,
		'and the remedy names the control branch itself');
	unlike($said, qr{git rebase \S*origin/},
		'rather than a remote-tracking ref there is no remote for');

	# The remote and control's tip go back, so this file leaves the clone
	# as it found it.
	Genesis::run({dir => $h->a, onfailure => 'could not restore the remote'},
		'git', 'remote', 'add', 'origin', $h->r);
	Genesis::run({dir => $h->a, onfailure => 'could not put control back'},
		'git', 'branch', '-q', '-f', $h->control, $control_sha);
	refresh($h, 'a', $h->control);
	is(ref_in($h->a, 'refs/heads/' . $h->control), $control_sha,
		'and control is back on the commit this row found it on');
};

done_testing;
