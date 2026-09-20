#!/usr/bin/env perl
# Proves T59: the session restores on every other exit path too, which is
# bail, a die inside a hook, and a signal, as far as Perl allows.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Genesis;
use_ok 'Service::Git::Session';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Every child spells its include paths absolutely, because the paths a test
# file reaches for are the ones it was started with and a child started in
# the harness repository has no lib of its own.
my @INC_ARGS = ('-I' . $helper::TOPDIR . '/lib', '-I' . $helper::TOPDIR . '/t');

subtest 'a bail inside the session restores working state' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $w = snapshot_w($h, copy => 'a');

	# A whole process, because at_exit hooks run from END and an in-process
	# eval never reaches them.
	my ($out, $rc, $err) = run({dir => $h->a, passfail => 0, stderr => 0},
		$^X, @INC_ARGS, '-e', <<'PERL', $h->a, $h->control, $h->slug('qa'));
use Genesis;
use Service::Git;
my ($root, $control, $branch) = @ARGV;
my $git = Service::Git->new($root);
my $session = $git->session(control => $control);
$session->begin;
$session->switch($branch);
bail("something went wrong halfway through");
PERL

	isnt($rc, 0, 'the process exited non-zero');
	like($err, qr/something went wrong halfway through/,
		'and said what went wrong');
	assert_w_restored($w, 'and the branch, cwd, tree, and index are back');
	ok($h->git('a')->is_clean, 'with a clean tree');
};

subtest 'the net discards and resets rather than only changing back' => sub {
	plan tests => 4;

	# The other rows in this file pass against a net that only checks the
	# branch back out, because they leave nothing behind to clean up.  This
	# one leaves both kinds of debris, a commit on the deployment branch and
	# a half-written file over it, so it can tell a bare restore from the
	# abort the net has to make.
	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git  = $h->git('a');
	my $qa_t = $git->sha('refs/remotes/origin/' . $h->slug('qa'));
	my $w    = snapshot_w($h, copy => 'a');

	my ($out, $rc, $err) = run({dir => $h->a, passfail => 0, stderr => 0},
		$^X, @INC_ARGS, '-e', <<'PERL', $h->a, $h->control, $h->slug('qa'));
use Genesis;
use Service::Git;
my ($root, $control, $branch) = @ARGV;
my $git = Service::Git->new($root);
my $session = $git->session(control => $control);
$session->begin;
my $head = $session->origin->{head};
$session->switch($branch);
$git->checkout_file($head, 'qa.yml');
$git->commit('deliver qa.yml', 'qa.yml');
open my $fh, '>', "$root/qa.yml" or die "cannot write qa.yml: $!\n";
print $fh "---\nkit: half written\n";
close $fh;
bail("the run failed halfway through");
PERL

	isnt($rc, 0, 'the process exited non-zero');
	is($git->sha($h->slug('qa')), $qa_t,
		'the branch the run committed to sits back at its remote-tracking ref');
	ok($git->is_clean,
		'and the half-written file went with the commit that carried it');
	assert_w_restored($w, 'and working state is whole');
};

subtest 'a die inside a hook restores working state' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $w = snapshot_w($h, copy => 'a');

	my ($out, $rc, $err) = run({dir => $h->a, passfail => 0, stderr => 0},
		$^X, @INC_ARGS, '-e', <<'PERL', $h->a, $h->control, $h->slug('qa'));
use Genesis;
use Service::Git;
my ($root, $control, $branch) = @ARGV;
my $git = Service::Git->new($root);
my $session = $git->session(control => $control);
$session->begin;
$session->switch($branch);
my $hook = sub { die "the kit hook exploded\n" };
$hook->();
PERL

	isnt($rc, 0, 'the process exited non-zero');
	like($err, qr/the kit hook exploded/, 'and named the die');
	assert_w_restored($w, 'and working state is restored');
};

subtest 'a signal restores working state' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $w = snapshot_w($h, copy => 'a');

	# bin/genesis routes INT and TERM to bail, so the signal path reaches
	# the same END hooks the bail path does.
	my ($out, $rc, $err) = run({dir => $h->a, passfail => 0, stderr => 0},
		$^X, @INC_ARGS, '-e', <<'PERL', $h->a, $h->control, $h->slug('qa'));
use Genesis;
use Service::Git;
my ($root, $control, $branch) = @ARGV;
$SIG{INT} = $SIG{TERM} = sub {bail("Genesis halted due to user interrupt")};
my $git = Service::Git->new($root);
my $session = $git->session(control => $control);
$session->begin;
$session->switch($branch);
kill 'TERM', $$;
sleep 5;
PERL

	isnt($rc, 0, 'the process exited non-zero');
	like($err, qr/user interrupt/, 'and named the interrupt');
	assert_w_restored($w, 'and working state is restored');
};

subtest 'a restore the net cannot make is named' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	my ($out, $rc, $err) = run({dir => $h->a, passfail => 0, stderr => 0},
		$^X, @INC_ARGS, '-e', <<'PERL', $h->a, $h->control, $h->slug('qa'));
use Genesis;
use Service::Git;
my ($root, $control, $branch) = @ARGV;
my $git = Service::Git->new($root);
my $session = $git->session(control => $control);
$session->begin;
$session->switch($branch);
# A branch that no longer exists cannot be returned to.  The
# remote-tracking ref goes with it, because git would otherwise make the
# local branch again from the remote of that name and the return would
# quietly succeed.
run({dir => $root, passfail => 1}, 'git', 'branch', '-D', $control);
run({dir => $root, passfail => 1},
	'git', 'update-ref', '-d', "refs/remotes/origin/$control");
bail("the run failed");
PERL

	isnt($rc, 0, 'the process exited non-zero');
	like($err, qr/\Q@{[$h->control]}\E/,
		'and named the branch it could not return to');
};

subtest 'the net is registered through at_exit and not DESTROY' => sub {
	plan tests => 2;

	# bail exits outside an eval, Perl runs END before global
	# destruction, and the order after that is undefined, so a net in
	# DESTROY fires too late or not at all.
	my $session = get_file($helper::TOPDIR . '/lib/Service/Git/Session.pm');
	like($session, qr/Genesis::Commands::at_exit/,
		'the session registers its last-resort abort through at_exit');

	my $git = get_file($helper::TOPDIR . '/lib/Service/Git.pm');
	my ($destroy) = $git =~ /sub DESTROY \{(.*?)\n\}/s;
	unlike($destroy, qr/checkout|restore/,
		'and DESTROY no longer restores anything');
};

done_testing;
