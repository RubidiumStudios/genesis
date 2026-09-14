#!/usr/bin/env perl
# Proves T70: sessions are sequential and keyed on their handle.
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

subtest 'a second session inside a first is refused' => sub {
	plan tests => 3;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($h->slug('qa'));

	my $err = exception(sub { $git->session->begin });
	like($err, qr/already open/i, 'the nested begin refused');
	like($err, qr/nested/i, 'and said why');
	is($git->current_branch, $h->slug('qa'),
		'the first session still holds its branch');

	$session->finish;
};

subtest 'control after a deployment branch is a second session' => sub {
	plan tests => 6;

	# The operator stands on a deployment branch, so every row below reads a
	# branch the session had to move us to.  With the tree left on control,
	# both the switch to control and the restore to control are no-ops and
	# the rows pass whether or not the session does anything at all.
	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	stand_on($h, $h->slug('qa'));
	my $git = $h->git('a');

	my $first = $git->session(control => $h->control);
	$first->begin;
	$first->switch($h->control);
	is($git->current_branch, $h->control, 'the first session reached control');
	$first->finish;
	ok(!$first->active, 'the first session finished');
	is($git->current_branch, $h->slug('qa'),
		'and stood us back on the deployment branch');

	my $second = $git->session(control => $h->control);
	$second->begin;
	$second->switch($h->control);
	is($git->current_branch, $h->control, 'the second session reached control');
	ok($second->active, 'and only one session is open at a time');
	$second->finish;
	is($git->current_branch, $h->slug('qa'), 'with the branch restored');
};

subtest 'two handles for two working trees hold one session each' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	my $a = $h->git('a');
	my $b = $h->git('b');
	isnt($a, $b, 'the two copies are two handles');

	my $sa = $a->session(control => $h->control);
	my $sb = $b->session(control => $h->control);
	isnt($sa, $sb, 'and each handle has its own session');

	$sa->begin;
	$sb->begin;
	ok($sa->active && $sb->active,
		'both are open at once, because the key is the handle');

	$sa->finish;
	$sb->finish;
	ok(!$sa->active && !$sb->active, 'and both close independently');
};

subtest 'one handle answers with one session' => sub {
	plan tests => 1;

	my $h   = make_harness(envs => ['qa']);
	my $git = $h->git('a');
	is($git->session, $git->session,
		'asking twice for the session gives the same object');
};

sub exception {
	my ($code) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	eval { $code->(); 1 } and return '';
	return $@;
}

done_testing;
