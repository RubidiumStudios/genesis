#!/usr/bin/env perl
# Proves T76: the session's verbs are the only branch changers left, so
# track_branch and restore_branch have no callers, DESTROY restores nothing,
# and checkout and reset_working_tree are reached through the session alone.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use File::Find;
use Genesis;
use_ok 'Service::Git';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The sources under lib/ and bin/, read once, with the session itself set
# aside: it is the one file allowed to call these.
sub sources {
	my @files;
	find(sub {push @files, $File::Find::name if /\.(pm|pod)$/}, 'lib');
	push @files, 'bin/genesis';
	return sort grep {$_ ne 'lib/Service/Git/Session.pm'
		&& $_ ne 'lib/Service/Git/Session.pod'
		&& $_ ne 'lib/Service/Git.pm'
		&& $_ ne 'lib/Service/Git.pod'} @files;
}

subtest 'track_branch is gone and nothing asks for it' => sub {
	plan tests => 3;

	my $git_pm = get_file('lib/Service/Git.pm');
	unlike($git_pm, qr/_track_branch/, 'the tracking field is gone');
	unlike($git_pm, qr/_original_branch/,
		'and so is the field H16 says one caller stamped for everybody');

	my @callers = grep {get_file($_) =~ /track_branch/} sources();
	is_deeply(\@callers, [], 'and nothing under lib/ or bin/ asks for it');
};

subtest 'restore_branch is gone and nothing calls it' => sub {
	plan tests => 2;

	my $git_pm = get_file('lib/Service/Git.pm');
	unlike($git_pm, qr/sub restore_branch/, 'the sub is removed');

	my @callers = grep {get_file($_) =~ /restore_branch/} sources();
	is_deeply(\@callers, [], 'and it has no callers left');
};

subtest 'DESTROY no longer restores a branch' => sub {
	plan tests => 3;

	my $git_pm = get_file('lib/Service/Git.pm');
	my ($destroy) = $git_pm =~ /sub DESTROY \{(.*?)\n\}/s;
	ok($destroy, 'DESTROY is still there for the flyweight');
	unlike($destroy, qr/checkout/, 'and checks nothing out');
	unlike($destroy, qr/passfail/,
		'so there is no silent restore left to swallow anything');
};

subtest 'a branch change outside a session dies naming the session' => sub {
	plan tests => 5;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	my $err = exception(sub { $git->checkout($h->slug('qa')) });
	like($err, qr/session/i, 'a bare checkout names the session');
	is($git->current_branch, $h->control, 'and nothing switched');

	my $detached = exception(sub { $git->checkout_detached($git->sha('HEAD')) });
	like($detached, qr/session/i, 'and so does a bare detached checkout');

	my $reset = exception(sub { $git->reset_working_tree });
	like($reset, qr/session/i, 'and so does a bare reset_working_tree');

	my $session = $git->session(control => $h->control);
	$session->begin;
	ok(eval { $session->switch($h->slug('qa')); 1 },
		'while the session reaches the same checkout');
	$session->finish;
};

subtest 'nothing outside the session checks a branch out' => sub {
	plan tests => 2;

	# Every call site that used to switch now goes through the session,
	# which is what makes the guard above something other than decoration.
	my @callers;
	for my $file (sources()) {
		my $body = get_file($file);
		push @callers, $file if $body =~ /->checkout\(/
			|| $body =~ /->reset_working_tree\b/;
	}
	is_deeply(\@callers, [],
		'no caller under lib/ or bin/ reaches either entry point directly');

	# The deploy moves onto the environment branch and means to stay there,
	# and the post-deploy block moves onto control and hands off to a child.
	# A session would put both back, so the three come through the allowance
	# until M13 and M15 decide what they should mean instead.  Naming them
	# here is what keeps a fourth from joining them quietly.
	my @allowed = grep {get_file($_) =~ /->checkout_one_way\(/} sources();
	is_deeply(\@allowed,
		['lib/Genesis/Commands/Env.pm', 'lib/Genesis/Env.pm'],
		'and the one-way allowance carries only the sites M13 and M15 move');
};

subtest 'the propagate run drives a session end to end' => sub {
	plan tests => 4;

	# The branch is cut by the environment's own name, because that is what
	# propagation looks for, and the kit is a real one because the run loads
	# every environment in scope before it computes a single diff.
	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	Harness::Propagation::run(
		{dir => $h->a, onfailure => 'Failed to cut the qa branch'},
		'git', 'branch', 'qa', $h->control);

	my $control = commit_on_control($h,
		files   => {'qa.yml' => slurp($h->a . '/qa.yml') . "\n# a change\n"},
		message => 'change qa',
		push    => 1,
	);

	# run_genesis asserts for itself that the run left the working state as
	# it found it, which is the fourth row of this plan.
	my ($out, $err, $exit) = run_genesis($h,
		'propagate', '--commit', $control, '--no-fetch');

	is($exit, 0, 'the run delivered and came back');
	is($h->git('a')->current_branch, $h->control,
		'on the branch we started on');
	ok($h->git('a')->is_clean, 'with a clean tree');
};

sub exception {
	my ($code) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	eval { $code->(); 1 } and return '';
	return $@;
}

done_testing;

# vim: ts=2 sw=2 sts=2 noet
