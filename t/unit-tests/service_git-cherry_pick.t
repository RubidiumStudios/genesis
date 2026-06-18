#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;

use Genesis;
use_ok 'Service::Git';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Build a Service::Git instance pointed at any path; run() is stubbed.
sub make_git {
	my $root = workdir();
	mkdir_or_fail($root) unless -d $root;
	bless { root => $root, _branch_cache => {} }, 'Service::Git';
}

our @run_calls;
our @run_results;

sub install_run_stub {
	no warnings qw(redefine once);
	*Service::Git::run = sub {
		push @run_calls, [@_];
		my $r = shift @run_results;
		$r //= ['', 0, ''];
		return @$r;
	};
}

sub reset_stub { @run_calls = (); @run_results = (); }

# ======================================================================
# cherry_pick - apply a commit by SHA onto the current branch
# ======================================================================

subtest 'cherry_pick - success returns $self' => sub {
	plan tests => 3;
	reset_stub();
	install_run_stub();
	push @run_results, ['', 0, ''];   # cherry-pick succeeds, no output

	my $git = make_git();
	my $returned = $git->cherry_pick('abc1234');

	is $returned, $git, 'returns $self on success';

	# Find the cherry-pick call -- args order: opts-hash, 'git', 'cherry-pick', <sha>
	my ($call) = grep { my @flat = @{$_}; grep { $_ eq 'cherry-pick' } @flat } @run_calls;
	ok defined($call), 'a cherry-pick run() was invoked';
	my @args = @$call;
	# Last arg should be the sha
	is $args[-1], 'abc1234', 'sha is the final argument to git cherry-pick';
};

subtest 'cherry_pick - conflict aborts and bails with file list' => sub {
	plan tests => 3;
	reset_stub();
	install_run_stub();
	# git cherry-pick failure with conflict message
	push @run_results, [
		"CONFLICT (content): Merge conflict in some/path/file.yml\n".
		"error: could not apply abc1234... [pipeline] propagate\n",
		1,
		''
	];
	# And the abort cleanup call
	push @run_results, ['', 0, ''];

	my $git = make_git();
	throws_ok {
		$git->cherry_pick('abc1234');
	} qr/conflict/i, 'bails with conflict in the error message';

	like $@, qr{some/path/file\.yml},
		'error message names the conflicting file(s)';

	# Confirm we issued a cherry-pick --abort to clean up
	my @aborts = grep {
		my @flat = @{$_};
		grep { $_ eq '--abort' } @flat
	} @run_calls;
	ok scalar(@aborts) >= 1,
		'cherry-pick --abort was invoked to clean up the conflict';
};

subtest 'cherry_pick - generic git failure bails with stderr' => sub {
	plan tests => 1;
	reset_stub();
	install_run_stub();
	push @run_results, ['', 128, 'fatal: bad revision abc1234'];

	my $git = make_git();
	throws_ok {
		$git->cherry_pick('abc1234');
	} qr/bad revision|cherry.pick/i,
		'bails with the underlying git error visible';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
