#!/usr/bin/env perl
# Proves T76: the session's verbs are the only branch changers left, so
# track_branch and restore_branch have no callers, DESTROY restores nothing,
# and checkout is reached through the session alone.
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

subtest 'the two subs the session replaces are gone' => sub {
	plan tests => 4;

	my $git_pm = get_file('lib/Service/Git.pm');
	unlike($git_pm, qr/sub restore_branch/, 'restore_branch is removed');

	my @callers = grep {get_file($_) =~ /restore_branch/} sources();
	is_deeply(\@callers, [], 'and it has no callers left');

	# Discarding a working tree is what abort does now, and it does more
	# than this method could: it names the files first, it reaches the
	# index as well as the tree, and it puts back every branch the session
	# moved.  Leaving the method behind would leave a second way to throw
	# work away that no session verb opens the door for.
	unlike($git_pm, qr/sub reset_working_tree/, 'reset_working_tree is removed');

	my @resetters = grep {get_file($_) =~ /reset_working_tree/} sources();
	is_deeply(\@resetters, [], 'and nothing under lib/ or bin/ names it');
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
	plan tests => 4;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $git = $h->git('a');

	my $err = exception(sub { $git->checkout($h->slug('qa')) });
	like($err, qr/session/i, 'a bare checkout names the session');
	is($git->current_branch, $h->control, 'and nothing switched');

	my $detached = exception(sub { $git->checkout_detached($git->sha('HEAD')) });
	like($detached, qr/session/i, 'and so does a bare detached checkout');

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
	my @callers = grep {get_file($_) =~ /->checkout\(/} sources();
	is_deeply(\@callers, [],
		'no caller under lib/ or bin/ reaches the checkout directly');

	# The post-deploy block moves onto control and hands off to a child
	# command that expects to find it there, and a session would put it
	# back, so that one site comes through the allowance until M15 decides
	# what returning should mean.  The deploy's own site is gone: it
	# declares a branch class and switches inside the session the gate
	# opens.  The site before that was the deploy's --pull, which went with
	# the flag.
	#
	# The count is pinned and not just the file, because a second one-way
	# checkout added inside a file that already holds one would otherwise
	# join the allowance without turning anything red.
	my %allowed;
	for my $file (sources()) {
		my $calls = () = get_file($file) =~ /->checkout_one_way\(/g;
		$allowed{$file} = $calls if $calls;
	}
	is_deeply(\%allowed,
		{'lib/Genesis/Env.pm' => 1},
		'and the one-way allowance carries the one site M15 still moves');
};

subtest 'the propagate run drives a session end to end' => sub {
	plan tests => 5;

	# The branch is cut by the deployment slug, because that is what
	# propagation looks for, and the kit is a real one because the run loads
	# every environment in scope before it computes a single diff.  The
	# branch is cut here rather than by the run: propagate creates no
	# branch, and an environment that has none is reported as awaiting
	# genesis pipeline-apply and delivered nothing.
	my $h  = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $qa = $h->slug('qa');
	Harness::Propagation::run(
		{dir => $h->a, onfailure => "Failed to cut the $qa branch"},
		'git', 'branch', $qa, $h->control);
	# Published, because a deployment branch this clone holds and the
	# remote has never had is one the pre-flight refuses before the walk
	# is reached, on the grounds that nothing but pipeline-apply cuts one.
	push_from($h, 'a', $qa);

	# The run sources whatever control's tip holds, so the change to
	# propagate is simply made and published there.  Naming a commit is not
	# open to a caller any more: --commit went with the cascade it fed,
	# because a caller-chosen source is the one thing that let the
	# pipeline's run and the operator's run differ.
	commit_on_control($h,
		files   => {'qa.yml' => slurp($h->a . '/qa.yml') . "\n# a change\n"},
		message => 'change qa',
		push    => 1,
	);

	# run_genesis asserts for itself that the run left the working state as
	# it found it, which is the fourth row of this plan.
	my ($out, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, 0, 'the run delivered and came back');

	# Read on the branch that was written to rather than in the run's own
	# report, because a run that decided there was nothing to propagate
	# also exits nought, on control, with a clean tree, and would pass
	# every other row here having driven no session at all.
	my ($subject) = $h->git('a')->log_subjects($qa, limit => 1);
	like($subject, qr/\[pipeline\] control\@/,
		'and the target branch carries the commit it delivered');

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
