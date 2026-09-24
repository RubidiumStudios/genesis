#!/usr/bin/env perl
# t/bin/test-progress reads a run's log and reports each tier's files done,
# the failures so far, and the time left from the last run's times, giving
# no estimate where it has no time for a file still to run.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

my $dir = "$helper::TMP/progress";
mkdir $dir;

put_file("$dir/manifest", <<'EOS');
[sanity-tests]
sanity-tests/one.t
[unit-tests]
unit-tests/a.t
unit-tests/b.t
unit-tests/c.t
[integration-tests]
integration-tests/x.t
integration-tests/y.t
[e2e-tests]
e2e-tests/z.t
EOS

put_file("$dir/state", <<'EOS');
---
tests:
  t/unit-tests/c.t:
    elapsed: 60
  t/integration-tests/x.t:
    elapsed: 120
  t/integration-tests/y.t:
    elapsed: 180
  t/e2e-tests/z.t:
    elapsed: 60
EOS

sub progress {
	my ($log, @args) = @_;
	put_file("$dir/log", $log);
	return scalar qx($^X $helper::TOPDIR/t/bin/test-progress --manifest $dir/manifest --state $dir/state -j 2 @args $dir/log);
}

subtest 'a run part way through' => sub {
	plan tests => 5;
	my $said = progress(<<'EOS');
[10:00:00] t/sanity-tests/one.t ........ ok      10 ms
[10:00:01] t/unit-tests/a.t ........ ok      10 ms
[10:00:02] t/unit-tests/b.t ........
Dubious, test returned 1 (wstat 256, 0x100)
EOS
	like($said, qr/sanity-tests\s+1 \/ 1\s+done/, 'a tier all done says so');
	like($said, qr/unit-tests\s+2 \/ 3\s+running/, 'a failed file counts as done in its tier');
	like($said, qr/failed so far:\n\s+t\/unit-tests\/b\.t/, 'and is named among the failures');
	like($said, qr/integration-tests\s+0 \/ 2\s*\n/, 'a tier not started shows none done');
	# c.t's 60 s is shared by the two unit jobs, and the rest run one at a
	# time: 30 + 120 + 180 + 60 = 390 s, about 7 minutes.
	like($said, qr/about 7 min left/, "the time left comes from the last run's times");
};

subtest 'a tier a later tier has followed is over' => sub {
	plan tests => 2;
	# The manifest lists c.t, which this run never ran: a file added after
	# the run started.  Once integration has begun, the unit tier is over
	# however its count reads.
	my $said = progress(<<'EOS');
[10:00:01] t/unit-tests/a.t ........ ok      10 ms
[10:00:02] t/unit-tests/b.t ........ ok      10 ms
[10:00:03] t/integration-tests/x.t ........ ok      10 ms
EOS
	like($said, qr/unit-tests\s+2 \/ 3\s+done, 1 not in this run/,
		'it reads done, and counts the file the run did not include');
	like($said, qr/integration-tests\s+1 \/ 2\s+running/, 'while the later tier runs');
};

subtest 'no estimate without a time for every file left' => sub {
	plan tests => 1;
	put_file("$dir/state", "---\ntests:\n  t/unit-tests/c.t:\n    elapsed: 60\n");
	like(progress("[10:00:00] t/sanity-tests/one.t ........ ok      10 ms\n"),
		qr/no estimate: 5 file\(s\) left have no time/, 'it says how many it cannot time');
};

subtest 'a failed tier ends the watch' => sub {
	plan tests => 1;
	# With -w the report would refresh until the run ended; a tier that fails
	# ends make test, so the report stops there rather than waiting forever.
	my $said = progress("[10:00:01] t/unit-tests/a.t ........\nDubious, test returned 1\nResult: FAIL\n", '-w', 1);
	like($said, qr/failed so far/, 'it reports once and stops');
};

done_testing;
