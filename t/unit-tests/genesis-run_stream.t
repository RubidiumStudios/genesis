#!/usr/bin/env perl
# run()'s stream option hands a command's output to a callback as it
# arrives and returns it whole, in memory, so a caller can show it live
# with no copy written to disk.  Like any output, it stays out of the trace
# unless marked public.  While the command runs, INT, TERM, and HUP are
# passed on to it instead of ending Genesis, so the command decides how to
# stop, and the caller is told which signal came in.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;

use Genesis;

subtest 'streamed output reaches the callback and the caller, and not the trace' => sub {
	my $value = fake_secret('streamed');
	my ($seen, @results) = ('');
	my $log = capture_trace {
		@results = run({stream => sub {$seen .= $_[0]}},
			'printf "first %s\n" "$1"; printf "second\n"; exit 3', {redact => $value});
	};
	is($seen, "first $value\nsecond\n", 'the callback sees every byte, as printed');
	is($results[0], $seen, 'the caller gets the same output, untrimmed');
	is($results[1], 3, 'and the exit code');
	unlike($log, qr/\Q$value\E/, 'the output is not traced');
	like($log, qr/\[\d+b of redacted data omitted from debug\]/, 'only its size is');
};

subtest 'a signal to Genesis is passed on to the command' => sub {
	my ($signal, $sent, @results) = (undef, 0);
	capture_trace {
		@results = run({
			stream => sub {
				# Signal Genesis itself once the command is waiting.
				kill('INT', $$) if !$sent++ && $_[0] =~ /ready/;
			},
			on_signal => sub {$signal = $_[0]},
		}, q{trap 'echo stopping; exit 130' INT; echo ready; for i in $(seq 1 100); do sleep 0.1; done; echo timed-out});
	};
	is($signal, 'INT', 'the caller is told the run was interrupted');
	is($results[1], 130, 'the command stopped on the signal it was passed');
	like($results[0], qr/stopping/, 'and said so');
	unlike($results[0], qr/timed-out/, 'without running to the end');
};

subtest 'without a signal, the callback is not told of one' => sub {
	my $called = 0;
	my (undef, $rc) = run({stream => sub {}, on_signal => sub {$called++}}, 'true');
	is($rc, 0, 'the command runs');
	is($called, 0, 'and on_signal is not called');
};

subtest 'pty_command sends the typescript to /dev/null' => sub {
	local $^O = 'darwin';
	is_deeply([pty_command('spruce', 'diff', 'a b', 'c|d')],
		['script', '-q', '/dev/null', 'spruce', 'diff', 'a b', 'c|d'],
		'on macOS the arguments follow unchanged');
	local $^O = 'linux';
	is_deeply([pty_command('spruce', 'diff', 'a b', 'c|d')],
		['script', '-qef', '-c', "'spruce' 'diff' 'a b' 'c|d'", '/dev/null'],
		'on Linux the command is quoted into one -c string');
	local $^O = 'freebsd';
	is_deeply([pty_command('spruce', 'diff')], ['spruce', 'diff'], 'elsewhere the command runs as it is');
};

done_testing;
