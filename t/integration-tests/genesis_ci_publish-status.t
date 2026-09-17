#!/usr/bin/env perl
# Proves T190: a run in which every branch landed exits 0 and a run in which
# one branch was rejected exits TEMPFAIL, so a partial publish is
# distinguishable from a clean one by the status alone.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a clean publish exits zero' => sub {
	# Two rather than one, because run_genesis asserts the restoration of the
	# working state in its own words and that assertion is counted here.  Both
	# subtests in this file are counted the same way.
	plan tests => 2;

	my $h = ready_harness(envs => ['lab', 'qa'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: fourteen\n"},
		message => 'share an op with every environment',
		push    => 1,
	);

	my (undef, undef, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, 0, 'every branch landed, so the run is clean');
};

subtest 'a single rejection makes the whole run a partial one' => sub {
	plan tests => 3;

	my $h = ready_harness(envs => ['lab', 'qa'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);

	# Copy B advances qa/bosh on R between copy A's refresh and its first
	# push, so the remote turns that one ref down and leaves lab's alone.
	move_on_r_at($h, 'qa/bosh', at => 'push', nth => 1);

	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: fifteen\n"},
		message => 'share an op with every environment',
		push    => 1,
	);

	my ($out, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, Genesis::Exit::TEMPFAIL,
		'one rejected branch makes the run a partial one');
	like(unfolded($out, $err), qr{publish rejected, qa/bosh moved on R},
		'and the report says which branch it was');
};

done_testing;
