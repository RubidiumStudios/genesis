#!/usr/bin/env perl
# t/bin/affected-tests chooses the tests a change can reach, from the record
# Harness::Deps writes of what each test really loaded, and errs toward
# running a test whenever the record cannot answer for it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

my $dir = "$helper::TMP/affected";
mkdir $dir;

put_file("$dir/manifest", <<'EOS');
[sanity-tests]
sanity-tests/pod.t
[unit-tests]
unit-tests/kit.t
unit-tests/top.t
unit-tests/new.t   # never recorded yet
[integration-tests]
integration-tests/deploy.t
EOS

put_file("$dir/deps", <<'EOS');
t/unit-tests/kit.t	lib/Genesis/Kit.pm
t/unit-tests/kit.t	t/helper.pm
t/unit-tests/top.t	lib/Genesis/Top.pm
t/unit-tests/top.t	t/helper.pm
t/integration-tests/deploy.t	lib/Genesis/Kit.pm
t/integration-tests/deploy.t	lib/Genesis/Commands/Env.pm
EOS

sub affected {
	my (@args) = @_;
	my @out = split ' ', qx($^X $helper::TOPDIR/t/bin/affected-tests --manifest $dir/manifest --map $dir/deps @args);
	return [@out];
}

subtest 'a changed module selects the tests that loaded it' => sub {
	plan tests => 2;
	is_deeply(affected(qw(--tier unit-tests --changed lib/Genesis/Kit.pm)),
		[qw(t/unit-tests/kit.t t/unit-tests/new.t)],
		'the unit test that loaded it, and the one never recorded, which the record cannot answer for');
	is_deeply(affected(qw(--tier integration-tests --changed lib/Genesis/Commands/Env.pm)),
		[qw(t/integration-tests/deploy.t)],
		'a module only a genesis child loaded still reaches the test that ran it');
};

subtest 'a changed test selects itself' => sub {
	plan tests => 1;
	is_deeply(affected(qw(--changed t/unit-tests/top.t)),
		[qw(t/unit-tests/top.t)], 'and nothing else');
};

subtest 'a shared test module reaches every test that loaded it' => sub {
	plan tests => 1;
	is_deeply(affected(qw(--tier unit-tests --changed t/helper.pm)),
		[qw(t/unit-tests/kit.t t/unit-tests/top.t t/unit-tests/new.t)],
		'in manifest order');
};

subtest 'a change the record cannot place reaches everything' => sub {
	plan tests => 3;
	is_deeply(affected(qw(--changed Makefile)),
		[qw(t/sanity-tests/pod.t t/unit-tests/kit.t t/unit-tests/top.t t/unit-tests/new.t t/integration-tests/deploy.t)],
		'a file outside lib/ and the tests runs every test');
	is_deeply(affected(qw(--tier sanity-tests --changed lib/Genesis/Kit.pod)),
		[qw(t/sanity-tests/pod.t)], 'a POD change runs the sanity tier, where the POD gate is');
	is_deeply(affected(qw(--tier unit-tests --changed lib/Genesis/Kit.pod)), [],
		'and no other');
};

subtest 'without a record, every test runs' => sub {
	plan tests => 1;
	my @out = split ' ', qx($^X $helper::TOPDIR/t/bin/affected-tests --manifest $dir/manifest --map $dir/missing --tier unit-tests --changed lib/Genesis/Kit.pm);
	is_deeply(\@out, [qw(t/unit-tests/kit.t t/unit-tests/top.t t/unit-tests/new.t)], 'the whole tier');
};

subtest 'no change selects nothing' => sub {
	plan tests => 1;
	is_deeply(affected(qw(--changed)), [], 'an empty list');
};

done_testing;
