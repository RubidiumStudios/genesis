#!/usr/bin/env perl
# Proves T324: a deployed-state command switches to the environment's own
# branch inside a session for its read, the session closes where the command
# returns, and the operator is left on the branch they stood on.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Fcntl qw/:flock/;
use Test::More;

# make_harness runs fixture_vault itself unless the row says vault => 0, so
# it is not run again here.
my $h = make_harness(envs => ['qa'], type => 'bosh');
my $git = $h->git('a');

# The kit's info hook is the discriminator.  `genesis <env> info` prints
# what the hook writes, and the hook reads the environment file out of the
# working tree, so the line it prints names whichever branch the session
# left the tree standing on.  The kit is untracked, so it is the same kit
# on every branch while the file it reads is not.
fixture_kit($h, hooks => {
	info      => "grep '^  marker:' \"\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml\"\n",
	blueprint => "echo manifest.yml\n",
});

# Control and the deployment branch disagree about the environment file, so
# a read that came from control would be visibly the wrong one.
write_env_file($h, 'qa', params => {marker => 'control'}, commit => 0);
# The file is written uncommitted and unstaged, and commit_on_control makes
# the commit out of the set it is handed, so the body is read back and
# handed to it rather than left for a commit that would find nothing staged.
my $on_control = helper::get_file($h->a . '/qa.yml');
my $control = commit_on_control($h,
	files => {'qa.yml' => $on_control},
	message => 'Edit qa on control', push => 1);
(my $delivered = $on_control) =~ s/marker: control/marker: delivered/;
deliver($h, 'qa', control => $control, files => {'qa.yml' => $delivered});
refresh($h, 'a');
certify($h, 'qa', control_commit => $control);

# The switch lock is per working tree and it is never unlinked, so the
# question a row can ask of it afterwards is whether anybody still holds it.
my $lock_path = $git->git_dir . '/genesis-session.lock';

# An assertion rather than a state builder, so it lives here beside the row
# that reads it rather than in the harness.
sub lock_is_free {
	my ($name) = @_;
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	open(my $fh, '+>>', $lock_path) or return fail("$name (cannot open the lock)");
	my $free = flock($fh, LOCK_EX | LOCK_NB) ? 1 : 0;
	flock($fh, LOCK_UN) if $free;
	close $fh;
	return ok($free, $name);
}

subtest 'info reads the environment branch and closes the session' => sub {
	stand_on($h, $h->control);

	my ($out, $err, $exit) = run_genesis($h, 'qa', 'info');

	is($exit, 0, 'the read succeeded');
	like("$out$err", qr/marker:\s*delivered/,
		'the read saw the file the deployment branch carries');
	unlike("$out$err", qr/marker:\s*control/,
		'and not the one control carries');

	# The session's own net aborts a session that is still open when the
	# process exits, and says so.  A gate that leaves the closing to an
	# exit hook is a gate whose every successful run meets the net, so
	# this row fails against one and passes only where the gate closed the
	# session itself.
	unlike("$out$err", qr/branch session still open/,
		'the session was closed by the command rather than by the net');

	# Green on arrival, because the kernel drops a flock when its holder
	# exits whatever the run did.  It catches a gate that hands the session
	# to something outliving the command, which would leave a live holder
	# named in the lock file.
	lock_is_free('the switch lock is free again');
};

subtest 'the switch happens from a feature branch too' => sub {
	$git->create_branch('reading', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'reading');

	my ($out, $err, $exit) = run_genesis($h, 'qa', 'info');

	is($exit, 0, 'the read succeeded');
	like("$out$err", qr/marker:\s*delivered/,
		'it still read the deployment branch');
};

subtest 'a deployed-state command is not gated as pre-deploy' => sub {
	# Standing on the deployment branch itself is not a refusal for this
	# class, because that is exactly where the command belongs.  The first
	# two rows are green on arrival, since this command succeeded here
	# before the class existed; the refusal row catches a gate that handed
	# info to assert_pre_deploy, whose refusal says "is a deployment
	# branch", and the marker row catches a switch that is not a no-op
	# when the tree already stands where it is going.
	stand_on($h, $h->slug('qa'));
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'info');

	is($exit, 0, 'no pre-deploy refusal was raised');
	unlike($err, qr/deployment branch/i,
		'and the pre-deploy condition was never evaluated');
	like("$out$err", qr/marker:\s*delivered/,
		'the read still saw the deployment branch');
};

subtest 'a refusal inside the command keeps its own exit code' => sub {
	stand_on($h, $h->control);

	# Two arguments too many, which information refuses with its usage
	# error.  The refusal is raised inside the command, with the session
	# open, so the code it exits is the code the whole run should carry.
	# A gate that closes its session from an exit hook loses it: the hook
	# bails after the command has already chosen 2, and the run ends 255.
	#
	# The usage code stands in for the DATAERR the class will one day
	# refuse with, because no refusal inside info carries a named exit
	# code today and any code that is neither 0 nor 1 proves the point.
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'info', 'one', 'two');

	is($exit, 2, 'the command\'s own usage code survived the session');
	like("$out$err", qr/Usage:/,
		'and the operator was shown the usage the command raised');

	# The command exits before finish is reached, so the session's net
	# restores the tree.  On a run that is already ending non-zero the
	# command has said why it stopped, and a second sentence about a
	# session the operator never knew they had buries the refusal above
	# it, so the net puts the branch back and says nothing.
	unlike("$out$err", qr/branch session still open/,
		'and no unrelated sentence followed the refusal');
};

subtest 'an environment that was never delivered is not switched' => sub {
	# staging has a file on control and no deployment branch, which is
	# every environment between genesis new and its first deploy.
	write_env_file($h, 'staging', params => {marker => 'control'}, commit => 0);
	my $staging = helper::get_file($h->a . '/staging.yml');
	commit_on_control($h,
		files => {'staging.yml' => $staging},
		message => 'Add staging on control', push => 1);
	stand_on($h, $h->control);

	my ($out, $err, $exit) = run_genesis($h, 'staging', 'info');

	like("$out$err", qr/No record of deployment found/,
		'the command said what it has always said');
	unlike("$out$err", qr/not in this repository/,
		'and met no refusal about a commit the repository lacks');
	is($exit, 0, 'and exited as it did before the class existed');
};

subtest 'a command with no environment opens no session' => sub {
	stand_on($h, $h->control);

	my ($out, $err, $exit) = run_genesis($h, 'info');

	is($exit, 2, 'the usage error is what the operator gets');
	unlike("$out$err", qr/file an issue/i,
		'rather than a bug report about an undefined name');
	unlike("$out$err", qr/branch session still open/,
		'and no session was opened to be aborted');
};

done_testing;
