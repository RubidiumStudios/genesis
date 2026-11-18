#!/usr/bin/env perl
# A deploy from a terminal runs bosh with --no-redact, so the operator
# sees the manifest diff with its values.  The transcript is then saved
# as the deployment's output log, and that file must not keep the diff:
# it keeps bosh's task output, which carries no values, and says the diff
# was left out.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;

use Genesis;
use Genesis::Env;

my $env = bless({name => 'fake-env'}, 'Genesis::Env');
my $old = fake_secret('deploy-old-password');
my $new = fake_secret('deploy-new-password');
my $transcript = join("\n",
	"Using environment '10.0.0.4' as client 'admin'", '',
	"Using deployment 'fake'", '',
	'  instance_groups:', '  - name: web', '    properties:',
	"-     password: \"$old\"", "+     password: \"$new\"", '',
	"\e[1mContinue?\e[0m [yN]: y", '',
	'Task 1234', '',
	'Task 1234 | 12:00:00 | Preparing deployment: Preparing deployment (00:00:01)',
	'Task 1234 Started  Mon Nov 16 12:00:00 UTC 2026', 'Succeeded', '');

subtest 'an unredacted transcript is saved without its diff' => sub {
	my $saved = $env->_deploy_log_content($transcript, 1);
	unlike($saved, qr/\Q$old\E|\Q$new\E/, 'neither value is saved');
	like($saved, qr/^Task 1234 \| 12:00:00 \| Preparing deployment/m, 'the task output is kept');
	like($saved, qr/Succeeded/, 'through to the end');
	like($saved, qr/diff .*left out/i, 'and the log says the diff was left out');
};

subtest 'an unredacted transcript with no task keeps nothing of it' => sub {
	my $saved = $env->_deploy_log_content("Using deployment 'fake'\n-  password: \"$old\"\nExit code 1\n", 1);
	unlike($saved, qr/\Q$old\E/, 'the value is not saved');
	like($saved, qr/left out/i, 'the log says why it is empty');
};

subtest 'a redacted transcript is saved as it is' => sub {
	my $redacted = $transcript =~ s/\Q$old\E|\Q$new\E/<redacted>/gr;
	is($env->_deploy_log_content($redacted, 0), $redacted, 'bosh already redacted the diff');
	is($env->_deploy_log_content(undef, 0), 'No output received', 'and no output is noted');
};

done_testing;
