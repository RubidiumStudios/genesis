#!/usr/bin/env perl
# Proves T229, the success path restoring all of working state; T230, the bail
# path after a BOSH failure restoring the same; T236, the H16 shape in which a
# process-lifetime object restores a branch it did not set; and T237, the H10
# shape in which the root the deploy read was rebuilt out of whatever its own
# checkout had left behind.
#
# The fifth row is the cleanliness precondition on the path that opens no
# session, which is the one D84 asserts and the session cannot, because on
# that path begin never runs.
#
# The first three rows assert the restoration in their own words, so each of
# them passes restore => 0 and no run is asserted twice.  The fourth and the
# fifth leave nothing anywhere else, so each of them lets run_genesis make
# that assertion for it.
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

subtest 'a deploy from a feature branch in a subdirectory restores W' => sub {
	plan tests => 2;

	# The deployment root sits at bosh/ rather than at the repository root,
	# because this row is about a deploy run from a subdirectory and the
	# deployment branch has to carry that directory for the deploy to reach
	# its end at all.
	my $h = seeded_harness(root => 'bosh');
	fixture_bosh($h);
	run({dir => $h->a}, 'git', 'checkout', '-b', 'wip/a-change');
	stand_on($h, 'wip/a-change', dir => 'bosh');

	my $w = snapshot_w($h);
	# --no-propagate, as the no-git-write rows do: the auto-cascade hands off
	# to a child genesis propagate, which writes to deployment branches on
	# purpose, so a row about what this deploy did should not be reading the
	# child's work as the deploy's own.
	my ($out, $err, $exit) = run_genesis($h, {dir => 'bosh', restore => 0},
		'qa', 'deploy', '--no-propagate', '-y', 'a reason');
	is($exit, 0, 'the deploy succeeded');

	assert_w_restored($w, 'the success path');
};

subtest 'a BOSH failure after the switch restores W and reports the failure' => sub {
	plan tests => 3;

	my $h = seeded_harness();
	fixture_bosh($h);
	run({dir => $h->a}, 'git', 'checkout', '-b', 'wip/a-change');
	stand_on($h, 'wip/a-change');
	# Scoped rather than set and deleted, so a death anywhere below cannot
	# leave the flag armed for every later row in this file, where it would
	# turn a success into a failure that reads as a product bug.
	local $ENV{GENESIS_HARNESS_BOSH_FAILS} = 1;

	my $w = snapshot_w($h);
	# --no-propagate for the reason the row above gives.
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '--no-propagate', '-y', 'a reason');
	isnt($exit, 0, 'the command reports the failure');
	# The environment's own bail is the one that speaks here, and it says
	# "Deployment failed."  The command's own line reads "Deployment
	# Failed", so the match is made without regard to case rather than
	# pinned to whichever of the two the deploy reaches first.
	like($err, qr/Deployment failed/i, 'and names it as a deployment failure');

	assert_w_restored($w, 'the bail path');
};

subtest 'the process-lifetime handle restores nothing it did not set' => sub {
	plan tests => 3;

	my $h = seeded_harness();
	fixture_bosh($h);
	run({dir => $h->a}, 'git', 'checkout', '-b', 'wip/a-change');
	stand_on($h, 'wip/a-change');

	# The H16 shape: one caller switches, a second caller runs, and the
	# first caller's remembered branch is what the process exits on.
	# --no-propagate for the reason the first row gives.
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '--no-propagate', '-y', 'a reason');

	# The exit is read first, because a deploy that refused before it
	# switched anything would leave the branch exactly where this row wants
	# to find it and the two assertions below would prove nothing.
	is($exit, 0, 'the deploy succeeded');

	my ($branch) = run({dir => $h->a}, 'git', 'rev-parse', '--abbrev-ref', 'HEAD');
	chomp $branch;
	is($branch, 'wip/a-change',
		'finish restored the branch the current caller entered on');
	unlike($err // '', qr/restored branch/,
		'and DESTROY restored nothing, having set nothing');
};

subtest 'the deploy reads the branch it switched to, not the one it left' => sub {
	plan tests => 4;

	# The H10 shape, as far as the command line can still reach it.  The
	# deploy checked its own branch out and then rebuilt its root from '.',
	# and a root built after a checkout is a root built out of whatever the
	# checkout left behind, which is how a deploy the checkout had moved out
	# from under reported a repository that was not there rather than the
	# problem in front of it.  The root is now loaded once, on the branch the
	# gate switched to, and the environment file is the discriminator:
	# control and the deployment branch disagree about it, and the blueprint
	# prints whichever of the two the deploy is reading.
	#
	# The subdirectory half of H10 is no longer reachable through the
	# command line.  Genesis resolves <env> against the directory the command
	# was run in and stands the process in the deployment root holding that
	# file, and a deployment branch always carries its own root, so there is
	# no directory left for the switch to take away.  A branch carrying no
	# root at all is the state that remains, and the gate does not switch
	# onto one.
	my $h = seeded_harness();
	write_env_file($h, 'qa', params => {marker => 'control'}, commit => 0);
	# The file is written uncommitted and commit_on_control makes the commit
	# out of the set it is handed, so the body is read back and handed to it
	# rather than left for a commit that would find nothing staged.
	my $on_control = helper::get_file($h->a . '/qa.yml');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => $on_control},
		message => 'mark qa on control',
		push    => 1);
	(my $delivered = $on_control) =~ s/marker: control/marker: delivered/;
	deliver($h, 'qa', control => $control, files => {'qa.yml' => $delivered});
	refresh($h, 'a');
	fixture_bosh($h, hooks => {blueprint =>
		"grep '^  marker:' \"\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml\" >&2\n"
		. "cat > manifest.yml <<'MANIFEST'\n---\nharness: deployed\nMANIFEST\n"
		. "echo manifest.yml\n"});
	stand_on($h, $h->control);

	# Nothing is left anywhere else, so this run lets run_genesis assert the
	# restoration and that is the fourth row of the plan.
	my ($out, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'a reason');

	is($exit, 0, 'the deploy succeeded');
	like("$out$err", qr/marker:\s*delivered/,
		'the deploy read the environment file the deployment branch carries');
	unlike("$out$err", qr/marker:\s*control/,
		'and not the one control carries');
};

subtest 'a deploy that opens no session still refuses a dirty tree' => sub {
	plan tests => 6;

	# The gate opens no session for an environment with no deployment branch,
	# so begin never runs and nothing there asserts the tree clean.  A deploy
	# from a dirty tree would deploy content it then records a commit not
	# holding, which is the audit trail describing something other than what
	# shipped, so the deploy makes the assertion itself on that path.
	my $h = seeded_harness();
	fixture_bosh($h);

	# The branch is taken away everywhere the gate looks for it, which is the
	# local ref and the remote-tracking one, and from R as well so that the
	# deploy's own refresh does not bring it back.
	my $slug = $h->slug('qa');
	delete_on_r($h, $slug);
	delete_local($h, 'a', $slug);
	run({dir => $h->a}, 'git', 'update-ref', '-d', "refs/remotes/origin/$slug");

	stand_on($h, $h->control);

	# Armed with nothing planned, because only fault_git arms the step log the
	# last assertion reads.
	my $git = fault_git($h);

	# The harness picks the file, so this row and the two in the faults file
	# edit the same one, and a harness with a deployment root still answers
	# rather than leaving the row writing to a name that is half empty.
	my $edited = edited_file($h, 'qa');
	my $body = slurp($h->a.'/'.$edited)."# edited in place\n";
	mkfile_or_fail($h->a.'/'.$edited, $body);

	my ($out, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'a reason');

	isnt($exit, 0, 'the deploy refused');
	like($err, qr/Working tree has uncommitted changes/,
		'in the words the switch used to refuse in');
	like($err, qr{\Q$edited\E}, 'naming the file that is modified');
	is(slurp($h->a.'/'.$edited), $body, 'leaving the edit as it was');
	my @writes = grep {$_->[0] =~ /^(checkout|commit|push)$/} step_log($git);
	is_deeply(\@writes, [], 'and refusing before its first write');
};

subtest 'a dry run under a pipeline leaves no session behind' => sub {
	# Three: two rows about the session and one about the cache it left.
	plan tests => 3;

	# A dry run leaves the post-deploy work through an exit of its own,
	# ahead of the finish that every other path reaches, so the session was
	# still open when the process went and the session's last-resort net
	# aborted it on the way out.  The net speaks whenever the status is
	# zero, because on a zero status nothing else has explained why the
	# branch moved, and an operator who asked what a deploy would do was
	# told instead about a session they never opened.
	my $h = seeded_harness();
	fixture_bosh($h);
	run({dir => $h->a}, 'git', 'checkout', '-b', 'wip/a-change');
	stand_on($h, 'wip/a-change');

	# The restoration is left to the rows above, which is why this one
	# passes restore => 0.  The same early exit used to skip the deploy's
	# own cleanup of its cache directory, so a dry run ended with
	# .genesis/deploy-cache standing untracked in the tree and an operator
	# met it at their next git status.  The cache is read here by name
	# rather than through the restoration, because the expanded dev kit
	# stands untracked beside it for a reason of its own and reading the
	# two together would read a second question through the first.
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '--dry-run', '-y', 'a reason');
	is($exit, 0, 'the dry run succeeded')
		or diag("what the dry run said:\n$err");
	unlike($err, qr/exited with a branch session still open/,
		'and said nothing about a session it had left open');
	ok(!-d $h->a . '/.genesis/deploy-cache',
		'and took its deployment cache away behind it');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
