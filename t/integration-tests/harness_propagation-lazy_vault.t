#!/usr/bin/env perl
# A harness starts its vault when something first needs it, not as it is
# built: a row that only reads git never pays for one, and a unit test that
# builds a harness for its repositories starts no server.  vault => 1 starts
# it at once, and vault => 0 keeps it off, so a command runs with none.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

local $ENV{GENESIS_HARNESS_NO_CACHE} = 1;

subtest 'a harness built for its repositories starts no vault' => sub {
	plan tests => 2;
	my $h = make_harness(envs => ['qa']);
	ok(!$h->{vault_target}, 'no vault is started as it is built');
	ok(-d "$h->{a}/.git", 'while its repositories are there to read');
};

subtest 'the first thing that needs the vault starts it' => sub {
	# Three, and the restoration run_genesis asserts for itself.
	plan tests => 4;
	my $h = make_harness(envs => ['qa']);
	$h->fixture_applied;
	ok($h->{vault_target}, 'writing a record starts it');

	my $g = make_harness(envs => ['qa']);
	my (undef, $err, $rc) = run_genesis($g, 'pipeline-status');
	ok($g->{vault_target}, 'and so does running a command');
	is($rc, 0, 'which then reads it') or diag $err;
};

subtest 'vault => 1 starts it at once, and vault => 0 keeps it off' => sub {
	# Two, and the restoration run_genesis asserts for itself.
	plan tests => 3;
	ok(make_harness(envs => ['qa'], vault => 1)->{vault_target},
		'asked for, it is started as the harness is built');

	my $h = make_harness(envs => ['qa'], vault => 0);
	run_genesis($h, 'pipeline-status');
	ok(!$h->{vault_target}, 'refused, a command runs without one');
};

done_testing;
