#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;

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

# ======================================================================
# resolve_branch - how does this branch stand against the remote's?
# ======================================================================
#
# The query compares two refs that are already here, the local branch and
# its remote-tracking ref, and answers with a state, both counts, and the
# unverifiable flag.  It reads refs and nothing else.  The refresh is a step
# of its own, so an answer is about one moment and can be asked for twice.
#
# What this file proves is which git commands the query issues and which it
# does not.  The six states are driven through real repositories in
# t/unit-tests/service_git-divergence.t, where a state means something.

sub override_branch_exists {
	my ($exists) = @_;
	no warnings qw(redefine once);
	*Service::Git::branch_exists = sub { $exists };
}

our @ref_asks;

# The tracking ref is a ref this repository either has or lacks, and naming
# the ones it has says so far more plainly than queueing a git verdict that
# has to be counted out in order.
sub override_ref_exists {
	my (@present) = @_;
	@ref_asks = ();
	my %here = map { $_ => 1 } @present;
	no warnings qw(redefine once);
	*Service::Git::_ref_exists = sub {
		my ($self, $ref) = @_;
		push @ref_asks, $ref;
		return $here{$ref} ? 1 : 0;
	};
}

subtest 'resolve_branch - both counts come back in one record' => sub {
	plan tests => 3;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	override_branch_exists(1);
	override_ref_exists('refs/remotes/origin/qa');
	push @run_results, ["2\t1\n", 0, ''];

	my $git = make_git();
	cmp_deeply($git->resolve_branch('qa'),
		{state => 'diverged', ahead => 2, behind => 1, unverifiable => 0},
		'commits on both sides read diverged, carrying both counts');
	is scalar @run_calls, 1, 'one git command answers it';
	is $run_calls[0][2], 'rev-list', 'and that command is the count';
};

subtest 'resolve_branch - equal tips read in-sync' => sub {
	plan tests => 1;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	override_branch_exists(1);
	override_ref_exists('refs/remotes/origin/qa');
	push @run_results, ["0\t0\n", 0, ''];

	my $git = make_git();
	cmp_deeply($git->resolve_branch('qa'),
		{state => 'in-sync', ahead => 0, behind => 0, unverifiable => 0},
		'neither side is holding anything the other lacks');
};

subtest 'resolve_branch - the two existence answers come before the counts' => sub {
	plan tests => 4;
	reset_stub(); install_run_stub();
	override_default_remote('origin');

	override_branch_exists(1);
	override_ref_exists();
	my $git = make_git();
	cmp_deeply($git->resolve_branch('qa'),
		{state => 'no-remote', ahead => 0, behind => 0, unverifiable => 0},
		'a branch this clone alone has reads no-remote');
	is scalar @run_calls, 0, 'and nothing is counted, because there is no second ref';

	reset_stub();
	override_branch_exists(0);
	override_ref_exists('refs/remotes/origin/qa');
	cmp_deeply($git->resolve_branch('qa'),
		{state => 'no-local', ahead => 0, behind => 0, unverifiable => 0},
		'a branch the tracking ref alone has reads no-local');
	is scalar @run_calls, 0, 'and that one is not counted either';
};

subtest 'resolve_branch - a branch that is nowhere has no state' => sub {
	plan tests => 2;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	override_branch_exists(0);
	override_ref_exists();

	my $git = make_git();
	# No state of the six describes a branch that is in neither place, and
	# inventing one would hand a caller a record to read rather than an
	# absence to act on.
	is $git->resolve_branch('qa'), undef,
		'neither ref exists, so the whole record is undef';
	is scalar @run_calls, 0, 'nothing is asked of git beyond the two refs';
};

subtest 'resolve_branch - a repository with no remote is local only' => sub {
	plan tests => 3;
	reset_stub(); install_run_stub();
	override_default_remote(undef);
	override_branch_exists(1);
	override_ref_exists();

	my $git = make_git();
	cmp_deeply($git->resolve_branch('qa'),
		{state => 'no-remote', ahead => 0, behind => 0, unverifiable => 0},
		'every branch such a repository holds is a branch it alone holds');
	is scalar @ref_asks, 0,
		'no tracking ref is looked for, since no remote names one';
	is scalar @run_calls, 0, 'and no count is taken';
};

subtest 'resolve_branch - remote names the ref the branch is measured against' => sub {
	plan tests => 3;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	override_branch_exists(1);
	override_ref_exists('refs/remotes/upstream/qa');
	push @run_results, ["0\t3\n", 0, ''];

	my $git = make_git();
	cmp_deeply($git->resolve_branch('qa', remote => 'upstream'),
		{state => 'behind', ahead => 0, behind => 3, unverifiable => 0},
		'the named remote answers rather than the default one');
	cmp_deeply(\@ref_asks, ['refs/remotes/upstream/qa'],
		'its tracking ref is the one looked for');
	is $run_calls[0][5], 'refs/heads/qa...refs/remotes/upstream/qa',
		'and the one the count is taken against';
};

subtest 'resolve_branch - unverifiable rides on the answer and asks nothing more' => sub {
	plan tests => 3;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	override_branch_exists(1);
	override_ref_exists('refs/remotes/origin/qa');
	push @run_results, ["1\t0\n", 0, ''];

	my $git = make_git();
	# The flag is the caller's own admission that it did not refresh first,
	# so a report can say its counts rest on a tracking ref nobody moved.
	# It is not a state, and it changes neither the state nor either count.
	my $div = $git->resolve_branch('qa', unverifiable => 1);
	is $div->{state}, 'ahead', 'the state is still read and still reported';
	is $div->{unverifiable}, 1, 'and the flag comes back on the record';
	is scalar @run_calls, 1, 'the flag makes the query no cheaper and no dearer';
};

# ======================================================================
# remote_url and has_remote - what git says when it cannot answer
# ======================================================================
#
# Both read a value out of git's stdout, so git's own complaint has to be
# captured apart from it or the complaint becomes the value.

subtest 'remote_url keeps git stderr out of the url' => sub {
	plan tests => 3;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	push @run_results, ["error: No such remote 'origin'", 2, ''];

	my $git = make_git();
	is($git->remote_url('origin'), undef,
		'a remote git cannot answer for has no url');
	is($run_calls[0][0]{stderr}, 0,
		'and the complaint is captured apart from the output');

	reset_stub();
	push @run_results, ["https://github.com/team/bosh.git\n", 0, ''];
	is($git->remote_url('origin'), 'https://github.com/team/bosh.git',
		'while a remote that answers gives its fetch url');
};

subtest 'has_remote asks git quietly too' => sub {
	plan tests => 2;
	reset_stub(); install_run_stub();
	push @run_results, ["origin\ndev\n", 0, ''];

	my $git = make_git();
	is($git->has_remote('dev'), 1, 'a configured remote is found');
	is($run_calls[0][0]{stderr}, 0,
		'and a complaint never reaches the list of names it reads');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
