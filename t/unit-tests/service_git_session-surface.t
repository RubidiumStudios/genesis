#!/usr/bin/env perl
# Proves the consumed half of T58 and T64: a clean finish answers finished
# true and finish_if_clean true, a tracked modification at finish answers
# both false and names the paths, and a branch the caller says it committed
# to is in the set the abort resets.
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

subtest 'a clean finish answers finished and finish_if_clean' => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	refresh($h, 'a', $h->control, $h->slug('qa'));
	my $git = $h->git('a');

	my $session = $git->session(control => $h->control);
	ok(!$session->finished, 'a session that never opened is not finished');

	# A clean tree is not a finish.  The answer says whether the session
	# finished, and there was no session here to finish.
	ok(!$session->finish_if_clean,
		'and finish_if_clean says so over a tree with nothing modified');

	$session->begin;
	$session->switch($h->slug('qa'));
	is_deeply($session->modified_paths, [],
		'a clean tree reports no modified paths');

	ok($session->finish_if_clean, 'finish_if_clean finished the session');
	ok($session->finished, 'and the session says it finished');
	is($git->current_branch, $h->control, 'and we are back on control');
};

subtest 'a tracked modification at finish is reported and not finished' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	refresh($h, 'a', $h->control, $h->slug('qa'));
	my $git = $h->git('a');

	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($h->slug('qa'));

	# The init blob is the one file the deployment branch carries, so a hand
	# edit of it is the tracked modification that makes the tree unclean.
	put_file($h->a . '/init', "edited by hand\n");

	is_deeply($session->modified_paths, ['init'],
		'the modified path is named as git spells it');
	ok(!$session->finish_if_clean, 'finish_if_clean declined to finish');
	ok(!$session->finished, 'and the session is not finished');
	ok($session->active, 'and it is still open for the caller to abort');

	# The caller's next move, made here so that nothing is left open for the
	# exit net to find when this file ends.
	exception(sub {$session->abort('there were changes')});
};

subtest 'the session hands back its handle and takes a recorded commit' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	refresh($h, 'a', $h->control, $h->slug('qa'));
	my $git = $h->git('a');

	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($h->slug('qa'));

	is($session->git, $git, 'the session hands back the handle it was built on');

	$session->_record_commit($h->slug('qa'));
	is_deeply([$session->committed_branches], [$h->slug('qa')],
		'a recorded branch is in the set the abort resets');

	$session->finish;
	ok($session->finished, 'and the session finished cleanly afterwards');
};

subtest 'a session opened a second time answers for itself alone' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	refresh($h, 'a', $h->control, $h->slug('qa'));
	my $git = $h->git('a');

	# The handle builds the session once and answers with that object
	# afterwards, so control after a deployment branch is this same session
	# opened again rather than a second one.
	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($h->slug('qa'));
	$session->finish;
	is($session->on, $h->slug('qa'), 'the first session names what it stood on');

	$session->begin;
	ok(!$session->finished,
		'a second begin takes back the first one\'s finish');
	is($session->on, undef, 'and the target it stood on');
	is_deeply([$session->committed_branches], [],
		'and the branches it committed to');

	$session->finish;
};

sub exception {
	my ($code) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	eval {$code->(); 1} and return '';
	return $@;
}

done_testing;
