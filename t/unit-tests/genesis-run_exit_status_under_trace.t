#!/usr/bin/env perl
# run() must report a command's exit code whether or not tracing is on.
#
# It used to read $? only after tracing the command's duration.  With
# GENESIS_TRACE set, that trace call probed the terminal width by running a
# command of its own, which reset $?, so every failing command came back with
# rc 0.  A caller that turned tracing on to debug a failure then saw the
# failure reported as a success.  The test helper pins the output width,
# which skips the probe, so these runs unset it the way a real shell has it.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use Genesis;
use Genesis::Log;

sub rc_of {
	my ($trace, @cmd) = @_;
	my ($rc, $stderr) = (undef, '');
	{
		local $ENV{GENESIS_TRACE} = $trace ? 'y' : '';
		local $ENV{GENESIS_OUTPUT_COLUMNS};
		delete $ENV{GENESIS_OUTPUT_COLUMNS};
		local $Genesis::Log::Logger = undef;
		local *STDERR;
		open STDERR, '>', \$stderr or die "cannot capture stderr: $!";
		(undef, $rc) = run({stderr => 0}, @cmd);
	}
	$Genesis::Log::Logger = undef;
	return ($rc, $stderr);
}

for my $trace (0, 1) {
	my $mode = $trace ? 'with GENESIS_TRACE' : 'without tracing';
	my ($rc) = rc_of($trace, 'bash', '-c', 'exit 3');
	is($rc, 3, "a command that exits 3 reports rc 3 $mode");
	($rc) = rc_of($trace, 'bash', '-c', 'exit 0');
	is($rc, 0, "a command that exits 0 reports rc 0 $mode");
}

my (undef, $stderr) = rc_of(1, 'bash', '-c', 'exit 3');
like($stderr, qr/rc 3/, 'the trace itself names the real exit code');

done_testing;
