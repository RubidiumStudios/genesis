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
use Cwd qw/abs_path/;

sub mktmp { abs_path(tempdir(CLEANUP => 1)) }

use_ok 'Genesis::Log';

# ===========================================================================
# cleanup_old_logs($log_config, %opts) -> { deleted, errors }
#
# Side-effect-ful orchestrator: composes parse_lifespan + find_log_files +
# apply_retention_policy and unlinks the resulting files.  Tolerant of
# failures - never bails, always returns.
# ===========================================================================

sub cleanup { Genesis::Log::cleanup_old_logs(@_) }

# Create a file with a controllable mtime
sub make_log {
	my ($path, $age_seconds) = @_;
	open my $fh, '>', $path or die "Cannot create $path: $!";
	print $fh "test\n";
	close $fh;
	if (defined $age_seconds) {
		my $mtime = time() - $age_seconds;
		utime($mtime, $mtime, $path) or die "utime $path: $!";
	}
	$path;
}

# Build a populated tempdir of timestamped logs, oldest first by age
sub make_tempdir_with_logs {
	my ($n) = @_;
	my $tmp = mktmp();
	my @paths;
	for my $i (0 .. $n - 1) {
		my $age = ($n - 1 - $i) * 86400;  # i=0 oldest, i=n-1 newest
		my $path = "$tmp/2026060${i}T000000.000Z.log";
		make_log($path, $age);
		push @paths, $path;
	}
	($tmp, \@paths);
}

# ---------- no-op shapes ----------

subtest 'missing file or lifespan => no-op' => sub {
	plan tests => 3;
	cmp_deeply cleanup({}), { deleted => [], errors => [] },
		'empty config => no-op';
	cmp_deeply cleanup({ file => '/tmp/foo' }), { deleted => [], errors => [] },
		'no lifespan => no-op';
	cmp_deeply cleanup({ lifespan => '5' }), { deleted => [], errors => [] },
		'no file => no-op';
};

subtest 'lifespan: forever => no deletes' => sub {
	plan tests => 2;
	my ($tmp, $paths) = make_tempdir_with_logs(5);
	my $result = cleanup({
		file     => "$tmp/{timestamp}.log",
		lifespan => 'forever',
	});
	cmp_deeply $result->{deleted}, [], 'forever => empty delete list';
	is scalar(grep { -f $_ } @$paths), 5, 'all 5 files still present';
};

# ---------- count-based cleanup ----------

subtest 'lifespan: 5 against 7 files deletes 2 oldest' => sub {
	plan tests => 3;
	my ($tmp, $paths) = make_tempdir_with_logs(7);
	my $result = cleanup({
		file     => "$tmp/{timestamp}.log",
		lifespan => '5',
	});
	is scalar(@{$result->{deleted}}), 2, '2 files deleted';
	is scalar(grep { -f $_ } @$paths), 5, '5 files remain on disk';
	ok( !(-f $paths->[0]), 'oldest (index 0) was unlinked' );
};

# ---------- active_path protection ----------

subtest 'active_path is never deleted even when in retention drop set' => sub {
	plan tests => 3;
	my ($tmp, $paths) = make_tempdir_with_logs(7);
	# Pick the OLDEST file as "active" - it would normally be deleted
	# under lifespan: 5 (since it's in the oldest 2)
	my $active = $paths->[0];
	my $result = cleanup(
		{ file => "$tmp/{timestamp}.log", lifespan => '5' },
		active_path => $active,
	);
	ok( -f $active, 'active_path file preserved on disk' );
	ok( !(grep { $_ eq $active } @{$result->{deleted}}),
		'active_path absent from delete list' );
	# 6 files now remain instead of 5 (active protected; only 1 deleted)
	is scalar(grep { -f $_ } @$paths), 6,
		'one fewer deletion happened due to active_path protection';
};

# ---------- reserve_slots ----------

subtest 'reserve_slots shrinks effective count budget' => sub {
	plan tests => 2;
	my ($tmp, $paths) = make_tempdir_with_logs(5);
	my $result = cleanup(
		{ file => "$tmp/{timestamp}.log", lifespan => '5' },
		reserve_slots => 1,
	);
	# count=5 with reserve=1 => effective budget = 4 => delete 1 (the oldest)
	is scalar(@{$result->{deleted}}), 1,
		'reserve_slots=1 drops effective budget by 1';
	is scalar(grep { -f $_ } @$paths), 4, '4 files remain on disk';
};

subtest 'reserve_slots floored at zero' => sub {
	plan tests => 1;
	my ($tmp, $paths) = make_tempdir_with_logs(3);
	my $result = cleanup(
		{ file => "$tmp/{timestamp}.log", lifespan => '5' },
		reserve_slots => 100,   # huge; would underflow naively
	);
	# Effective count = max(0, 5-100) = 0 => delete all
	is scalar(@{$result->{deleted}}), 3,
		'reserve_slots underflow floored at 0 => delete everything';
};

# ---------- error tolerance ----------

subtest 'invalid lifespan string: records error, does not bail' => sub {
	plan tests => 3;
	my ($tmp, $paths) = make_tempdir_with_logs(3);
	my $result;
	lives_ok {
		$result = cleanup({
			file     => "$tmp/{timestamp}.log",
			lifespan => 'not a valid expression',
		});
	} 'parser failure does not propagate';
	cmp_deeply $result->{deleted}, [], 'no deletes attempted';
	ok scalar(@{$result->{errors}}) > 0,
		'parse error recorded in errors list';
};

subtest 'unlink failure: records error, continues with rest' => sub {
	plan tests => 3;
	my ($tmp, $paths) = make_tempdir_with_logs(5);
	# Stub Genesis::Log::_unlink to fail for one specific file
	my $target = $paths->[0];
	{
		no warnings 'redefine';
		*Genesis::Log::_unlink = sub {
			my ($p) = @_;
			return 0 if $p eq $target;
			return CORE::unlink($p);
		};
	}
	my $result = cleanup({
		file     => "$tmp/{timestamp}.log",
		lifespan => '3',
	});
	# count=3 against 5 files: 2 deletes attempted (the 2 oldest)
	# One fails (target), one succeeds
	is scalar(@{$result->{deleted}}), 1, '1 successful delete';
	ok scalar(@{$result->{errors}}) > 0, 'unlink failure recorded';
	ok( -f $target, 'target file still present after failed unlink' );

	# Restore real unlink for other tests
	no warnings 'redefine';
	*Genesis::Log::_unlink = sub { CORE::unlink($_[0]) };
};

# ---------- concrete substitution narrows the family ----------

subtest 'concrete substitution narrows cleanup to a per-group family' => sub {
	plan tests => 3;
	my $tmp = mktmp();
	mkdir "$tmp/staging" or die "mkdir staging: $!";
	mkdir "$tmp/prod"    or die "mkdir prod: $!";
	make_log("$tmp/staging/20260601T000000.000Z.log", 3 * 86400);
	make_log("$tmp/staging/20260602T000000.000Z.log", 86400);
	make_log("$tmp/staging/20260603T000000.000Z.log", 0);
	make_log("$tmp/prod/20260601T000000.000Z.log",    3 * 86400);

	my $result = cleanup(
		{ file => "$tmp/{env}/{timestamp}.log", lifespan => '2' },
		concrete => { env => 'staging' },
	);
	is scalar(@{$result->{deleted}}), 1,
		'staging scope deletes 1 (3 files - lifespan 2 = 1 oldest)';
	ok( !(-f "$tmp/staging/20260601T000000.000Z.log"),
		'oldest staging file unlinked' );
	ok( (-f "$tmp/prod/20260601T000000.000Z.log"),
		'prod files untouched (outside concrete scope)' );
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
