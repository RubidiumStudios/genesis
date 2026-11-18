#!/usr/bin/env perl
# A private entry is detail an operator asked to see, such as a config
# diff, that can carry a credential.  Log files never get it.  The terminal
# sink shows it only when it really is a terminal: redirected, as in CI,
# the output is a file or a pipe that someone keeps, so a one-line note
# says the detail was withheld and why.  A data entry, which is what a
# command such as lookup was asked to print on stdout, still goes wherever
# stdout goes.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;

use Genesis;

my $note = qr/<\d+ bytes of detail withheld because this output is not a terminal>/;

subtest 'off a terminal, private detail is withheld' => sub {
	my $value = fake_secret('private-info');
	my ($log, $stderr) = capture_trace { Genesis::info({private => 1}, "diff: %s", $value) };
	unlike($stderr, qr/\Q$value\E/, 'a redirected stderr does not get the detail');
	like($stderr, $note, 'it gets a note that says why, instead');
	unlike($log, qr/\Q$value\E/, 'and the log file does not get it either');

	$value = fake_secret('private-output');
	my $stdout;
	($log, $stderr, $stdout) = capture_trace { Genesis::output({raw => 1, private => 1}, $value) };
	unlike($stdout, qr/\Q$value\E/, 'a redirected stdout does not get private output');
	like($stdout, $note, 'it gets the note');
};

subtest 'on a terminal, private detail is shown' => sub {
	my $value = fake_secret('private-tty');
	no warnings qw/redefine once/;
	local *Genesis::Log::_is_terminal = sub { 1 };
	my ($log, $stderr) = capture_trace { Genesis::info({private => 1}, "diff: %s", $value) };
	like($stderr, qr/diff: \Q$value\E/, 'the terminal shows the detail');
	unlike($stderr, $note, 'with no note');
	unlike($log, qr/\Q$value\E/, 'and the log file still does not get it');
};

subtest 'a data request reaches stdout wherever it goes' => sub {
	my $value = fake_secret('data');
	my ($log, $stderr, $stdout) = capture_trace { Genesis::output({raw => 1, private => 1, data => 1}, $value) };
	like($stdout, qr/\Q$value\E/, 'a redirected stdout gets the data asked for');
	unlike($stdout, $note, 'with no note');
	unlike($log, qr/\Q$value\E/, 'and the log file does not get it');
};

subtest 'each handle is judged on its own' => sub {
	my $value = fake_secret('split');
	no warnings qw/redefine once/;
	local *Genesis::Log::_is_terminal = sub { fileno($_[0]) == fileno(\*STDOUT) };
	my ($log, $stderr, $stdout) = capture_trace {
		Genesis::info({private => 1}, "on stderr %s", $value);
		Genesis::output({raw => 1, private => 1}, "on stdout $value");
	};
	unlike($stderr, qr/\Q$value\E/, 'stderr, not a terminal, withholds');
	like($stdout, qr/on stdout \Q$value\E/, 'stdout, a terminal, shows');
};

done_testing;
