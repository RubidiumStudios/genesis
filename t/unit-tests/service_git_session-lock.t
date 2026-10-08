#!/usr/bin/env perl
# Proves T67, a second switch in one working tree is refused by name; T68,
# a command that never switches proceeds under a held lock; T69, the kernel
# releases the lock when its holder dies; T71, the lock is per working tree
# and nothing is handed to the child; and T75, a switch that removes the
# current directory finishes at the repository root.  Under D115 the lock is
# also taken before a session begins and kept by its switch, let go by a run
# that refuses before it begins, and read for its holder without being taken.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Cwd qw/getcwd/;
use Genesis;
use Genesis::Exit qw/TEMPFAIL/;
use_ok 'Service::Git::Session';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a second switch is refused naming the holder' => sub {
	plan tests => 6;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	my $pid = hold_session_lock($h, copy => 'a', command => 'genesis propagate');
	ok(-f $git->git_dir . '/genesis-session.lock',
		'the lock sits on genesis-session.lock in the git directory');

	my $session = $git->session(control => $h->control, remote => 'origin');
	$session->begin;

	# I1 promises the directory at exit is the one at entry, and a refusal
	# is an exit, so the refused switch has to leave us where it found us.
	my $here = getcwd();
	my $err = exception(sub { $session->switch($h->slug('qa')) });

	like($err, qr/\b$pid\b/, "the refusal names the holder's pid");
	like($err, qr/genesis propagate/, 'and the command it is running');
	is($git->current_branch, $h->control, 'nothing switched');
	is(getcwd(), $here, 'and we are standing where we were');

	release_session_lock($h, $pid);
	$session->switch($h->slug('qa'));
	is($git->current_branch, $h->slug('qa'),
		'and the switch succeeds once the holder lets go');
	$session->finish;
};

subtest 'a second process that switches is refused and exits TEMPFAIL' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	my $pid = hold_session_lock($h, copy => 'a', command => 'genesis propagate');
	my $second = fork_and_switch($h, $h->slug('qa'));
	like($second->{err}, qr/\b$pid\b/, 'the second process names the holder');
	is($second->{exit}, TEMPFAIL,
		'and exits TEMPFAIL, since the holder will let go');
	release_session_lock($h, $pid);
};

subtest 'a command that never switches proceeds under the lock' => sub {
	# Four, because run_genesis asserts the restoration in its own words.
	plan tests => 4;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	my $pid = hold_session_lock($h, copy => 'a', command => 'genesis propagate');

	# A hook shelling out to genesis inside a deploy is unaffected, because
	# a command that never switches never touches the lock, and
	# pipeline-describe is a command that changes no branch.
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-describe');
	is($exit, 0, 'a command that changes no branch runs under a held lock');
	unlike($err, qr/\b$pid\b/, 'and never meets the lock at all');

	my $switcher = fork_and_switch($h, $h->slug('qa'));
	isnt($switcher->{exit}, 0, 'while a process that would switch is refused');
	release_session_lock($h, $pid);
};

subtest 'the kernel releases the lock when its holder dies' => sub {
	plan tests => 3;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	my $pid = hold_session_lock($h, copy => 'a');
	release_session_lock($h, $pid, hard => 1);

	my $session = $git->session(control => $h->control, remote => 'origin');
	$session->begin;
	ok(eval { $session->switch($h->slug('qa')); 1 },
		'a later switch succeeds with no break-lock option anywhere');
	is($git->current_branch, $h->slug('qa'), 'and it actually switched');

	# Every refusal above names a pid the harness wrote.  This is the one
	# row that reads back what the product itself wrote, so the writer and
	# the readers are held to the same two-line form.
	open my $lock, '<', $git->git_dir . '/genesis-session.lock'
		or die "cannot read the session lock: $!\n";
	chomp(my $wrote = <$lock> // '');
	close $lock;
	is($wrote, "$$", 'and our own pid is on the first line of the lock it took');

	$session->finish;
};

subtest 'the lock is per working tree' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	# init_branch writes the branch in copy A and pushes it, so copy B has
	# to fetch before it has anything of that name to switch to.
	refresh($h, 'b', $h->slug('qa'));

	my $a = $h->git('a');
	my $b = $h->git('b');
	isnt($a->git_dir, $b->git_dir,
		'two copies of one repository have their own git directories');

	my $pid = hold_session_lock($h, copy => 'a');
	my $sb = $b->session(control => $h->control, remote => 'origin');
	$sb->begin;
	ok(eval { $sb->switch($h->slug('qa')); 1 },
		"a held lock in copy A does not reach copy B");
	$sb->finish;

	# Read the refusal rather than the bare death, since a failed checkout
	# or an unopened session would die here too and say nothing about the
	# lock.
	my $sa = $a->session(control => $h->control, remote => 'origin');
	$sa->begin;
	my $refused = exception(sub { $sa->switch($h->slug('qa')) });
	like($refused, qr/\b$pid\b/,
		'while copy A is still refused, naming the holder in copy A');

	# The refused switch left the session open on control, and a session
	# still open at exit is what the last-resort net aborts and complains
	# about, so this row closes the one it opened.
	$sa->finish;
	release_session_lock($h, $pid);
};

subtest 'the child takes the lock itself after the session has finished' => sub {
	plan tests => 3;

	# Nothing is handed from one process to another.  The post-deploy child
	# takes the lock for itself, which it can only do once the deploy's own
	# session has released it.
	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	my $session = $git->session(control => $h->control, remote => 'origin');
	$session->begin;
	$session->switch($h->slug('qa'));

	# While the session holds the lock, a second process is refused.
	my $second = fork_and_switch($h, $h->slug('qa'));
	isnt($second->{exit}, 0,
		'a second process is refused while the session holds it');

	$session->finish;

	my $after = fork_and_switch($h, $h->slug('qa'));
	is($after->{exit}, 0,
		'and takes the lock for itself once the first session finished');
	unlike($after->{err}, qr/handed|inherit/i,
		'having taken it rather than received it');
};

subtest 'a switch that removes the current directory lands at the root' => sub {
	plan tests => 3;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	# The deployment root exists on control and not on the environment
	# branch, which is the shape that removes the directory the session
	# stands in when it switches.
	mkdir_or_fail($h->a . '/doomsday');
	put_file($h->a . '/doomsday/env.yml', "---\nkit: {}\n");
	commit_on_control($h,
		files   => {'doomsday/env.yml' => "---\nkit: {}\n"},
		message => 'add a deployment root',
	);
	stand_on($h, $h->control, dir => 'doomsday');

	my $session = $git->session(control => $h->control, remote => 'origin');
	$session->begin;
	$session->switch($h->slug('qa'));

	is($git->current_branch, $h->slug('qa'), 'the branch actually changed');
	is(getcwd(), $git->root, 'and we are at the repository root');
	ok(-d getcwd(), 'which is a directory that exists, so relative paths resolve');

	$session->finish;
};

subtest 'the lock file stops naming a holder once it is released' => sub {
	plan tests => 3;

	# The kernel drops the flock when the session finishes, and the file
	# outlives it.  A reader that tests a holder's liveness reads the pid
	# line, so a file still naming the process that just let go would be
	# read as held for as long as that process runs, which is the rest of
	# the command.  Emptying it on release is what makes the line mean
	# what a reader takes it to mean.
	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');
	my $path = $git->git_dir . '/genesis-session.lock';

	my $session = $git->session(control => $h->control, remote => 'origin');
	$session->begin;
	$session->switch($h->slug('qa'));
	is(read_first_line($path), "$$",
		'the lock names our pid while the session holds it');

	$session->finish;
	is(read_first_line($path), '',
		'and names nobody once the session has let go');

	# The take side truncates before it writes, so an emptied file is a
	# shape it already expects and a later session takes the lock as
	# readily as it took the first one.
	my $second = $git->session(control => $h->control, remote => 'origin');
	ok(eval {$second->begin; $second->switch($h->slug('qa')); 1},
		'and a later session takes the same file again');
	$second->finish;
};

# D115 takes the lock first, before it reads R or asks anything, and
# switches only once every question has passed, so the lock is taken
# without a switch and the switch that follows reuses it.
subtest 'the lock is taken before the session begins and kept by its switch' => sub {
	plan tests => 6;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git  = $h->git('a');
	my $path = $git->git_dir . '/genesis-session.lock';

	my $session = $git->session(control => $h->control, remote => 'origin');
	$session->take_lock;
	is(read_first_line($path), "$$", 'the lock names us before anything began');
	is($git->current_branch, $h->control, 'and nothing switched to take it');

	my $second = fork_and_switch($h, $h->slug('qa'));
	like($second->{err}, qr/\b$$\b/, 'a second process is refused naming us');
	is($second->{exit}, TEMPFAIL, 'at TEMPFAIL');

	$session->begin;
	ok(eval {$session->switch($h->slug('qa')); 1},
		'the switch that follows reuses the lock it holds');
	$session->finish;
	is(read_first_line($path), '', 'and finishing lets it go');
};

subtest 'a lock taken for a run that refuses before it begins is let go' => sub {
	plan tests => 3;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git  = $h->git('a');
	my $path = $git->git_dir . '/genesis-session.lock';

	my $session = $git->session(control => $h->control, remote => 'origin');
	$session->take_lock;
	$session->release_lock;
	is(read_first_line($path), '', 'the file names nobody');

	my $second = fork_and_switch($h, $h->slug('qa'));
	is($second->{exit}, 0, 'and another process takes the lock')
		or diag($second->{err});
	ok(!$session->active, 'the session that let go never began');
};

subtest 'taking a lock another holds refuses before anything moves' => sub {
	plan tests => 4;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	my $pid = hold_session_lock($h, copy => 'a', command => 'genesis propagate');
	my $session = $git->session(control => $h->control, remote => 'origin');
	my $here = getcwd();
	my $err = exception(sub { $session->take_lock });

	like($err, qr/\b$pid\b/, "the refusal names the holder's pid");
	like($err, qr/genesis propagate/, 'and its command');
	is($git->current_branch, $h->control, 'nothing switched');
	is(getcwd(), $here, 'and we stand where we were');
	release_session_lock($h, $pid);
};

# pipeline-status never takes the lock (D115), and says when a run holds it,
# so the holder is read from the file without the lock being taken.
subtest 'the holder is read from the file without taking the lock' => sub {
	plan tests => 6;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	is(Service::Git::Session->lock_holder($git), undef, 'nobody holds a fresh clone');

	my $pid = hold_session_lock($h, copy => 'a', command => 'genesis propagate');
	my $holder = Service::Git::Session->lock_holder($git);
	is($holder && $holder->{pid}, $pid, 'a live holder is named by its pid');
	is($holder && $holder->{command}, 'genesis propagate', 'and its command');

	my $second = fork_and_switch($h, $h->slug('qa'));
	is($second->{exit}, TEMPFAIL, 'and reading took nothing from it');

	# Killed hard, the holder cannot empty the file, so it names a process
	# that is gone, which is no holder at all.
	release_session_lock($h, $pid, hard => 1);
	is(Service::Git::Session->lock_holder($git), undef,
		'a file naming a process that is gone names no holder');

	my $session = $git->session(control => $h->control, remote => 'origin');
	$session->take_lock;
	$session->release_lock;
	is(Service::Git::Session->lock_holder($git), undef,
		'and neither does a file emptied on release');
};

sub read_first_line {
	my ($path) = @_;
	return '' unless -f $path;
	open my $fh, '<', $path or die "cannot read the session lock: $!\n";
	chomp(my $line = <$fh> // '');
	close $fh;
	return $line;
}

sub exception {
	my ($code) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	eval { $code->(); 1 } and return '';
	return $@;
}

done_testing;
