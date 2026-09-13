#!/usr/bin/env perl
# Proves the setup of T119, T242, T248, and T164: a spawned child is
# recorded with its arguments and what the lock was doing around it, the
# lock probe answers about a free and a held lock in this process and from
# a child of its own, the shuttle spy tells no request from no backend and
# reads a request back where one was made, a skipped git step reports and
# does not land, and the broken-blueprint kit fails one environment and not
# the other.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Cwd ();
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

	# The hook helper's genesis function puts -C and the deployment root in
	# front of whatever the hook asked for, so the whole list is named here
	# rather than counted, and the root is named as the child was handed it.
	is_deeply($runs[0]{argv}, ['-C', Cwd::abs_path($h->a), 'version'],
		'its argument list was recorded exactly as the hook passed it');
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

subtest 'the probe script answers from a child of its own' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $probe = $h->lock_probe_bin;

	# A kit hook cannot call a sub in this process, so the probe a hook would
	# call is run here the way a hook runs it, which is as a command taking a
	# label, and the answers are read back out of the harness's own log.
	my $pid = hold_session_lock($h, command => 'genesis pipeline-apply');
	run({}, $probe, 'while it is held');
	release_session_lock($h, $pid);
	run({}, $probe, 'once it is free');

	my @samples = lock_probe_log($h);
	is(scalar(@samples), 2, 'the probe logged an answer for each label');
	is($samples[0]{pid}, $pid, 'the first answer names the holder');
	is($samples[0]{command}, 'genesis pipeline-apply',
		'and the command it is running');
	is($samples[1]{held}, 0, 'and the second answers a free lock');
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

subtest 'the shuttle spy reads back a request a child made' => sub {
	# One of the three is the restoration the run asserts for itself.
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	my $spy = shuttle_spy($h);

	# The request is written by a child of the run rather than by this
	# process, because that is where a shuttle request will be written from,
	# and the spy is named to that child through the environment alone.
	fixture_kit($h, hooks => {features => <<'EOS'});
printf '{"action":"trigger","environment":"%s","provider":"manual"}\n' \
	"$GENESIS_ENVIRONMENT" >> "$GENESIS_SHUTTLE_SPY"
for feature in "$@" ; do echo "$feature" ; done
EOS

	run_genesis($h, 'qa', 'lookup', '--env', 'genesis');
	my @requests = shuttle_requests($spy);
	is(scalar(@requests), 1, 'the one request the child made is read back');
	is_deeply($requests[0],
		{action => 'trigger', environment => 'qa', provider => 'manual'},
		'and it carries every field the child wrote');
};

subtest 'a skipped git step reports and does not land' => sub {
	plan tests => 3;

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

	# The refresh above ran before the local commit and nothing has moved R
	# since, so the remote-tracking ref still holds what R holds and the ahead
	# count is the distance between copy A and R.  A push that quietly did
	# nothing at all would leave the same two shas but no commit in front.
	my ($ahead) = counts($h->a, $branch);
	is($ahead, 1, 'and copy A still stands one commit in front of R');
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
