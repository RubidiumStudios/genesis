#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;

use Genesis;
use_ok 'Service::Git';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

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

sub override_default_remote {
	my ($name) = @_;
	no warnings qw(redefine once);
	*Service::Git::default_remote = sub { $name };
}

# ======================================================================
# remote_branch_exists - check if a branch exists on the remote
# ======================================================================
#
# Uses `git ls-remote --heads <remote> <branch>` which returns one
# line per matching ref on stdout (or empty if not present).  Empty
# output AND rc=0 means the branch doesn't exist on the remote.
# Non-zero rc means the ls-remote call itself failed (auth, network,
# bad remote) and should bail.

subtest 'remote_branch_exists - true when ls-remote returns a matching ref' => sub {
	plan tests => 1;
	reset_stub();
	install_run_stub();
	override_default_remote('origin');
	push @run_results, [
		"abc1234567890\trefs/heads/pr/staging\n",
		0,
		''
	];

	my $git = make_git();
	ok $git->remote_branch_exists('pr/staging'),
		'matching ref in ls-remote output => true';
};

subtest 'remote_branch_exists - false when ls-remote returns empty' => sub {
	plan tests => 1;
	reset_stub();
	install_run_stub();
	override_default_remote('origin');
	push @run_results, ['', 0, ''];

	my $git = make_git();
	ok !$git->remote_branch_exists('pr/never-was'),
		'empty ls-remote output => false';
};

subtest 'remote_branch_exists - false when no remote is configured' => sub {
	plan tests => 1;
	reset_stub();
	install_run_stub();
	override_default_remote(undef);

	my $git = make_git();
	ok !$git->remote_branch_exists('pr/staging'),
		'no default remote => false (no remote to check against)';
};

subtest 'remote_branch_exists - bails on ls-remote failure' => sub {
	plan tests => 1;
	reset_stub();
	install_run_stub();
	override_default_remote('origin');
	push @run_results, ['', 128, 'fatal: unable to access'];

	my $git = make_git();
	throws_ok {
		$git->remote_branch_exists('pr/staging');
	} qr/ls-remote|remote/i,
		'ls-remote failure bails (auth/network surfaces vs "branch not found")';
};

# ======================================================================
# delete_remote_branch - delete a branch on the remote
# ======================================================================
#
# Uses `git push <remote> --delete <branch>`.  Returns $self on
# success.  On failure (e.g. branch already gone, permission denied),
# bails with the git error visible -- caller can wrap in eval if a
# best-effort cleanup is desired.

subtest 'delete_remote_branch - success returns $self' => sub {
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_default_remote('origin');
	push @run_results, ['', 0, ''];

	my $git = make_git();
	my $returned = $git->delete_remote_branch('pr/staging');
	is $returned, $git, 'returns $self on successful delete';

	# Confirm we called: git push origin --delete pr/staging
	my $expected = ['origin', '--delete', 'pr/staging'];
	my $matched = 0;
	for my $call (@run_calls) {
		my @flat = @$call;
		my @keep = grep { ref($_) ne 'HASH' && $_ ne 'git' && $_ ne 'push' } @flat;
		if (join(' ', @keep) eq join(' ', @$expected)) {
			$matched = 1;
			last;
		}
	}
	ok $matched, 'git push origin --delete pr/staging was invoked';
};

subtest 'delete_remote_branch - no-op when no remote configured' => sub {
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_default_remote(undef);

	my $git = make_git();
	my $returned = $git->delete_remote_branch('pr/staging');
	is $returned, $git, 'returns $self even with no remote';
	is scalar(@run_calls), 0,
		'no git command issued when there is no remote';
};

subtest 'delete_remote_branch - bails on push failure' => sub {
	plan tests => 1;
	reset_stub();
	install_run_stub();
	override_default_remote('origin');
	push @run_results, ['', 1, 'remote: error: unable to delete'];

	my $git = make_git();
	throws_ok {
		$git->delete_remote_branch('pr/staging');
	} qr/delete|remote/i,
		'push --delete failure bails with the git error';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
