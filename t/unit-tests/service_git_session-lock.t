#!/usr/bin/env perl
# Proves T67, a second switch in one working tree is refused by name; T68,
# a command that never switches proceeds under a held lock; T69, the kernel
# releases the lock when its holder dies; T71, the lock is per working tree
# and nothing is handed to the child; and T75, a switch that removes the
# current directory finishes at the repository root.
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

	my $session = $git->session(control => $h->control);
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

	my $session = $git->session(control => $h->control);
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
	my $sb = $b->session(control => $h->control);
	$sb->begin;
	ok(eval { $sb->switch($h->slug('qa')); 1 },
		"a held lock in copy A does not reach copy B");
	$sb->finish;

	# Read the refusal rather than the bare death, since a failed checkout
	# or an unopened session would die here too and say nothing about the
	# lock.
	my $sa = $a->session(control => $h->control);
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

	my $session = $git->session(control => $h->control);
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
	# branch, which is the shape the fix 920294c5 was written for.
	mkdir_or_fail($h->a . '/doomsday');
	put_file($h->a . '/doomsday/env.yml', "---\nkit: {}\n");
	commit_on_control($h,
		files   => {'doomsday/env.yml' => "---\nkit: {}\n"},
		message => 'add a deployment root',
	);
	stand_on($h, $h->control, dir => 'doomsday');

	my $session = $git->session(control => $h->control);
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

	my $session = $git->session(control => $h->control);
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
	my $second = $git->session(control => $h->control);
	ok(eval {$second->begin; $second->switch($h->slug('qa')); 1},
		'and a later session takes the same file again');
	$second->finish;
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
