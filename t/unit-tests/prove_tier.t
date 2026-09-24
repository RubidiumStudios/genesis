#!/usr/bin/env perl
# t/bin/prove-tier runs exactly the tier's files it is given, slowest first
# by the last run's times, and with --failed only the tier's files that
# failed last time; prove's own state selection would add every file it
# has ever recorded, whatever the tier.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Cwd qw/getcwd/;
use Test::More;

my $dir = "$helper::TMP/prove-tier";
mkdir $dir;
mkdir "$dir/t";
mkdir "$dir/t/$_" for qw/unit-tests integration-tests/;

# Each file notes that it started, so the order files start in can be read
# back; $pause makes one slower than the rest, $fail makes it fail.
sub test_file {
	my ($path, %opts) = @_;
	my $pause = $opts{pause} || 0;
	my $ok    = $opts{fail} ? 'not ok' : 'ok';
	put_file("$dir/$path", <<EOS);
open my \$fh, '>>', 'ran' or die; print \$fh "$path\\n"; close \$fh;
select(undef, undef, undef, $pause);
print "1..1\\n$ok 1\\n";
EOS
}

sub prove_tier {
	my @args = @_;
	unlink "$dir/ran";
	my $here = getcwd;
	chdir $dir or die;
	my $said = qx($helper::TOPDIR/t/bin/prove-tier @args 2>&1 < /dev/null);
	my $rc = $? >> 8;
	chdir $here or die;
	my @ran;
	if (open my $fh, '<', "$dir/ran") { chomp(@ran = <$fh>); }
	return ($rc, \@ran, $said);
}

test_file('t/unit-tests/fast.t');
test_file('t/unit-tests/slow.t', pause => 0.5);
test_file('t/integration-tests/other.t');

subtest 'a tier runs only the files it is given' => sub {
	plan tests => 3;
	my ($rc, $ran) = prove_tier(qw(integration-tests 2 t/integration-tests/other.t));
	is($rc, 0, 'the integration file passes');
	($rc, $ran) = prove_tier(qw(unit-tests 2 t/unit-tests/fast.t t/unit-tests/slow.t));
	is($rc, 0, 'the unit files pass');
	is_deeply([sort @$ran], [qw(t/unit-tests/fast.t t/unit-tests/slow.t)],
		'the integration file the state records is not run with them');
};

subtest 'the slowest file last time starts first' => sub {
	plan tests => 2;
	my ($rc, $ran) = prove_tier(qw(unit-tests 1 t/unit-tests/fast.t t/unit-tests/slow.t));
	is($rc, 0, 'the unit files pass');
	is_deeply($ran, [qw(t/unit-tests/slow.t t/unit-tests/fast.t)],
		'slow.t, named last, starts first');
};

subtest 'a subset of a tier stays a subset' => sub {
	plan tests => 1;
	my (undef, $ran) = prove_tier(qw(unit-tests 2 t/unit-tests/fast.t));
	is_deeply($ran, [qw(t/unit-tests/fast.t)], 'only the file named runs');
};

subtest '--failed reruns only the tier\'s failures' => sub {
	plan tests => 5;
	test_file('t/unit-tests/fast.t', fail => 1);
	my ($rc) = prove_tier(qw(unit-tests 2 t/unit-tests/fast.t t/unit-tests/slow.t));
	isnt($rc, 0, 'a failing unit file fails the tier');

	my ($ran, $said);
	($rc, $ran, $said) = prove_tier(qw(--failed integration-tests 2));
	is($rc, 0, 'a tier with no failures succeeds');
	is_deeply($ran, [], 'and runs nothing');
	like($said, qr/No integration-tests file failed/, 'saying so');

	(undef, $ran) = prove_tier(qw(--failed unit-tests 2));
	is_deeply($ran, [qw(t/unit-tests/fast.t)], 'the unit tier reruns its failure alone');
};

done_testing;
