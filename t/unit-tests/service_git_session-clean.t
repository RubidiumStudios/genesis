#!/usr/bin/env perl
# Proves T63, clean means no tracked modification and nothing staged with
# untracked files ignored, and T64, a tracked modification at finish is a
# defect that takes the abort path.
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

subtest 'an untracked file blocks nothing and survives everything' => sub {
	plan tests => 8;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	# An operator's scratch file, which is nobody's business but theirs.
	put_file($h->a . '/scratch.txt', "notes to myself\n");

	my $session = $git->session(control => $h->control);
	ok(eval { $session->begin; 1 }, 'begin accepted the untracked file');
	$session->switch($h->slug('qa'));
	ok(eval { $session->finish; 1 }, 'and finish accepted it too');
	ok(-f $h->a . '/scratch.txt', 'and the file is still there');

	my $second = $git->session(control => $h->control);
	$second->begin;
	$second->switch($h->slug('qa'));
	eval { $second->abort('the run failed') };
	ok(-f $h->a . '/scratch.txt', 'an abort does not remove it either');

	# The last row is an unlike, and an unlike that could never match is a
	# row that guards nothing, so the pattern is weighed on both spellings
	# before the module is put to it.  Every git call in the module is a
	# list, which is the spelling a pattern wanting whitespace between the
	# two words would sail straight past, and the shell string form is
	# there too because a later call could be written that way.  The gap
	# allows punctuation alone, which is what keeps the reader the session
	# asks about out of the match.
	my $never = qr/\bgit\b\W{0,6}clean\b/;
	like(q{run({dir => $root, passfail => 1}, 'git', 'clean', '-fd');},
		$never, 'the pattern catches a git clean spelled as a list');
	like(q{run({dir => $root}, "git clean -fd");},
		$never, 'and one spelled as a shell string');
	unlike(q{return $git->is_clean;},
		$never, 'and it is not fooled by is_clean');

	my $module = get_file($helper::TOPDIR . '/lib/Service/Git/Session.pm');
	unlike($module, $never,
		'because abort never runs git clean, so the discard is tracked only');
};

subtest 'a tracked modification at finish names the files and aborts' => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);

	my $git = $h->git('a');
	my $w   = snapshot_w($h, copy => 'a');
	my $qa_t = $git->sha('refs/remotes/origin/' . $h->slug('qa'));

	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($h->slug('qa'));
	$git->checkout_file($control, 'qa.yml');
	$git->commit('deliver qa.yml', 'qa.yml');

	# A kit hook writing into the repository is the defect the clean check
	# names.
	put_file($h->a . '/qa.yml', "---\nkit: written by a hook\n");

	my $err = exception(sub { $session->finish });
	like($err, qr/qa\.yml/, 'finish named the file that was modified');
	like($err, qr/wrote into the repository|unexpected/i,
		'and said what kind of thing this is');
	is($git->current_branch, $h->control,
		'and it restored the branch, so working state is whole');
	is($git->sha($h->slug('qa')), $qa_t,
		'the abort path reset the branch it had committed to');
	ok($git->is_clean, 'and the tree is clean');
	assert_w_restored($w, 'working state is restored after the defect');
};

subtest 'the defect reaches the caller rather than being swallowed' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($h->slug('qa'));

	# The file has to be delivered before it can be modified, because the
	# deployment branch carries only its init blob until something writes
	# to it and an untracked file is no defect at all.
	$git->checkout_file($session->origin->{head}, 'qa.yml');
	$git->commit('deliver qa.yml', 'qa.yml');
	put_file($h->a . '/qa.yml', "---\nkit: written by a hook\n");

	my $err = exception(sub { $session->finish });
	isnt($err, '', 'finish raised rather than warning and carrying on');
	ok(!$session->active,
		'and the session is closed, so the caller decides what to exit with');
};

subtest 'a staged change at begin is refused with the tracked ones' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	put_file($h->a . '/qa.yml', "---\nkit: edited\n");
	run({dir => $h->a}, 'git', 'add', '--', 'qa.yml');
	put_file($h->a . '/scratch.txt', "notes\n");

	my $err = exception(sub { $git->session(control => $h->control)->begin });
	like($err, qr/qa\.yml/, 'the staged file is named');
	unlike($err, qr/scratch\.txt/, 'and the untracked one is not');
};

sub exception {
	my ($code) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	eval { $code->(); 1 } and return '';
	return $@;
}

done_testing;
