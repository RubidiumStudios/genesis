#!/usr/bin/env perl
# A process killed by a signal has no exit code, so reading $? >> 8 alone
# turns a killed command into one that exited 0.  run() must report it as
# a failure, 128 plus the signal number as a shell would, whatever the
# capture policy: captured, interactive, pass/fail, or exact.  A kit hook
# runs interactively, so a pre-deploy hook killed by a signal must not
# let a deploy go ahead.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;

use Genesis;

# `exec kill` replaces the shell run() starts, so the shell itself is the
# process that dies of the signal.
my $killed = 'exec /bin/kill -TERM $$';

subtest 'a captured command' => sub {
	my ($out, $rc);
	capture_trace { ($out, $rc) = run({stderr => 0}, $killed) };
	is($rc, 128 + 15, 'reports 128 plus the signal');
};

subtest 'an interactive command' => sub {
	my $rc;
	capture_trace { (undef, $rc) = run({interactive => 1}, $killed) };
	is($rc, 128 + 15, 'reports 128 plus the signal');
};

subtest 'a pass/fail command' => sub {
	my $ok;
	capture_trace { $ok = run({passfail => 1}, $killed) };
	ok(!$ok, 'fails');
};

subtest 'a command with stderr left alone' => sub {
	my ($out, $rc);
	capture_trace { ($out, $rc) = run({stderr => undef}, $killed) };
	is($rc, 128 + 15, 'reports 128 plus the signal');
};

subtest 'the trace names the signal' => sub {
	my $log = capture_trace { run({interactive => 1}, $killed) };
	like($log, qr/killed by signal 15/, 'the signal is traced');
};

done_testing;
