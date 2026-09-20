#!/usr/bin/env perl
# Proves the four answers _prior_env_record gives, which are the record a
# deploy reads about its predecessor before it decides anything.
#
# Three of the four are an undefined answer, and they differ in what made it
# undefined, which is a predecessor nobody named, a path that holds nothing
# to read, and a path holding records where none of them reached the
# director.  The fourth is the newest deployment that did reach it.
#
# The sub is called directly, because a deploy reads this once and then
# refuses or carries on, so a spawned run shows the refusal rather than the
# answer underneath it, and three of these four answers look the same from
# outside.
#
# The records are written through the harness, at the paths the deployment
# reader enumerates, so the row reads what a deploy would have read rather
# than a shape composed beside the test.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

use_ok 'Genesis::Commands::Env';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

my $h = make_harness(envs => ['lab', 'qa', 'ops']);
fixture_vault($h);
my $env = top_for($h)->load_env('qa')->with_vault;

subtest 'a deploy with no predecessor reads no record' => sub {
	plan tests => 1;

	is(Genesis::Commands::Env::_prior_env_record($env, undef), undef,
		'an environment naming no predecessor asks the vault nothing');
};

subtest 'a predecessor with nothing at its path reads no record' => sub {
	plan tests => 1;

	# ops is declared like the others and has never deployed, so the path
	# the reader composes holds nothing at all.
	is(Genesis::Commands::Env::_prior_env_record($env, 'ops'), undef,
		'a path that holds no deployments answers with no record');
};

subtest 'a predecessor whose deployments all failed reads no record' => sub {
	plan tests => 1;

	# A deployment that never reached the director is not one the deploy may
	# stand on, and a record of it is still a record at the path.
	certify($h, 'lab', result => 'failed', control_commit => 'c0ffee1');

	is(Genesis::Commands::Env::_prior_env_record($env, 'lab'), undef,
		'a predecessor that only ever failed has certified nothing');
};

subtest 'a predecessor two deployments deep reads the newest of them' => sub {
	plan tests => 3;

	# The entries are keyed on the compact timestamp the deploy writes, and
	# the reader sorts them rather than taking whichever one the hash hands
	# back first, so two deployments are what tells a sort from an accident.
	certify($h, 'lab', control_commit => 'aaaaaaa',
		at => '2026-09-01 10:00:00 +0000');
	certify($h, 'lab', control_commit => 'bbbbbbb',
		at => '2026-09-02 10:00:00 +0000');

	my $record = Genesis::Commands::Env::_prior_env_record($env, 'lab');
	is($record->{git}{control_commit}, 'bbbbbbb',
		'the newest deployment is the one the deploy is told about');
	is($record->{result}, 'success',
		'and it is one that reached the director');
	# The record is addressed by the compact stamp the deploy writes, which
	# is the timestamp the reader hands back.
	is($record->{at}, '20260902100000',
		'and the record carries when it was, so the deploy can say so');
};

done_testing;
