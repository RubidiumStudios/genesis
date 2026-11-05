#!perl
# A log file is its owner's alone, mode 0600: the trace log records every
# command Genesis runs, and a file left at the umask's 0644 is readable by
# every account on the machine.  One already standing at a wider mode is
# narrowed the first time it is written.
use strict;
use warnings;
use lib 't';
use helper;
use File::Temp qw/tempdir/;
use Test::More;

use Genesis::Log;

local $ENV{GENESIS_CALLBACK_BIN};   # not in a callback, so the log is kept
umask 022;

sub mode_of { sprintf('%04o', (stat $_[0])[2] & 07777) }

sub logged_to {
	my ($file, %opts) = @_;
	$Genesis::Log::Logger = undef;
	my $logger = Genesis::Log->new();
	$logger->configure_log($file, level => 'TRACE', %opts);
	$logger->trace('a traced line');
	return $logger;
}

subtest 'a new log file is created 0600' => sub {
	my $dir = tempdir(CLEANUP => 1);
	logged_to("$dir/appended.log");
	is(mode_of("$dir/appended.log"), '0600', 'appended to');
	logged_to("$dir/truncated.log", lifespan => 'current');
	is(mode_of("$dir/truncated.log"), '0600', 'and truncated for the current command');
};

subtest 'an existing wider one is narrowed' => sub {
	my $dir = tempdir(CLEANUP => 1);
	helper::put_file("$dir/old.log", "an older run\n");
	chmod 0644, "$dir/old.log";
	logged_to("$dir/old.log");
	is(mode_of("$dir/old.log"), '0600', 'to 0600 when next written');
};

done_testing;
