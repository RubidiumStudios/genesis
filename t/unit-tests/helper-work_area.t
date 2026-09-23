#!/usr/bin/env perl
# Each test process works in a directory of its own under t/tmp, named for
# its pid, so test files can run side by side.  A file starting up removes
# only the work areas whose process is gone, and a file ending removes its
# own.  helper used to clear the whole of t/tmp and stop every suite vault as
# it loaded, which is what made two files at once destroy each other.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use IPC::Open2;
use Genesis qw/mkdir_or_fail/;

my $TMP_ROOT = "$helper::TOPDIR/t/tmp";

# A test file started beside this one: it loads helper, reports its HOME,
# writes a file there, and stays until told to go.
sub start_file {
	my $pid = open2(my $out, my $in, $^X, "-I$helper::TOPDIR/t", '-e', <<'EOS');
use helper;
$| = 1;
open my $fh, '>', "$ENV{HOME}/marker" or die $!;
print $fh "alive\n";
close $fh;
print "$ENV{HOME}\n";
<STDIN>;
EOS
	chomp(my $home = <$out>);
	return {pid => $pid, in => $in, out => $out, home => $home};
}

sub stop_file {
	my ($file) = @_;
	close $file->{in};
	waitpid($file->{pid}, 0);
}

subtest 'this process works in a directory of its own' => sub {
	plan tests => 2;
	is($ENV{HOME}, "$TMP_ROOT/$$/home", 'HOME sits under t/tmp, named for this process');
	ok(-d $ENV{HOME}, 'and it exists');
};

subtest 'a file starting up leaves a running file alone' => sub {
	plan tests => 4;

	my $first = start_file();
	like($first->{home}, qr{^\Q$TMP_ROOT\E/\d+/home$}, 'the first file has its own HOME');

	my $second = start_file();
	isnt($second->{home}, $first->{home}, 'the second file has another');
	ok(-f "$first->{home}/marker",
		"and the second starting left the first file's work area as it was");

	stop_file($_) for $first, $second;
	ok(!-e ($first->{home} =~ s{/home$}{}r),
		'a file that ends takes its own work area with it');
};

subtest 'a work area whose process is gone is swept' => sub {
	plan tests => 2;

	# A pid that is certainly gone: a process that has run and been reaped.
	my $gone = fork // die "fork: $!";
	exit 0 unless $gone;
	waitpid($gone, 0);

	my $stale = "$TMP_ROOT/$gone";
	mkdir_or_fail("$stale/home");
	put_file("$stale/home/leftover", "stale\n");

	stop_file(start_file());
	ok(!-e $stale, 'the next file to start removes it');
	ok(-d "$TMP_ROOT/$$", 'and leaves the running one alone');
};

done_testing;
