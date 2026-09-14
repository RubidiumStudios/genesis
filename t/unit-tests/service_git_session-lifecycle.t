#!/usr/bin/env perl
# Proves T58, the session restores working state on a clean run, and T62,
# a session refuses to start over uncommitted work.
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
use Service::Git;
use_ok 'Service::Git::Session';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a clean run leaves working state exactly as it found it' => sub {
	plan tests => 6;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	my $w = snapshot_w($h, copy => 'a');
	my $session = $git->session(control => $h->control);

	$session->begin;
	is($session->origin->{branch}, $h->control,
		'begin records the branch the operator stood on');
	is($session->origin->{head}, $git->sha('HEAD'),
		'begin records the HEAD sha');
	is($session->origin->{cwd}, getcwd(),
		'begin records the current directory');

	$session->switch($h->slug('qa'));
	$git->checkout_file($session->origin->{head}, 'qa.yml');
	$git->commit('deliver qa.yml', 'qa.yml');
	isnt($git->current_branch, $h->control,
		'the session is standing on the deployment branch');

	$session->finish;
	ok(!$session->active, 'the session is closed');
	assert_w_restored($w, 'branch, HEAD, cwd, tree, and index are all back');
};

subtest 'begin refuses over a tracked modification' => sub {
	plan tests => 3;

	my $h   = make_harness(envs => ['qa']);
	my $git = $h->git('a');
	put_file($h->a . '/qa.yml', "---\nkit: edited by hand\n");

	my $session = $git->session(control => $h->control);
	my $err = exception(sub { $session->begin });

	like($err, qr/uncommitted/i, 'begin refused');
	like($err, qr/qa\.yml/, 'and named the file that is modified');
	ok(!$session->active, 'nothing was opened');
};

subtest 'begin refuses over a staged change, before its first write' => sub {
	plan tests => 3;

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	put_file($h->a . '/staged.yml', "---\nstaged: true\n");
	run({dir => $h->a}, 'git', 'add', '--', 'staged.yml');

	my $before = $git->sha($h->slug('qa'));
	my $session = $git->session(control => $h->control);
	my $err = exception(sub { $session->begin });

	like($err, qr/staged\.yml/, 'begin named the staged file');
	is($git->sha($h->slug('qa')), $before,
		'the refusal came before any write to a deployment branch');
	is($git->current_branch, $h->control,
		'and before any switch');
};

subtest 'a clean tree and index are accepted' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa']);
	my $git = $h->git('a');

	my $session = $git->session(control => $h->control);
	ok($session->begin, 'begin accepted a clean tree and index');
	ok($session->active, 'and the session is open');
	$session->finish;
};

subtest 'begin reaches the pre-flight through the shared helper' => sub {
	plan tests => 3;

	# The other half of T72: begin and genesis new run the same code, so
	# H20 closes in the session for every command that switches.
	my $module = get_file('lib/Service/Git/Session.pm');
	like($module, qr/->preflight\b/,
		'begin calls the helper rather than classifying its own failures');
	unlike($module, qr/dubious ownership|safe\.directory/,
		'and holds no second copy of the classification');

	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'no_identity');
	my $git  = Service::Git->new($path);

	# The fixture marks the repository and the harness git turns that marker
	# into the shape, so that git has to be first on the path for as long as
	# the call runs, which is what a row reading a shape itself arranges.
	local $ENV{PATH} = $h->preflight_bin . ":$ENV{PATH}";

	my $err  = exception(sub { $git->session(control => 'control')->begin });
	like($err, qr/no committer identity/,
		'so a fixture with no identity fails in begin naming the fix');
};

# One local helper, because an assertion helper lives beside its test.
sub exception {
	my ($code) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	eval { $code->(); 1 } and return '';
	return $@;
}

done_testing;
