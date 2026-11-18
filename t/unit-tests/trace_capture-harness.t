#!/usr/bin/env perl
# The privacy tests rest on capture_trace, so it must see everything that
# could carry a leak.  A child process writes to file descriptors 1 and
# 2, not to Perl's STDOUT and STDERR handles, so capture_trace has to
# capture the descriptors.  And each capture starts with an empty secret
# registry, so a value registered by an earlier test cannot hide a leak
# in a later one.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;

use Genesis;
use Genesis::Log;

subtest 'a child process\'s streams are captured' => sub {
	my ($out, $err) = map {fake_secret("child-$_")} qw/out err/;
	my ($log, $stderr, $stdout) = capture_trace {
		system('/bin/sh', '-c', 'printf "%s\n" "$1"; printf "%s\n" "$2" >&2', 'sh', $out, $err);
	};
	like($stdout, qr/^\Q$out\E$/m, 'what the child writes to stdout is captured');
	like($stderr, qr/^\Q$err\E$/m, 'what the child writes to stderr is captured');
};

subtest 'Perl\'s own handles are captured as before' => sub {
	my ($log, $stderr, $stdout) = capture_trace {
		print STDOUT "perl-stdout\n";
		print STDERR "perl-stderr\n";
	};
	like($stdout, qr/^perl-stdout$/m, 'print STDOUT is captured');
	like($stderr, qr/^perl-stderr$/m, 'print STDERR is captured');
};

subtest 'a capture that dies still restores the streams' => sub {
	my $ok = eval { capture_trace { die "inside the capture\n" }; 1 };
	ok(!$ok, 'the exception is passed on');
	like($@, qr/inside the capture/, 'unchanged');
	my ($log, $stderr) = capture_trace { system('/bin/sh', '-c', 'echo after >&2') };
	like($stderr, qr/^after$/m, 'and a later capture still works');
};

subtest 'each capture starts with an empty registry' => sub {
	my $value = fake_secret('registry');
	capture_trace { my ($logger) = @_; $logger->register_secret($value, 'earlier') };
	my $log = capture_trace { trace("unregistered %s", $value) };
	like($log, qr/\Q$value\E/,
		'a value registered in an earlier capture is not scrubbed in a later one');
};

done_testing;
