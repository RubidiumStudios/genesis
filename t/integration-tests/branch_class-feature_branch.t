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
};

done_testing;
