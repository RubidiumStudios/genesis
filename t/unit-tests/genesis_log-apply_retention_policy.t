#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use_ok 'Genesis::Log';

# ===========================================================================
# apply_retention_policy($files, $policy)
#
# Pure decision function: given file metadata + parsed policy, returns
# the list of files to delete.
#
# Inputs:
#   $files  - arrayref of { path, mtime } hashrefs
#   $policy - hashref as produced by parse_lifespan
#
# Output: arrayref of file hashrefs to delete (subset of $files)
# ===========================================================================

sub apply { Genesis::Log::apply_retention_policy(@_) }

# Build a synthetic file list: $n files spaced 1 day apart, newest first
# at index 0, oldest at the end.  mtimes anchored to a fixed reference
# so tests are deterministic across runs.
my $NOW = 1717286400;  # 2024-06-02T00:00:00Z, arbitrary fixed anchor

sub make_files {
	my ($n) = @_;
	[ map { { path => "/tmp/$_.log", mtime => $NOW - $_ * 86400 } } 0 .. $n - 1 ]
}

# Convenience: build a policy hash
sub p {
	my (%h) = @_;
	+{
		mode        => $h{mode}        // 'union',
		count       => $h{count}       // undef,
		age_seconds => $h{age_seconds} // undef,
		warnings    => [],
	}
}

# Stub time() so age-based tests are deterministic.
{
	no warnings 'redefine';
	*Genesis::Log::_now = sub { $NOW };
}

# ---------- mode: none (forever) ----------

subtest 'mode=none keeps all files; empty delete list' => sub {
	plan tests => 2;
	cmp_deeply apply([], p(mode => 'none')), [],
		'empty input + mode=none => empty delete list';
	cmp_deeply apply(make_files(5), p(mode => 'none')), [],
		'5 files + mode=none => empty delete list (forever)';
};

# ---------- mode: truncate (reserved for forward compat) ----------

subtest 'mode=truncate is a no-op for the cleanup path' => sub {
	plan tests => 1;
	cmp_deeply apply(make_files(3), p(mode => 'truncate')), [],
		'mode=truncate => empty delete list (reserved)';
};

# ---------- single count bound ----------

subtest 'single count bound: keep top N most recent' => sub {
	plan tests => 3;
	my $files = make_files(5);
	my $delete = apply($files, p(mode => 'union', count => 3));
	is scalar(@$delete), 2, "5 files, count=3 => 2 deletes";
	is $delete->[0]{path}, '/tmp/4.log', 'oldest file in delete list';
	is $delete->[-1]{path}, '/tmp/3.log', 'second-oldest file in delete list';
};

subtest 'count larger than file list: no deletes' => sub {
	plan tests => 1;
	cmp_deeply apply(make_files(3), p(mode => 'union', count => 10)),
		[], 'count >> files => empty delete list';
};

subtest 'count = 0: delete everything' => sub {
	plan tests => 1;
	is scalar(@{ apply(make_files(5), p(mode => 'union', count => 0)) }), 5,
		'count=0 => all 5 files deleted';
};

# ---------- single duration bound ----------

subtest 'single duration bound: delete files older than threshold' => sub {
	plan tests => 2;
	my $files = make_files(5);  # spans 0 to 4 days old
	my $delete = apply($files, p(mode => 'union', age_seconds => 2 * 86400 + 1));
	# Files 0, 1, 2 days old kept; files 3 and 4 days old deleted
	is scalar(@$delete), 2, "5 files, threshold=2d => 2 deletes";
	cmp_deeply [ sort map { $_->{path} } @$delete ],
		[ '/tmp/3.log', '/tmp/4.log' ],
		'oldest two files in delete list';
};

subtest 'duration: very large threshold => no deletes' => sub {
	plan tests => 1;
	cmp_deeply apply(make_files(5), p(mode => 'union', age_seconds => 365 * 86400)),
		[], 'threshold=1y => empty delete list';
};

subtest 'duration: age_seconds = 0 => delete all' => sub {
	plan tests => 1;
	is scalar(@{ apply(make_files(5), p(mode => 'union', age_seconds => 0)) }), 5,
		'age_seconds=0 => all files deleted (none newer than 0 seconds ago)';
};

# ---------- compound union (min of) ----------

subtest 'union: keep if EITHER bound votes keep' => sub {
	plan tests => 2;
	my $files = make_files(10);
	# count=2 alone would keep top 2; age=4d alone would keep top 5
	# Union: keep top 5 (the union of the two kept sets)
	my $delete = apply($files,
		p(mode => 'union', count => 2, age_seconds => 4 * 86400 + 1));
	is scalar(@$delete), 5, "union(count=2, age=4d): 5 deletes";
	cmp_deeply [ sort map { $_->{path} } @$delete ],
		[ '/tmp/5.log', '/tmp/6.log', '/tmp/7.log', '/tmp/8.log', '/tmp/9.log' ],
		'5 oldest files deleted (count-bound liberalised by age-bound)';
};

# ---------- compound intersection (max of) ----------

subtest 'intersection: delete if EITHER bound votes delete' => sub {
	plan tests => 2;
	my $files = make_files(10);
	# count=2 alone keeps top 2; age=4d alone keeps top 5
	# Intersection: keep top 2 (the intersection of the two kept sets)
	my $delete = apply($files,
		p(mode => 'intersection', count => 2, age_seconds => 4 * 86400 + 1));
	is scalar(@$delete), 8, "intersection(count=2, age=4d): 8 deletes";
	cmp_deeply [ sort map { $_->{path} } @$delete ],
		[ '/tmp/2.log', '/tmp/3.log', '/tmp/4.log', '/tmp/5.log',
		  '/tmp/6.log', '/tmp/7.log', '/tmp/8.log', '/tmp/9.log' ],
		'8 deletes (everything beyond the tighter count bound)';
};

# ---------- intersection with single bound: collapses to that bound ----------

subtest 'intersection with only count bound = single count behavior' => sub {
	plan tests => 1;
	is scalar(@{
		apply(make_files(5), p(mode => 'intersection', count => 3))
	}), 2, 'intersection mode + count only => same as union count: 2 deletes';
};

# ---------- boundary: file count exactly equals budget ----------

# The orchestrator (cleanup_old_logs) decides whether to "reserve a
# slot" for an upcoming write based on on_reuse mode and whether the
# active path is already in the set.  This primitive is naive: it
# operates on the file set it is given without surprise.  When the set
# is exactly at the budget, nothing is deleted.

subtest 'at-budget: file count = lifespan count => 0 deletes' => sub {
	plan tests => 2;
	cmp_deeply apply(make_files(5), p(mode => 'union', count => 5)), [],
		'5 files, count=5 => empty delete list';
	cmp_deeply apply(make_files(5),
		p(mode => 'intersection', count => 5,
		  age_seconds => 365 * 86400)),
		[],
		'5 files, intersection count=5 + permissive age => empty delete list';
};

# ---------- input list with arbitrary mtime ordering ----------

subtest 'input order is not assumed; sort handled internally' => sub {
	plan tests => 1;
	my $files = [
		{ path => '/tmp/middle.log', mtime => $NOW - 86400 },
		{ path => '/tmp/oldest.log', mtime => $NOW - 5 * 86400 },
		{ path => '/tmp/newest.log', mtime => $NOW },
	];
	my $delete = apply($files, p(mode => 'union', count => 2));
	cmp_deeply [ map { $_->{path} } @$delete ],
		[ '/tmp/oldest.log' ],
		'mtime-desc sort handled internally; oldest dropped';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
