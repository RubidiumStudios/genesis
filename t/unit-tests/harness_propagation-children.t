#!/usr/bin/env perl
# Proves the setup of T119, T242, T248, and T164: a spawned child is
# recorded with its arguments and what the lock was doing around it, the
# lock probe answers about a free and a held lock, the shuttle spy tells
# no request from no backend, a skipped git step reports and does not
# land, and the broken-blueprint kit fails one environment and not the
# other.
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

subtest 'a spawned child is recorded with its arguments' => sub {
	# One of the four is the restoration the run asserts for itself.
	plan tests => 4;

	my $h = make_harness(envs => ['qa']);

	# The features hook is run once for an environment and by the cheapest
	# command there is, so the child this row counts is the one the hook
	# spawned and nothing else the run did along the way.
	fixture_kit($h, hooks => {features => <<'EOS'});
genesis version >/dev/null
for feature in "$@" ; do echo "$feature" ; done
EOS
	child_recorder($h, exit => 0);

	run_genesis($h, 'qa', 'lookup', '--env', 'genesis');
	my @runs = child_runs($h);
	is(scalar(@runs), 1, 'exactly one child was spawned');
	ok(scalar(@{$runs[0]{argv}}), 'its argument list was recorded');
	ok(exists $runs[0]{lock_at_start},
		'and what the lock was doing when it started');
};

subtest 'the lock probe answers for a free and a held lock' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);
	is(lock_probe($h), undef, 'a free lock reads undef');

	my $pid = hold_session_lock($h, command => 'genesis propagate');
	my $holder = lock_probe($h);
	is($holder->{pid}, $pid, 'a held lock names the holder');
	is($holder->{command}, 'genesis propagate', 'and the command it is running');

	release_session_lock($h, $pid);
};

subtest 'the shuttle spy tells no request from no backend' => sub {
	# One of the three is the restoration the run asserts for itself.
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	my $spy = shuttle_spy($h);
	is_deeply([shuttle_requests($spy)], [],
		'a run that has not happened made no requests');

	run_genesis($h, 'qa', 'deploy', '-y');
	is_deeply([shuttle_requests($spy)], [],
		'and a manual-provider deploy made none either');
};

subtest 'a skipped git step reports and does not land' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $branch = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $h->control, $branch);

	# The branch has to stand in front of R for the skip to say anything, so
	# the row writes a commit copy A keeps to itself and then asks for the
	# push that would publish it.
	local_only_commit($h, $branch);

	my $git = fault_git($h);
	my $before = remote_sha($h, $branch);
	skip_on($git, 'push', 1);
	$git->push('origin', $branch);

	is(remote_sha($h, $branch), $before, 'R did not move');
	is(scalar(grep {$_->[0] eq 'push'} step_log($git)), 1,
		'and the step reported itself as taken');
};

subtest 'the broken-blueprint kit fails one environment and not the other' => sub {
	# Two of the four are the restorations the runs assert for themselves.
	plan tests => 4;

	my $h = make_harness(envs => ['lab', 'qa'], kit => 'broken-blueprint');
	write_env_file($h, 'qa', genesis => {kit_blueprint_fails => 1});

	my (undef, undef, $good) = run_genesis($h, 'lab', 'check-secrets');
	is($good, 0, 'the environment whose blueprint stands renders');

	my (undef, undef, $bad) = run_genesis($h, 'qa', 'check-secrets');
	isnt($bad, 0, 'and the one whose blueprint raises does not');
};

done_testing;
