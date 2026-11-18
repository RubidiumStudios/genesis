#!/usr/bin/env perl
# run({stderr => 0}) captures a command's stderr apart from its output.
# It used to send stderr to a run-*.stderr file in the work directory and
# read it back, which left whatever a failed command printed, credentials
# included, on disk until cleanup, and for good after an abrupt exit.  Both
# streams are now drained through pipes into memory, and run() returns
# them as it always has.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;

use Genesis;

use File::Temp qw/tempdir/;

# What the command's stderr is, as the command sees it.
my $fd2 = 'if [ -f /dev/fd/2 ]; then echo file; elif [ -p /dev/fd/2 ]; then echo pipe; else echo other; fi';

subtest 'no stderr file is written' => sub {
	my $value = fake_secret('stderr');
	my $wd = tempdir(CLEANUP => 1);
	no warnings 'redefine';
	local *Genesis::workdir = sub { $wd };
	use warnings 'redefine';
	my ($out, $rc, $err) = run({stderr => 0},
		"$fd2; echo \"err \$1\" >&2; exit 3", {redact => $value});
	is($out, 'pipe', 'the command writes its stderr to a pipe, not a file');
	is($rc, 3, 'the exit code comes back');
	is($err, "err $value\n", 'and stderr comes back whole, in memory');
	opendir(my $dh, $wd) or die;
	my @left = grep {!/^\.\.?$/} readdir($dh);
	is_deeply(\@left, [], 'and nothing is written to the work directory');
};

subtest 'the return values are as before' => sub {
	my ($out, $rc, $err) = run({stderr => 0}, 'printf "out  \n\n"; printf "e1\ne2\n\n" >&2');
	is($out, 'out', 'output is trimmed of trailing whitespace');
	is($rc, 0, 'a success exits 0');
	is($err, "e1\ne2\n\n", 'stderr is as printed');

	($out, $rc, $err) = run({stderr => 0}, 'printf "quiet"');
	is($err, '', 'a command that prints no stderr gives an empty string, not undef');

	my $scalar = run({stderr => 0}, 'echo some-out; echo some-err >&2; exit 2');
	is($scalar, "some-err\n", 'a failed command in scalar context returns its stderr');
	$scalar = run({stderr => 0}, 'echo some-out; echo some-err >&2');
	is($scalar, 'some-out', 'and a successful one its output');

	($out) = run({stderr => 0, exact => 1}, 'printf "keep\n\n"');
	is($out, "keep\n\n", 'exact keeps the output as printed');

	($out) = run({stderr => 0, stdin => "from stdin\n"}, 'cat');
	is($out, 'from stdin', 'stdin still reaches the command');
};

subtest 'large output on both streams does not stall' => sub {
	my ($out, $rc, $err) = run({stderr => 0},
		'for i in $(seq 1 4000); do echo "out line $i of a long run"; echo "err line $i of a long run" >&2; done');
	is($rc, 0, 'the command finishes');
	is(scalar(() = $out =~ /^out line/mg), 4000, 'every line of output arrives');
	is(scalar(() = $err =~ /^err line/mg), 4000, 'and every line of stderr');
};

subtest 'a signal and a streamed run still report stderr' => sub {
	my ($out, $rc, $err) = run({stderr => 0}, 'echo dying >&2; kill -TERM $$');
	is($rc, 143, 'a command killed by TERM reports 128 + 15');
	like($err, qr/\Adying\nkilled by signal 15\z/, 'and stderr says so after what it printed');

	my $seen = '';
	($out, $rc, $err) = run({stderr => 0, stream => sub {$seen .= $_[0]}},
		"$fd2; echo streamed; echo apart >&2");
	is($seen, "pipe\nstreamed\n", 'a streamed command writes stderr to a pipe, and its output reaches the callback');
	is($err, "apart\n", 'and its stderr is kept apart, in memory');
};

subtest 'private stderr stays out of the trace' => sub {
	my $value = fake_secret('stderr-trace');
	my $log = capture_trace {
		run({stderr => 0}, 'echo "$1" >&2; exit 1', {redact => $value});
	};
	unlike($log, qr/\Q$value\E/, 'the stderr value is not traced');
	unlike($log, qr/run-\d+\.stderr/, 'and no stderr file is named');
};

done_testing;
