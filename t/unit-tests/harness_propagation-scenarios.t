#!/usr/bin/env perl
# Proves the composing half of T2: each named scenario leaves the state its
# name says, and a row that wants something else passes options through.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'ready_envs does the five things a walking row needs' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['lab', 'qa']);
	ready_envs($h);

	ok(remote_sha($h, $h->slug('lab')), 'lab has its branch on R');
	ok(remote_sha($h, $h->slug('qa')), 'and so does qa');
	ok(record_at($h, $h->applied_path), 'the applied record is written');
	ok(record_at($h, $h->env_path('lab')), "and lab's certified commit");
};

subtest 'the named shapes each add the one thing their name says' => sub {
	plan tests => 5;

	my $ready = ready_harness();
	ok(record_at($ready, $ready->applied_path), 'ready_harness is walked');

	my $seeded = seeded_harness();
	isnt(harness_marker($seeded, $seeded->slug('qa')), undef,
		'seeded_harness carries a delivery');

	my $due = due_harness();
	isnt(tip_of($due, $due->control), harness_marker($due, $due->slug('qa')),
		'due_harness leaves a control commit undelivered');

	my $held = held_harness();
	ok(record_at($held, $held->env_path('prod') . '/hold'),
		'held_harness carries the hold record');

	my $pr = ready();
	ok($pr->{gh}, 'ready stands the GitHub double up for PR mode');
};

subtest 'a row that wants something else passes options through' => sub {
	plan tests => 2;

	my $h = ready_harness(envs => ['lab', 'qa', 'prod'], type => 'vault');
	is($h->type, 'vault', 'the type reached make_harness');
	ok(remote_sha($h, $h->slug('prod')),
		'and the third environment has its branch');
};

done_testing;
