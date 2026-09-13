#!/usr/bin/env perl
# Proves the reading half of T2 and the setup of T72 and T144: a written
# record reads back, the reads are counted, a certified record carries the
# dependency set, breaking the applied record alone leaves the
# environments readable, and the three pre-flight shapes are what git
# refuses on.
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

subtest 'every written record reads back through one reader' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa']);
	my $control = $h->git('a')->sha($h->control);

	fixture_applied($h, control => $control, provider => 'manual');
	my $applied = record_at($h, $h->applied_path);
	is($applied->{control_commit}, $control,
		'the applied record reads back at the address D103 fixes');

	certify($h, 'qa', control_commit => $control,
		dependencies_read => ['ops/bosh']);
	my $deployed = record_at($h, $h->env_path('qa'));
	is($deployed->{'git.control_commit'}, $control,
		"the deployment record carries the branch's control commit");
	is($deployed->{dependencies_read}, 'ops/bosh',
		'and the dependency set it was deployed against');

	is(record_at($h, $h->env_path('qa') . '/hold'), undef,
		'a path nothing was written to reads undef');
};

subtest 'a record still reads as itself once it has children' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	certify($h, 'qa', commit => 'deadbeef', control_commit => 'cafebabe');
	fixture_pipeline_record($h, 'qa', dependencies => ['lab/bosh']);

	# safe export answers with the whole subtree, so the reader has to pick
	# the record out by its own address rather than take whatever came back.
	my $deployed = record_at($h, $h->env_path('qa'));
	is($deployed->{'git.commit'}, 'deadbeef',
		'the deployment record reads back with a pipeline record beneath it');
	is(record_at($h, $h->env_path('qa') . '/pipeline')->{dependencies},
		'lab/bosh', 'and the record beneath it reads back as itself');

	is(record_at($h, $h->exodus_mount . 'qa'), undef,
		'a path holding nothing of its own reads undef whatever it carries');
};

subtest 'the reads are counted in order' => sub {
	# One of the nine is the restoration the run asserts for itself.
	plan tests => 9;

	my $h = make_harness(envs => ['qa']);
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	certify($h, 'qa', control_commit => $h->git('a')->sha($h->control));

	# The reads a command makes are made by a child process, and the recording
	# safe first on that child's path is the only thing that can see them, so
	# the row makes its read the way the child makes one.
	my $shown;
	{
		local $ENV{PATH} = join(':',
			Harness::Propagation::_path_prefix($h), $ENV{PATH});
		($shown) = run({}, 'safe', 'get', $h->applied_path);
	}

	my $read = vault_read_log($h);
	ok(scalar(@$read), 'a read made on the path a run is given is counted');
	is(scalar(grep {$_ eq $h->applied_path} @$read), 1,
		'and the applied record is named exactly once');
	is($read->[-1], $h->applied_path, 'the log answers in the order read');
	like($shown, qr/control_commit/,
		'and the record still comes back through the recording safe');

	# A run empties the log as it starts, so what the log answers is that
	# run's reads and never what a row read before it.  The read above is what
	# the emptying has to clear for the assertion below to mean anything.
	my (undef, undef, $exit) = run_genesis($h, 'environments');
	is($exit, 0, 'a default harness is a repository a whole command runs in');
	is_deeply(vault_read_log($h), [],
		'and the run started on an empty log');

	# The reader the harness owns runs on the parent's own path, which the
	# recording safe is kept off, so a row reading a record to assert on it is
	# no part of what the run read.
	ok(record_at($h, $h->applied_path), 'the record reads back after the run');
	is_deeply(vault_read_log($h), [],
		"and the harness's own reader counted for nothing");
};

subtest 'the applied record alone can be made unreadable' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa']);
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	certify($h, 'qa', control_commit => $h->git('a')->sha($h->control));

	break_vault($h, envs => [], applied => 1);
	is(record_at($h, $h->applied_path), undef,
		'the applied record is gone');
	ok(record_at($h, $h->env_path('qa')),
		"and every environment's record is still readable");
};

subtest 'the three pre-flight shapes are what git refuses on' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);

	my $unsafe = fixture_preflight($h, 'safe_directory');

	# The fixture git that answers the refusal is one of the directories
	# run_genesis puts first on the path, so the row puts the same ones first
	# for the length of the row and meets the git a whole run would meet.
	local $ENV{PATH} = join(':',
		Harness::Propagation::_path_prefix($h), $ENV{PATH});

	my $safe_ok = run({dir => $unsafe, passfail => 1},
		'git', 'rev-parse', '--verify', 'HEAD');
	ok(!$safe_ok, 'git refuses the safe.directory shape');

	my $nameless = fixture_preflight($h, 'no_identity');
	my $named = run({dir => $nameless, passfail => 1},
		'git', 'config', '--get', 'user.email');
	ok(!$named, 'the identity shape has no committer identity');

	my $empty = fixture_preflight($h, 'no_commits');
	is(ref_in($empty, 'HEAD'), undef, 'and the empty shape has no commits');
};

done_testing;
