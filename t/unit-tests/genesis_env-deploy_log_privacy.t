#!/usr/bin/env perl
# A deploy's transcript is saved as the deployment's output log, which is
# archived with the deployment.  bosh's output can carry credentials: a
# deploy from a terminal shows the manifest diff with its values, and a
# failing task's error text can quote them.  The saved log therefore keeps
# only structured facts, which are the tasks bosh ran and how each ended,
# the exit code, and the outcome, and it is readable by its owner alone.
# The outcome tells a declined prompt, an EOF at the prompt, and Ctrl-C
# apart, whatever else bosh printed.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Env;

my $env = bless({name => 'fake-env'}, 'Genesis::Env');
my $old = fake_secret('deploy-old-password');
my $new = fake_secret('deploy-new-password');
my $err = fake_secret('deploy-task-error');
my $transcript = join("\r\n",
	"Using environment '10.0.0.4' as client 'admin'", '',
	"Using deployment 'fake'", '',
	'  instance_groups:', '  - name: web', '    properties:',
	"-     password: \"$old\"", "+     password: \"$new\"", '',
	"\e[1mContinue?\e[0m [yN]: y", '',
	'Task 1234', '',
	'Task 1234 | 12:00:00 | Preparing deployment: Preparing deployment (00:00:01)',
	"Task 1234 | 12:00:05 | Error: Action Failed get_task: $err",
	'Task 1234 Started  Mon Nov 16 12:00:00 UTC 2026',
	'Task 1234 Finished Mon Nov 16 12:00:05 UTC 2026',
	'Task 1234 Duration 00:00:05',
	'Task 1234 error', '',
	'Updating deployment:',
	"  Expected task '1234' to succeed but state is 'error'", '',
	'Exit code 1', '');

subtest 'the saved log keeps the tasks, the exit code, and the outcome' => sub {
	my $saved = $env->_deploy_log_content($transcript, 1, 'Deployment failed.');
	unlike($saved, qr/\Q$old\E|\Q$new\E|\Q$err\E/, 'no value from the diff or the task error is saved');
	unlike($saved, qr/Preparing deployment|password|instance_groups/, 'nor any other line bosh printed');
	like($saved, qr/^Task 1234: error$/m, 'each task is listed with its final state');
	like($saved, qr/^Task 1234 started: Mon Nov 16 12:00:00 UTC 2026$/m, 'with when it started');
	like($saved, qr/^Task 1234 finished: Mon Nov 16 12:00:05 UTC 2026$/m, 'when it finished');
	like($saved, qr/^Task 1234 duration: 00:00:05$/m, 'and how long it took');
	like($saved, qr/^bosh exit code: 1$/m, 'the exit code is kept');
	like($saved, qr/^Outcome: Deployment failed\.$/m, 'and so is the outcome');
};

subtest 'a transcript without tasks keeps only the exit code and outcome' => sub {
	my $saved = $env->_deploy_log_content("Deploying:\n  Creating instance 'bosh/0' $err\nExit code 1\n", 1, 'Deployment failed.');
	unlike($saved, qr/\Q$err\E|Creating instance/, 'nothing bosh printed is saved');
	like($saved, qr/^No bosh tasks were reported\.$/m, 'the log says there were no tasks');
	like($saved, qr/^bosh exit code: 1$/m, 'and keeps the exit code');
	like($env->_deploy_log_content(undef, undef, 'Deployment failed.'), qr/^No output received\.$/m,
		'and a missing transcript is noted');
};

subtest 'a task line that does not match its form is left out' => sub {
	my $odd = join("\n",
		"Task 77 Started  $err", "Task 77 Duration $err", "Task 77 done $err", "Task 77 $err",
		'Task 77 done', '');
	my $saved = $env->_deploy_log_content($odd, 0, 'Deployment succeeded.');
	unlike($saved, qr/\Q$err\E/, 'no value is saved');
	like($saved, qr/^Task 77: done$/m, 'only the well-formed state is kept');
};

my $prompt = "\e[1mContinue?\e[0m [yN]: ";
for my $case (
	["${prompt}n\r\n\r\nStopped\r\n\r\nExit code 1\r\n", 1, 'declined',
		'User canceled deployment when prompted to continue.', 1],
	["${prompt}\r\nAsking for confirmation:\r\n  EOF\r\n\r\nExit code 1\r\n", 1, 'eof',
		'User interrupted deployment at continue prompt.', 1],
	["${prompt}y\r\n\r\nTask 99\r\n\r\nTask 99 | 12:00:00 | Updating instance\r\n^C\r\n", 130, 'interrupted',
		'User interrupted deployment (Ctrl-C)', 0],
	["Task 99\r\nTask 99 done\r\n\r\nSucceeded\r\n", 0, 'succeeded', 'Deployment succeeded.', 1],
	["Task 99\r\nTask 99 error\r\n\r\nExit code 1\r\n", 1, 'failed', 'Deployment failed.', 1],
	[undef, 1, 'failed', 'Deployment failed.', 1],
) {
	my ($out, $rc, $kind, $message, $cleanup) = @$case;
	subtest "a $kind deploy is told apart" => sub {
		my %outcome = $env->_deploy_outcome($out, $rc);
		is($outcome{kind}, $kind, 'the outcome is recognised');
		is($outcome{message}, $message, 'and described');
		is($outcome{cleanup_cache}, $cleanup, 'and the cache is kept for a rejoin only after Ctrl-C');
	};
}

subtest 'the saved log is readable by its owner alone' => sub {
	my $dir = tempdir(CLEANUP => 1);
	my $path = "$dir/cache/fake-env-output.log";
	my $saved = $env->_save_deploy_log($path, $transcript, 1, 'Deployment failed.');
	is($saved, $path, 'the log is written');
	is(sprintf('%o', (stat($path))[2] & 07777), '600', 'with mode 0600');
	unlike(slurp($path), qr/\Q$old\E|\Q$err\E/, 'and without any value');
};

done_testing;
