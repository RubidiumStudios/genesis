#!/usr/bin/env perl
# Proves T514 (D180): the help flags.  -h is counted, so -hh shows a command's
# help with the global options beside it, and --help-globals shows the global
# options alone.  --globals is gone, so the name is free for a command to use,
# and one given it is told so as it is for any option it does not take.
#
# --globals was a global option, read on every command before the command saw
# its own, so no command could carry an option of that name or one it
# abbreviates.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 120;

my $h = make_harness(envs => ['qa']);

# What the command printed, on both streams, and what it exited.
sub said {
	my (@args) = @_;
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, @args);
	return ("$out\n$err", $exit);
}

my $GLOBAL  = qr/Enable \[or disable\] color output/; # a global option's own description
my $PING    = qr/ping - Check if genesis binary is present/;
my $LISTING = qr/grouped by function areas/;         # the general help's own words

subtest '-h shows the command alone, and says how to see more' => sub {
	my ($text, $exit) = said('ping', '-h');
	is($exit, 0, 'exits 0');
	like($text, $PING, 'the command\'s help');
	unlike($text, $GLOBAL, 'without the global options');
	like($text, qr/-hh/, 'naming -hh for them');
	like($text, qr/--help-globals/, 'and --help-globals for the global options alone');
	unlike($text, qr/--globals\b/, 'and no longer --globals');
};

subtest '-h given twice adds the global options' => sub {
	for my $args (['-hh'], ['-h', '-h'], ['--help', '--help'], ['-h', '--help']) {
		my ($text, $exit) = said('ping', @$args);
		is($exit, 0, "@$args exits 0");
		like($text, $PING, "@$args shows the command's help");
		like($text, $GLOBAL, "@$args with the global options");
	}
};

subtest 'the long forms still show both' => sub {
	for my $flag (qw/--help-full --helpful/) {
		my ($text, $exit) = said('ping', $flag);
		is($exit, 0, "$flag exits 0");
		like($text, $PING, "$flag shows the command's help");
		like($text, $GLOBAL, "$flag with the global options");
	}
};

subtest '--help-globals shows the global options alone' => sub {
	my ($text, $exit) = said('ping', '--help-globals');
	is($exit, 0, 'exits 0');
	like($text, $GLOBAL, 'the global options');
	unlike($text, $PING, 'and not the command\'s help');
	like($text, qr/--help-globals/, 'which list the flag itself');
	unlike($text, qr/--globals\b/, 'and no --globals');
};

# The screen and the code, not the line naming the option: command_usage
# prints that line only when the process is not under test.
subtest '--globals is no longer taken from a command' => sub {
	for my $cmd (qw/ping secrets-provider/) {
		my ($text, $exit) = said($cmd, '--globals');
		is($exit, 2, "$cmd --globals is a usage error");
		like($text, qr/^Usage: \S* ?\Q$cmd\E\b/m, 'answered with the command\'s own usage');
		unlike($text, $GLOBAL, 'and the global options are not listed in its place');
	}

	# config is the command that now carries the name, for the user-level
	# configuration (D181).
	my ($text, $exit) = said('config', '--globals');
	is($exit, 0, 'config --globals is the command\'s own option');
	like($text, qr/^output_style:/m, 'and prints the user-level configuration');
	unlike($text, $GLOBAL, 'not the global options');
};

subtest 'with no command' => sub {
	my ($text, $exit) = said('-h');
	is($exit, 0, '-h exits 0');
	like($text, $LISTING, '-h lists the commands');
	unlike($text, $GLOBAL, 'without the global options');

	($text, $exit) = said('-hh');
	is($exit, 0, '-hh exits 0');
	like($text, $LISTING, '-hh lists the commands');
	like($text, $GLOBAL, 'and the global options after them');

	($text, $exit) = said('--help-globals');
	is($exit, 0, '--help-globals exits 0');
	like($text, $GLOBAL, '--help-globals shows the global options');
	unlike($text, $LISTING, 'and no command listing');

	($text, $exit) = said('help', '--help-globals');
	is($exit, 0, 'help --help-globals exits 0');
	like($text, $GLOBAL, 'and shows the same');
};

done_testing;
