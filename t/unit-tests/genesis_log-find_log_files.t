#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;
use File::Temp qw/tempdir/;
use File::Spec;
use Cwd qw/abs_path/;

# Tempdir paths may include unresolved symlinks (macOS /var -> /private/var).
# Genesis::expand_path canonicalises via Cwd::abs_path; tests use the same.
sub mktmp { abs_path(tempdir(CLEANUP => 1)) }

use_ok 'Genesis::Log';

# ===========================================================================
# template_to_glob_pattern($template, %concrete)
# find_log_files($template, %concrete)
#
# Pure file-discovery primitives.
# ===========================================================================

sub glob_for { Genesis::Log::template_to_glob_pattern(@_) }
sub find     { Genesis::Log::find_log_files(@_) }

# ---------- digit-pattern wildcards ----------

my $TS_PATTERN = '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9]Z';
my $DATE_PATTERN = '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]';
my $TIME_PATTERN = '[0-9][0-9][0-9][0-9][0-9][0-9]';
my $PID_PATTERN = '[0-9]*';

# ===========================================================================
# template_to_glob_pattern
# ===========================================================================

subtest 'literal path: no vars => returned as-is' => sub {
	plan tests => 1;
	my $tmp = mktmp();
	is glob_for("$tmp/last-trace"), "$tmp/last-trace",
		'no template vars => path returned unchanged';
};

subtest '{timestamp} expands to digit pattern' => sub {
	plan tests => 1;
	my $tmp = mktmp();
	is glob_for("$tmp/{timestamp}.log"), "$tmp/$TS_PATTERN.log",
		'{timestamp} => YYYYMMDDTHHMMSS.mmmZ digit pattern';
};

subtest '{date} expands to 8-digit pattern' => sub {
	plan tests => 1;
	my $tmp = mktmp();
	is glob_for("$tmp/{date}.log"), "$tmp/$DATE_PATTERN.log",
		'{date} => YYYYMMDD digit pattern';
};

subtest '{time} expands to 6-digit pattern' => sub {
	plan tests => 1;
	my $tmp = mktmp();
	is glob_for("$tmp/{time}.log"), "$tmp/$TIME_PATTERN.log",
		'{time} => HHMMSS digit pattern';
};

subtest '{pid} expands to variable-length numeric wildcard' => sub {
	plan tests => 1;
	my $tmp = mktmp();
	is glob_for("$tmp/{pid}.log"), "$tmp/$PID_PATTERN.log",
		'{pid} => variable-length [0-9]* pattern';
};

subtest '{env} and {command} default to bare * wildcard' => sub {
	plan tests => 2;
	my $tmp = mktmp();
	is glob_for("$tmp/{env}/log"), "$tmp/*/log",
		'{env} without concrete => *';
	is glob_for("$tmp/{command}/log"), "$tmp/*/log",
		'{command} without concrete => *';
};

subtest '%concrete substitutes specific vars; others stay wildcards' => sub {
	plan tests => 2;
	my $tmp = mktmp();
	is glob_for("$tmp/{env}/{command}/{timestamp}.log", env => 'staging'),
		"$tmp/staging/*/$TS_PATTERN.log",
		'env=staging substituted; command stays *';
	is glob_for("$tmp/{env}/{command}/{timestamp}.log",
		env => 'staging', command => 'deploy'),
		"$tmp/staging/deploy/$TS_PATTERN.log",
		'env and command both substituted; timestamp stays as digit pattern';
};

subtest 'tilde expansion resolves to $HOME' => sub {
	plan tests => 1;
	is glob_for('~/.genesis/{timestamp}.log'),
		"$ENV{HOME}/.genesis/$TS_PATTERN.log",
		'~ resolved to $HOME; rest of pattern preserved';
};

# ===========================================================================
# find_log_files
# ===========================================================================

# Helper to create a test file with a controllable mtime
sub make_log {
	my ($path, $age_seconds) = @_;
	open my $fh, '>', $path or die "Cannot create $path: $!";
	print $fh "test log\n";
	close $fh;
	if (defined $age_seconds) {
		my $mtime = time() - $age_seconds;
		utime($mtime, $mtime, $path) or die "utime $path: $!";
	}
}

subtest 'find_log_files returns matching files with path and mtime' => sub {
	plan tests => 4;
	my $tmp = mktmp();
	make_log("$tmp/20260601T100000.000Z.log", 86400);
	make_log("$tmp/20260602T100000.000Z.log", 0);
	make_log("$tmp/notalog.txt",              0);   # different extension

	my $files = find("$tmp/{timestamp}.log");
	is scalar(@$files), 2, 'found 2 matching .log files';
	ok defined($files->[0]{path}),  'first result has path';
	ok defined($files->[0]{mtime}), 'first result has mtime';
	ok((grep { $_->{path} =~ /notalog\.txt/ } @$files) == 0,
		'non-matching extension excluded');
};

subtest 'find_log_files sorts by mtime descending (newest first)' => sub {
	plan tests => 2;
	my $tmp = mktmp();
	make_log("$tmp/20260601T100000.000Z.log", 86400 * 3);  # 3 days old
	make_log("$tmp/20260602T100000.000Z.log", 86400);      # 1 day old
	make_log("$tmp/20260603T100000.000Z.log", 0);          # current

	my $files = find("$tmp/{timestamp}.log");
	is scalar(@$files), 3, 'all 3 files discovered';
	cmp_ok $files->[0]{mtime}, '>', $files->[-1]{mtime},
		'first file is newer than last (descending sort)';
};

subtest 'find_log_files skips directories' => sub {
	plan tests => 1;
	my $tmp = mktmp();
	make_log("$tmp/20260601T100000.000Z.log", 0);
	mkdir "$tmp/20260602T100000.000Z.log" or die "mkdir: $!";

	my $files = find("$tmp/{timestamp}.log");
	is scalar(@$files), 1, 'directory matching the glob is skipped';
};

subtest 'find_log_files: empty result when nothing matches' => sub {
	plan tests => 1;
	my $tmp = mktmp();
	make_log("$tmp/different-name.log", 0);

	my $files = find("$tmp/{timestamp}.log");
	is scalar(@$files), 0, 'no matches => empty arrayref';
};

subtest 'find_log_files: %concrete narrows the glob' => sub {
	plan tests => 2;
	my $tmp = mktmp();
	mkdir "$tmp/staging"   or die "mkdir staging: $!";
	mkdir "$tmp/prod"      or die "mkdir prod: $!";
	make_log("$tmp/staging/20260601T100000.000Z.log", 86400);
	make_log("$tmp/staging/20260602T100000.000Z.log", 0);
	make_log("$tmp/prod/20260601T100000.000Z.log",    0);

	my $broad = find("$tmp/{env}/{timestamp}.log");
	is scalar(@$broad), 3, 'broad glob finds all 3 files across envs';

	my $scoped = find("$tmp/{env}/{timestamp}.log", env => 'staging');
	is scalar(@$scoped), 2, 'env=staging scopes results to 2 files';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
