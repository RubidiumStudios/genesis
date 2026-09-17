#!/usr/bin/env perl
# Proves T324: a deployed-state command switches to the environment's own
# branch inside a session for its read, and finish returns the operator to
# the branch they stood on.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

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

subtest 'info reads the environment branch and returns' => sub {
	stand_on($h, $h->control);

	my ($out, $err, $exit) = run_genesis($h, 'qa', 'info');

	is($exit, 0, 'the read succeeded');
	like("$out$err", qr/marker:\s*delivered/,
		'the read saw the file the deployment branch carries');
	unlike("$out$err", qr/marker:\s*control/,
		'and not the one control carries');
	is($git->current_branch, $h->control,
		'the operator is back on the branch they stood on');
};

subtest 'the switch happens from a feature branch too' => sub {
	$git->create_branch('reading', 'refs/remotes/origin/' . $h->control);
	stand_on($h, 'reading');

	my ($out, $err, $exit) = run_genesis($h, 'qa', 'info');

	is($exit, 0, 'the read succeeded');
	like("$out$err", qr/marker:\s*delivered/,
		'it still read the deployment branch');
	is($git->current_branch, 'reading',
		'and finish returned the operator to the feature branch');
};

subtest 'a deployed-state command is not gated as pre-deploy' => sub {
	# Standing on the deployment branch itself is not a refusal for this
	# class, because that is exactly where the command belongs.
	stand_on($h, $h->slug('qa'));
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'info');

	is($exit, 0, 'no pre-deploy refusal was raised');
	unlike($err, qr/deployment branch/i,
		'and the pre-deploy condition was never evaluated');
};

done_testing;
