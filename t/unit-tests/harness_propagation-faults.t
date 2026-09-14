#!/usr/bin/env perl
# Proves T5: a row can ask for the third checkout_file to die, and nothing
# else behaves differently.
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

subtest 'the third checkout_file dies and the first two ran' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files => {
			'qa.yml'          => "---\nkit: dev\n",
			'ops/one.yml'     => "---\none: 1\n",
			'ops/two.yml'     => "---\ntwo: 2\n",
			'ops/three.yml'   => "---\nthree: 3\n",
		},
		message => 'four files',
		push    => 1,
	);

	my $git = fault_git($h);
	fail_on($git, 'checkout_file', 3, message => 'the harness stopped here');

	$git->checkout($h->slug('qa'));
	my @wrote;
	for my $path (qw(qa.yml ops/one.yml ops/two.yml ops/three.yml)) {
		eval {$git->checkout_file($control, $path); push @wrote, $path; 1}
			or last;
	}

	is(scalar @wrote, 2, 'the first two calls ran');
	like($@, qr/the harness stopped here/, 'the third died with the given message');

	my @steps = step_log($git);
	my @files = grep {$_->[0] eq 'checkout_file'} @steps;
	is(scalar @files, 3, 'exactly three checkout_file calls were made');

	is($steps[0][0], 'checkout', 'the checkout before them ran');
	ok(!(grep {$_->[0] eq 'commit'} @steps), 'no later step of the sequence ran');
};

subtest 'no other git step behaves differently' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'one file',
		push    => 1,
	);

	my $git = fault_git($h);
	fail_on($git, 'checkout_file', 3);

	$git->checkout($h->slug('qa'));
	ok(eval {$git->checkout_file($control, 'qa.yml'); 1},
		'a checkout_file below the armed count still runs');

	my ($content) = run({dir => $h->a}, 'git', 'show', ':qa.yml');
	like($content, qr/kit: dev/, 'and it did the real work');
};

subtest 'a handle taken before the fault faults too' => sub {
	# Service::Git caches one instance per repository and hands it to every
	# later caller, so a row that read the repository before it armed a fault
	# would otherwise keep a handle that never faults.
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $early = $h->git('a');
	isa_ok($early, 'Service::Git', 'the handle taken before the fault');

	fault_git($h);
	fail_on($h->git('a'), 'checkout', 1, message => 'the harness stopped here');

	ok(!eval {$early->checkout($h->slug('qa')); 1},
		'the handle the row already held dies');
	like($@, qr/the harness stopped here/, 'with the armed message');
};

subtest 'an armed plan leaves an unaffected command alone' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $git = fault_git($h);
	fail_on($git, 'push', 1, message => 'the harness stopped the push');

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'ping');
	is($exit, 0, 'a command that takes no git step is unaffected');

	my @steps = step_log($git);
	ok(!(grep {$_->[0] eq 'push'} @steps),
		'and the armed step was never reached');
};

subtest 'the plan reaches a spawned command' => sub {
	# genesis ping builds no git handle, so the row above says only that the
	# plan disturbs nothing.  This one spawns a child that does take a git
	# step, under the environment run_genesis builds, and shows that the
	# override intercepted the step in the child and that an armed fault
	# fired there.
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $git = fault_git($h);

	my ($out, $rc, $err) = _fetch_in_child($h);
	is($rc, 0, 'the child took the step and lived');
	my @steps = step_log($git);
	is(scalar(grep {$_->[0] eq 'fetch_branch'} @steps), 1,
		'the step the child took is in the log');

	reset_steps($git);
	fail_on($git, 'fetch_branch', 1, message => 'the harness stopped the fetch');

	($out, $rc, $err) = _fetch_in_child($h);
	isnt($rc, 0, 'the child armed against dies');
	like($err, qr/the harness stopped the fetch/,
		'with the armed message on its stderr');

	@steps = step_log($git);
	is(scalar(grep {$_->[0] eq 'fetch_branch'} @steps), 1,
		'and the step was recorded before it died');
};

# _fetch_in_child - fetch one branch from a child perl, under the environment
# a spawned command runs in.  It is the machinery the rows above need rather
# than repository state, so it sits beside them.  The environment itself comes
# from the harness, which composes the same block for a whole command, so what
# a spawned command needs is said in one place and not in three.
sub _fetch_in_child {
	my ($h) = @_;
	# Not the control branch, which copy A has checked out, because git
	# refuses a forced fetch into the branch the working tree is on.
	return $h->run_in_child(
		'use Service::Git; Service::Git->new($ARGV[0])->fetch_branch($ARGV[1]);',
		$h->a, $h->slug('qa'));
}

subtest 'the remote can be severed and restored' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $git = fault_git($h);
	sever_remote($h);

	ok(!eval {$git->push('origin', $h->control); 1}, 'a push to a severed remote dies');
	like($@, qr/Could not resolve host/,
		'with the text a real unreachable remote emits');
	my $remote = $h->r;
	like($@, qr/\Q$remote\E/, 'and it names the remote it could not reach');

	restore_remote($h);
	reset_steps($git);
	ok(eval {$git->push('origin', $h->control); 1},
		'and the push works again once the remote is restored');
};

subtest 'the session lock is held by a child and dropped with it' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $lock = $h->a . '/.git/genesis-session.lock';

	my $pid = hold_session_lock($h, command => 'genesis propagate');
	ok($pid > 0, 'the holder is a real process');

	my ($held_pid, $held_command) = split /\n/, helper::get_file($lock);
	is($held_pid, $pid, 'the first line is the holder pid');
	is($held_command, 'genesis propagate', 'the second line is its command');

	ok(!_can_lock($lock), 'a second taker cannot have the lock');

	release_session_lock($h, $pid, hard => 1);
	ok(_can_lock($lock), 'and the kernel drops it when the holder is killed');
};

subtest 'a new harness takes back the variables the last one armed' => sub {
	plan tests => 4;

	my $one = make_harness(envs => ['qa'], vault => 0);
	fault_git($one);
	shuttle_spy($one);
	is($ENV{GENESIS_HARNESS_GIT_PLAN}, $one->{fault}{plan},
		'arming a fault names the plan in the parent, where a child reads it');
	ok(exists $ENV{GENESIS_SHUTTLE_SPY}, 'and the spy names its log there too');

	make_harness(envs => ['qa'], vault => 0);
	ok(!exists $ENV{GENESIS_HARNESS_GIT_PLAN},
		'building a second harness takes the plan away again');
	ok(!exists $ENV{GENESIS_SHUTTLE_SPY},
		'and takes the spy away with it');
};

subtest 'a child runs under the plan its own harness armed' => sub {
	plan tests => 4;

	my $one = make_harness(envs => ['qa'], vault => 0);
	init_branch($one, 'qa');
	my $git = fault_git($one);
	fail_on($git, 'fetch_branch', 1, message => 'the armed refusal');

	my ($out, $rc) = $one->run_in_child(
		'use Service::Git; Service::Git->new($ARGV[0])->fetch_branch($ARGV[1]);',
		$one->a, $one->slug('qa'));
	isnt($rc, 0, 'the armed step took the child down');
	is(scalar(grep {$_->[0] eq 'fetch_branch'} step_log($git)), 1,
		'and the call landed in this harness own step log');

	# What the parent already carries has to reach the child, because the
	# suite runs under -MCarp::Always and a child that lost it answers a
	# death with less of the story.
	{
		local $ENV{PERL5OPT} = join(' ', ($ENV{PERL5OPT} // ()), '-Mvars');
		my ($carried) = $one->run_in_child('print $ENV{PERL5OPT};');
		like($carried, qr/-Mvars/,
			'a PERL5OPT the parent carries reaches the child as well');
	}

	my $two = make_harness(envs => ['dev'], vault => 0);
	ok(!eval {$two->run_in_child('exit 0'); 1},
		'a harness that has armed no plan refuses to run a child at all');
};

subtest 'a holder that never takes the lock is refused, not waited out' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);

	# A git directory the holder cannot write, so it exits without ever
	# taking the lock.  That is the fixture failing rather than the code
	# under test, and the wait has to say so.
	my $where = "$h->{base}/unwritable";
	mkdir $where or die "cannot make $where: $!";
	mkdir "$where/.git" or die "cannot make $where/.git: $!";
	$h->{unwritable} = $where;
	chmod 0500, "$where/.git";

	ok(!eval {hold_session_lock($h, copy => 'unwritable'); 1},
		'the wait refuses rather than handing back a holder of nothing');
	like($@, qr/exited before it took/,
		'and the refusal names what the holder did');

	chmod 0700, "$where/.git";
};

subtest 'the wait answers on this holder and not on a file with content' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $lock = $h->a . '/.git/genesis-session.lock';

	my $first = hold_session_lock($h, command => 'genesis propagate');
	is((split /\n/, helper::get_file($lock))[0], $first,
		'the first holder wrote its own pid into the lock file');

	# The lock file now has something in it and the first holder still holds
	# the flock, so a second holder cannot have it.  A wait that asked only
	# whether the file had content would read the first holder's line and
	# answer at once with a pid that holds nothing.
	ok(!eval {hold_session_lock($h); 1},
		'a second holder that cannot have the lock is refused');
	like($@, qr/never took/, 'rather than answered on what the first wrote');

	release_session_lock($h, $first, hard => 1);
};

subtest 'a holder the lock never reaches goes down with the refusal' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $lock = $h->a . '/.git/genesis-session.lock';

	# A process outside the harness sits on the lock and writes nothing, so
	# the harness's own holder blocks where it asks for it.  That is the
	# other refusal, and unlike the one above it fires with the holder still
	# running, which is why the refusal has to take it down.
	my $stranger = _stranger_holding($lock);

	ok(!eval {hold_session_lock($h); 1},
		'the wait refuses rather than handing back a holder of nothing');
	like($@, qr/never took/, 'and the refusal says the holder never took it');

	my ($holder) = $@ =~ /holder (\d+)/;
	ok($holder && !kill(0, $holder),
		'while the holder itself is gone rather than left on the lock');

	kill('KILL', $stranger);
	waitpid($stranger, 0);
};

# _stranger_holding - a process outside the harness sitting on a lock file,
# writing nothing into it.  It builds no repository, vault, or API state, so
# it is machinery of this file rather than a harness helper, and it sits
# beside the row that needs it.
sub _stranger_holding {
	my ($file) = @_;
	require Fcntl;
	require POSIX;

	# The parent is told the lock is held down a pipe rather than by polling
	# the file, because the stranger deliberately writes nothing there.
	pipe(my $reader, my $writer) or die "cannot open a pipe: $!";
	my $parent = $$;
	my $pid = fork();
	die "cannot fork a stranger: $!" unless defined $pid;
	unless ($pid) {
		close $reader;
		open my $fh, '>>', $file or POSIX::_exit(2);
		flock($fh, Fcntl::LOCK_EX()) or POSIX::_exit(2);
		syswrite($writer, "held\n");

		# Never outlive the row that forked us, so a row that dies leaves the
		# lock free for the next one.
		for (1 .. 600) {
			POSIX::_exit(0) if getppid() != $parent;
			select undef, undef, undef, 0.1;
		}
		POSIX::_exit(0);
	}
	close $writer;
	scalar <$reader>;
	close $reader;
	return $pid;
}

# _can_lock - whether this process can take the lock without waiting.  It is
# an assertion helper for the rows above, so it sits beside them.
sub _can_lock {
	my ($file) = @_;
	require Fcntl;
	open my $fh, '>>', $file or return 0;
	my $got = flock($fh, Fcntl::LOCK_EX() | Fcntl::LOCK_NB()) ? 1 : 0;
	flock($fh, Fcntl::LOCK_UN()) if $got;
	close $fh;
	return $got;
}

done_testing;
