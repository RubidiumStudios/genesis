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

# ======================================================================
# resolve_branch - where does this branch actually live?
# ======================================================================
#
# A branch missing from the local clone is ambiguous: it may never have
# existed, or the clone may simply be fresh or stale.  Creating it in the
# second case forks it from the real branch, and the first push either
# is rejected or overwrites a deployment anchor.  So the remote decides,
# and callers get a state rather than a boolean.

sub override_branch_exists {
	my ($exists) = @_;
	no warnings qw(redefine once);
	*Service::Git::branch_exists = sub { $exists };
}

subtest 'resolve_branch - local when the branch is already here' => sub {
	plan tests => 2;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	override_branch_exists(1);

	my $git = make_git();
	is $git->resolve_branch('qa'), 'local', 'already present locally';
	is scalar @run_calls, 0, 'the remote is not consulted when we already have it';
};

subtest 'resolve_branch - fetched when the remote has it' => sub {
	plan tests => 3;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	override_branch_exists(0);
	push @run_results, ["abc123\trefs/heads/qa", 0, ''];   # ls-remote
	push @run_results, ['', 0, ''];                        # fetch

	my $git = make_git();
	is $git->resolve_branch('qa'), 'fetched',
		'absent locally but present on the remote is a fetch, never a create';
	is scalar @run_calls, 2, 'probed, then fetched';
	is $run_calls[1][2], 'fetch', 'second call is the fetch';
};

subtest 'resolve_branch - absent when it exists nowhere' => sub {
	plan tests => 2;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	override_branch_exists(0);
	push @run_results, ['', 0, ''];   # ls-remote finds nothing

	my $git = make_git();
	is $git->resolve_branch('qa'), 'absent',
		'only absent everywhere licenses a create';
	is scalar @run_calls, 1, 'nothing fetched';
};

subtest 'resolve_branch - absent when there is no remote to consult' => sub {
	plan tests => 2;
	reset_stub(); install_run_stub();
	override_default_remote(undef);
	override_branch_exists(0);

	my $git = make_git();
	# A local-only repository has no authority to consult, so absence is
	# the whole truth and creating is safe.
	is $git->resolve_branch('qa'), 'absent',
		'no remote means local absence is authoritative';
	is scalar @run_calls, 0, 'no probe attempted';
};

subtest 'resolve_branch - offline reports unverifiable, never absent' => sub {
	plan tests => 2;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	override_branch_exists(0);

	my $git = make_git();
	# --no-fetch means "do not talk to the remote", not "assume nothing is
	# there".  Callers must be able to reconcile local branches offline
	# without that silently becoming a licence to create.
	is $git->resolve_branch({offline => 1}, 'qa'), 'unverifiable',
		'offline withholds the answer rather than guessing at it';
	is scalar @run_calls, 0, 'the remote is not contacted';
};

subtest 'resolve_branch - offline still answers for a local branch' => sub {
	plan tests => 1;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	override_branch_exists(1);

	my $git = make_git();
	is $git->resolve_branch({offline => 1}, 'qa'), 'local',
		'a branch we already have needs no remote to confirm';
};

subtest 'resolve_branch - a failed probe is not read as absence' => sub {
	plan tests => 1;
	reset_stub(); install_run_stub();
	override_default_remote('origin');
	override_branch_exists(0);
	push @run_results, ['', 128, 'fatal: Authentication failed'];

	my $git = make_git();
	# Treating an unreachable remote as "absent" is precisely the mistake
	# this exists to prevent -- it would create branches offline.
	throws_ok {$git->resolve_branch('qa')} qr/ls-remote/,
		'an unreachable remote raises rather than licensing a create';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
