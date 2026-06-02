#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use File::Temp qw/tempdir/;
use Cwd qw/abs_path/;

sub mktmp { abs_path(tempdir(CLEANUP => 1)) }

use_ok 'Genesis::Log';

# ===========================================================================
# apply_on_reuse($path, $mode)
#
# Filesystem action that runs BEFORE log content is written.  Handles
# the collision behavior when the realized log path already exists.
# ===========================================================================

sub apply { Genesis::Log::apply_on_reuse(@_) }

sub make_file {
	my ($path, $content, $age_seconds) = @_;
	$content //= "test\n";
	open my $fh, '>', $path or die "open $path: $!";
	print $fh $content;
	close $fh;
	if (defined $age_seconds) {
		my $mtime = time() - $age_seconds;
		utime($mtime, $mtime, $path) or die "utime $path: $!";
	}
	$path;
}

sub mtime_of { (stat $_[0])[9] }

# ---------- truncate mode ----------

subtest 'truncate: existing file zeros its size, file persists' => sub {
	plan tests => 3;
	my $tmp = mktmp();
	my $path = make_file("$tmp/log", "some content here\n");
	my $result = apply($path, 'truncate');
	is $result->{action}, 'truncated', "result action = 'truncated'";
	ok( -e $path,            'file still exists' );
	is -s $path, 0,          'file size is 0 after truncate';
};

subtest 'truncate: non-existent path => no-op' => sub {
	plan tests => 2;
	my $tmp = mktmp();
	my $result = apply("$tmp/never-existed.log", 'truncate');
	is $result->{action}, 'none',  "no action taken";
	ok( !(-e "$tmp/never-existed.log"), 'file still does not exist' );
};

# ---------- append mode ----------

subtest 'append: existing file untouched' => sub {
	plan tests => 3;
	my $tmp = mktmp();
	my $path = make_file("$tmp/log", "existing content\n");
	my $size_before = -s $path;
	my $result = apply($path, 'append');
	is $result->{action}, 'none', "no filesystem action";
	is -s $path, $size_before, 'file size unchanged';
	ok( -e $path, 'file still exists' );
};

subtest 'append: non-existent path => no-op' => sub {
	plan tests => 1;
	my $tmp = mktmp();
	my $result = apply("$tmp/foo.log", 'append');
	is $result->{action}, 'none', "no action";
};

# ---------- rotate mode ----------

subtest 'rotate: existing file with no archives creates .1 with preserved mtime' => sub {
	plan tests => 5;
	my $tmp = mktmp();
	my $path = make_file("$tmp/log", "original\n", 3600);  # 1h old
	my $original_mtime = mtime_of($path);
	my $result = apply($path, 'rotate');
	is $result->{action}, 'rotated', "action = 'rotated'";
	is $result->{archives_shifted}, 0, "no pre-existing archives shifted";
	ok( !(-e $path), 'original path no longer exists (renamed to .1)' );
	ok( (-e "$path.1"), '.1 archive present' );
	is mtime_of("$path.1"), $original_mtime,
		'.1 archive preserves the original mtime';
};

subtest 'rotate: cascades existing .1 to .2, .2 to .3, etc.' => sub {
	plan tests => 9;
	my $tmp = mktmp();
	my $path = make_file("$tmp/log",   "current\n",  60);
	make_file("$path.1", "archive 1\n", 3600);
	make_file("$path.2", "archive 2\n", 7200);
	make_file("$path.3", "archive 3\n", 10800);

	my @before_mtimes = map { mtime_of($_) } ($path, "$path.1", "$path.2", "$path.3");

	my $result = apply($path, 'rotate');
	is $result->{action}, 'rotated', "action = 'rotated'";
	is $result->{archives_shifted}, 3, "3 archives shifted";

	ok( !(-e $path),       'original path gone' );
	ok( (-e "$path.1"),    '.1 present (was current)' );
	ok( (-e "$path.2"),    '.2 present (was .1)' );
	ok( (-e "$path.3"),    '.3 present (was .2)' );
	ok( (-e "$path.4"),    '.4 present (was .3)' );

	# mtime preservation: each new .N matches the old mtime of (N-1) or current
	is mtime_of("$path.1"), $before_mtimes[0], '.1 mtime matches original current';
	is mtime_of("$path.4"), $before_mtimes[3], '.4 mtime matches original .3';
};

subtest 'rotate: non-existent path => no-op' => sub {
	plan tests => 2;
	my $tmp = mktmp();
	my $result = apply("$tmp/never.log", 'rotate');
	is $result->{action}, 'none', "no action";
	ok( !(-e "$tmp/never.log"),     'file still does not exist' );
};

# ---------- default mode + unknown mode ----------

subtest 'undef mode defaults to truncate' => sub {
	plan tests => 1;
	my $tmp = mktmp();
	my $path = make_file("$tmp/log", "content\n");
	my $result = apply($path, undef);
	is $result->{action}, 'truncated', "undef mode treated as truncate";
};

subtest 'unknown mode is treated as truncate' => sub {
	plan tests => 1;
	my $tmp = mktmp();
	my $path = make_file("$tmp/log", "content\n");
	my $result = apply($path, 'bogus-mode');
	is $result->{action}, 'truncated', "unknown mode falls back to truncate";
};

# ---------- error tolerance ----------

subtest 'rotate: rename failure recorded; does not bail' => sub {
	plan tests => 2;
	my $tmp = mktmp();
	my $path = make_file("$tmp/log", "content\n");
	# Stub _rename to fail
	{
		no warnings 'redefine';
		*Genesis::Log::_rename = sub { 0 };  # simulate failure
	}
	my $result = apply($path, 'rotate');
	ok defined($result->{error}), 'error recorded on rename failure';
	is $result->{action}, 'none', 'action falls back to none on failure';

	# Restore real rename
	no warnings 'redefine';
	*Genesis::Log::_rename = sub { CORE::rename($_[0], $_[1]) };
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
