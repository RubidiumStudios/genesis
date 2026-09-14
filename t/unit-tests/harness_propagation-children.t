#!/usr/bin/env perl
# Proves the setup of T119, T242, T248, and T164: a spawned child is
# recorded with its arguments and what the lock was doing around it, the
# lock probe answers about a free and a held lock in this process and from
# a child of its own, the shuttle spy tells no request from no backend and
# reads a request back where one was made, a skipped git step reports and
# does not land, and the broken-blueprint kit fails one environment and not
# the other.
#
# The recorder itself is read here too, because it is the fixture behind
# every one of those children.  It answers with a status of its own where
# its lock fixture cannot go on and where a child's status was lost, and it
# says in the record which of the two happened.  The two fixture kits are
# read the same way, one for the list it takes out of an environment file
# and one for the key it refuses on.
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

subtest 'a fixture that cannot go on answers with one status' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);

	# A git directory the holder cannot write, so the holder the recorder
	# forks exits without ever taking the lock.  That is the fixture failing
	# rather than the command under test, and the recorder has to say so
	# with a status of its own rather than whatever errno held.
	my $where = "$h->{base}/unwritable";
	mkdir $where or die "cannot make $where: $!";
	mkdir "$where/.git" or die "cannot make $where/.git: $!";
	$h->{unwritable} = $where;
	chmod 0500, "$where/.git";

	my $recorder = child_recorder($h, copy => 'unwritable', exec => 0,
		hold_lock => 'a stranger');
	my (undef, $rc, $err) = run({stderr => 0, passfail => 0},
		$recorder, 'version');

	is($rc, 99, 'the refusal answers with the status the fixture keeps');
	like($err, qr/lock holder exited before it took the lock/,
		'and says on stderr what the holder did');
	is_deeply([child_runs($h)], [],
		'while no record was written for a child that never ran');

	chmod 0700, "$where/.git";
};

subtest 'the recorder waits for its own holder to take the lock' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);

	# The lock is already held and the holder's line is already in the file,
	# so the holder the recorder forks blocks where it asks for it and never
	# writes a line of its own.  A wait that asked only whether the file had
	# content would read the line that is already there and let the run
	# proceed against a lock it never took.
	my $first = hold_session_lock($h, command => 'genesis propagate');

	my $recorder = child_recorder($h, exec => 0, hold_lock => 'a stranger');
	my (undef, $rc, $err) = run({stderr => 0, passfail => 0},
		$recorder, 'version');

	is($rc, 99, 'the recorder refuses rather than take that line as proof');
	like($err, qr/did not take the lock/, 'and says its holder never got it');
	is_deeply([child_runs($h)], [],
		'while no record was written for a run that never went ahead');

	release_session_lock($h, $first, hard => 1);
};

subtest 'a child whose status was lost is recorded as lost' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $recorder = child_recorder($h, probe => 1);

	# The ordinary shape first, so the field below means something read
	# against it.
	my (undef, $rc) = run({stderr => 0, passfail => 0}, $recorder, 'version');
	is($rc, 0, 'a run nobody interfered with answers what its child did');
	my ($plain) = child_runs($h);
	ok(!$plain->{status_lost}, 'and records that the status was not lost');

	# With SIGCHLD ignored the kernel reaps the child itself, so the wait can
	# never answer with the pid it forked, and the loop has to end on that
	# rather than spin on it.  The recorder is read into a process that has
	# already ignored the signal rather than handed it across an exec,
	# because perl puts SIGCHLD back to its default as it starts up.
	my (undef, $lost) = run({stderr => 0, passfail => 0}, 'perl', '-e',
		'$SIG{CHLD} = "IGNORE"; my $it = shift @ARGV; do $it; die $@ if $@;',
		$recorder, 'version');
	is($lost, 99, 'a run whose child was reaped elsewhere refuses');

	my @runs = child_runs($h);
	ok($runs[-1]{status_lost}, 'the record says the status was lost');
	is($runs[-1]{exit}, 99,
		'and carries the same status, not the success it cannot vouch for');
};

subtest 'the blueprint refuses on the key and not the bare word' => sub {
	# Two of the four are the restorations the runs assert for themselves.
	plan tests => 4;

	my $h = make_harness(envs => ['lab', 'qa'], kit => 'broken-blueprint');
	write_env_file($h, 'qa', genesis => {kit_blueprint_fails => 1});

	# The word stands in lab's file twice without ever being set, which is
	# what a match on the bare word cannot tell from an environment that
	# asked to be refused.
	my $lab = $h->a . '/lab.yml';
	helper::put_file($lab, helper::get_file($lab)
		. "# kit_blueprint_fails: a note about the key\n"
		. "# see kit_blueprint_fails for what this kit refuses\n");
	run({dir => $h->a}, 'git', 'add', '--', 'lab.yml');
	run({dir => $h->a, onfailure => 'Failed to commit the mention'},
		'git', 'commit', '-q', '-m', 'mention the key without setting it');

	my (undef, undef, $mentioned) = run_genesis($h, 'lab', 'check-secrets');
	is($mentioned, 0, 'an environment that only mentions the word renders');

	my (undef, undef, $asked) = run_genesis($h, 'qa', 'check-secrets');
	isnt($asked, 0, 'and the one that sets the key does not');
};

subtest 'a list is read to the end of its own block' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0, kit => 'exodus-reader');

	# The list is the last key of the genesis block, with a block of its own
	# below it, which is the shape a range that ends only on a key at the
	# list key's own indent runs straight past.
	helper::put_file($h->a . '/qa.yml', <<'ENV');
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: qa
  reads_exodus:
    - beta
params:
  - gamma
  - delta
ENV

	# The hook is run as a hook runs it rather than through a command,
	# because what a command would spawn is a genesis child and the rows
	# above count those.
	my ($out) = run({
			dir => $h->a,
			env => {
				GENESIS_ROOT        => $h->a,
				GENESIS_ENVIRONMENT => 'qa',
				GENESIS_KIT_PATH    => $h->a . '/dev',
			},
		}, $h->a . '/dev/hooks/blueprint');

	is_deeply([grep {length} split /\n/, ($out // '')],
		['manifest.yml', 'reads/beta.yml'],
		'the list ends with its own block');
	ok(!-f $h->a . '/dev/reads/gamma.yml',
		'so no entry of the block below it was read as one of its own');
};

done_testing;
