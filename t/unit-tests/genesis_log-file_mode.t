#!/usr/bin/env perl
# Log files are created readable by their owner alone.  A trace holds
# command lines, vault paths, and environment names even with every
# credential scrubbed, so whatever the umask, a log file is created with
# mode 0600, and an existing one that others can read is narrowed to 0600
# the first time it is written.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;
use File::Temp qw/tempdir/;
use Cwd qw/abs_path/;

use Genesis;
use Genesis::Log;

my $dir = abs_path(tempdir(CLEANUP => 1));
umask 022;

sub mode_of { sprintf('%04o', (stat($_[0]))[2] & 07777) }

sub with_logger(&) {
	my ($code) = @_;
	local $Genesis::Log::Logger = undef;
	local $ENV{GENESIS_ACTIVE_LOG_0};
	local %ENV = %ENV;
	delete @ENV{grep {/^GENESIS_ACTIVE_LOG_\d+$/} keys %ENV};
	my $logger = Genesis::Log->new();
	$logger->configure_log('<terminal>', level => 'ERROR');
	$code->($logger);
}

subtest 'a new log file is created with mode 0600' => sub {
	my $file = "$dir/new.log";
	with_logger {
		my $logger = shift;
		$logger->configure_log($file, level => 'TRACE');
		$logger->trace("a line for the log");
	};
	ok(-f $file, 'the log was written');
	is(mode_of($file), '0600', 'the log is readable by its owner alone');
};

subtest 'a log configured with lifespan current is created with mode 0600' => sub {
	my $file = "$dir/current.log";
	with_logger {
		my $logger = shift;
		$logger->configure_log($file, level => 'TRACE', lifespan => 'current');
		is(mode_of($file), '0600', 'the emptied log is readable by its owner alone');
		$logger->trace("a line for the log");
	};
	is(mode_of($file), '0600', 'it stays that way once written');
};

subtest 'an existing log that others can read is narrowed to 0600' => sub {
	my $file = "$dir/existing.log";
	put_file($file, 0644, "an older line\n");
	chmod 0644, $file;
	with_logger {
		my $logger = shift;
		$logger->configure_log($file, level => 'TRACE');
		$logger->trace("a line for the log");
	};
	is(mode_of($file), '0600', 'the log is readable by its owner alone');
	like(Genesis::slurp($file), qr/an older line/, 'the older content is kept');
};

subtest 'last-trace from the logs configuration is created with mode 0600' => sub {
	my $home = "$dir/home";
	mkdir $home;
	mkdir "$home/.genesis";
	local $ENV{HOME} = $home;
	with_logger {
		Genesis::Log->setup_from_configs([{level => 'TRACE'}]);
		Genesis::Log->new->trace("a line for the log");
	};
	ok(-f "$home/.genesis/last-trace", 'last-trace was written');
	is(mode_of("$home/.genesis/last-trace"), '0600', 'last-trace is readable by its owner alone');
};

subtest 'an existing last-trace that others can read is narrowed to 0600' => sub {
	my $home = "$dir/home2";
	mkdir $home;
	mkdir "$home/.genesis";
	put_file("$home/.genesis/last-trace", 0644, "an older trace\n");
	chmod 0644, "$home/.genesis/last-trace";
	local $ENV{HOME} = $home;
	with_logger {
		Genesis::Log->setup_from_configs([{level => 'TRACE'}]);
		Genesis::Log->new->trace("a line for the log");
	};
	is(mode_of("$home/.genesis/last-trace"), '0600', 'last-trace is readable by its owner alone');
};

done_testing;
