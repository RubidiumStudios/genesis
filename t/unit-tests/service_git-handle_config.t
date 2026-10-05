#!/usr/bin/env perl
# The handle is the flyweight for a repository's own facts: asking for it
# again costs no git call, and the clone's remotes, their URLs, the branches'
# upstreams and git's insteadOf rewrites are read once, in one git call, and
# read again only when the configuration changes.  Every remote here is a URL
# that is never contacted, since nothing below fetches.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Genesis qw/run/;
use Service::Git;

# A private repository with one commit, in a directory of its own.
sub repo {
	my $dir = helper::workdir() . sprintf('/hc-%d-%06d', $$, int(rand(1_000_000)));
	mkdir_or_fail($dir);
	run({dir => $dir}, 'git', 'init', '-q', '-b', 'control');
	put_file("$dir/README", "readme\n");
	run({dir => $dir}, 'git', 'add', 'README');
	run({dir => $dir}, 'git', '-c', 'user.name=t', '-c', 'user.email=t@t',
		'commit', '-q', '-m', 'first');
	return $dir;
}

# How many git processes the code spawns through Service::Git.
sub git_calls {
	my ($code) = @_;
	my $calls = 0;
	no warnings qw/redefine once/;
	my $real = \&Service::Git::run;
	local *Service::Git::run = sub {
		$calls++ if grep {defined && !ref && $_ eq 'git'} @_;
		goto &$real;
	};
	$code->();
	return $calls;
}

subtest 'a second ask for the same path costs no git call' => sub {
	plan tests => 2;
	my $dir = repo();
	my $first = Service::Git->new($dir);
	my $again;
	is(git_calls(sub {$again = Service::Git->new($dir)}), 0,
		'the path was resolved once, and the handle is answered from memory');
	is($again, $first, 'and it is the same handle');
};

subtest 'the configuration is read once for every question about it' => sub {
	plan tests => 6;
	my $dir = repo();
	run({dir => $dir}, 'git', 'remote', 'add', 'origin', 'git@github.com:org/repo.git');
	run({dir => $dir}, 'git', 'remote', 'add', 'fork', 'https://github.com/me/repo.git');
	run({dir => $dir}, 'git', 'config', 'branch.control.remote', 'origin');
	my $git = Service::Git->new($dir);

	my ($names, $url, $upstream, $has);
	my $calls = git_calls(sub {
		$names    = [$git->remote_names];
		$url      = $git->configured_url('fork');
		$upstream = $git->branch_upstream_remote('control');
		$has      = $git->has_remote('origin');
	});
	is_deeply($names, ['fork', 'origin'], 'the remotes are listed');
	is($url, 'https://github.com/me/repo.git', 'a remote URL is read');
	is($upstream, 'origin', "a branch's upstream is read");
	is($has, 1, 'and whether a remote exists');
	is($calls, 1, 'all four answered from one git call');
	is(git_calls(sub {$git->remote_names; $git->configured_url('origin')}), 0,
		'and later questions cost none');
};

subtest 'a remote the clone does not have answers nothing' => sub {
	plan tests => 3;
	my $dir = repo();
	run({dir => $dir}, 'git', 'remote', 'add', 'origin', 'git@github.com:org/repo.git');
	my $git = Service::Git->new($dir);
	is($git->has_remote('nowhere'), 0, 'has_remote says it is not there');
	is($git->remote_url('nowhere'), undef, 'remote_url gives no URL for it');
	is($git->configured_url('nowhere'), undef, 'and neither does configured_url');
};

subtest 'a change made outside the handle is seen' => sub {
	plan tests => 3;
	my $dir = repo();
	run({dir => $dir}, 'git', 'remote', 'add', 'origin', 'git@github.com:org/aaaa.git');
	my $git = Service::Git->new($dir);
	is($git->configured_url('origin'), 'git@github.com:org/aaaa.git', 'read first');

	run({dir => $dir}, 'git', 'remote', 'add', 'upstream', 'git@github.com:org/repo.git');
	is_deeply([$git->remote_names], ['origin', 'upstream'], 'a remote added is seen');

	# The same length, in the same second: git rewrites the file through a
	# new one, so its inode changes even where its time and size do not.
	run({dir => $dir}, 'git', 'remote', 'set-url', 'origin', 'git@github.com:org/bbbb.git');
	is($git->configured_url('origin'), 'git@github.com:org/bbbb.git',
		'and a same-size change in the same second');
};

subtest 'the rewritten URL is the one git would contact' => sub {
	my @cases = (
		['no rewrite',             'git@github.com:org/repo.git', []],
		['a shorthand',            'gh:org/repo',
			[['url.git@github.com:.insteadOf', 'gh:']]],
		['the longest prefix wins', 'https://github.com/org/repo.git',
			[['url./srv/mirror/.insteadOf', 'https://github.com/'],
			 ['url./srv/org/.insteadOf',    'https://github.com/org/']]],
		['a whole URL redirected', 'https://github.com/org/repo.git',
			[['url./srv/r.git.insteadOf', 'https://github.com/org/repo.git']]],
	);
	plan tests => scalar(@cases);
	for my $case (@cases) {
		my ($label, $url, $rewrites) = @$case;
		my $dir = repo();
		run({dir => $dir}, 'git', 'remote', 'add', 'origin', $url);
		run({dir => $dir}, 'git', 'config', '--add', @$_) for @$rewrites;
		my ($want) = run({dir => $dir}, 'git', 'remote', 'get-url', 'origin');
		chomp $want;
		is(Service::Git->new($dir)->remote_url('origin'), $want,
			"$label: the same URL git remote get-url answers");
	}
};

subtest "a worktree reads its repository's configuration" => sub {
	plan tests => 2;
	my $dir = repo();
	run({dir => $dir}, 'git', 'remote', 'add', 'origin', 'git@github.com:org/repo.git');
	my $wt = "$dir-wt";
	run({dir => $dir}, 'git', 'worktree', 'add', '-q', '-b', 'side', $wt);
	my $git = Service::Git->new($wt);
	is($git->configured_url('origin'), 'git@github.com:org/repo.git',
		'the worktree answers from the shared configuration');

	run({dir => $dir}, 'git', 'remote', 'set-url', 'origin', 'git@github.com:org/moved.git');
	is($git->configured_url('origin'), 'git@github.com:org/moved.git',
		'and sees a change made through the main checkout');
};

done_testing;
