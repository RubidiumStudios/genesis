#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use_ok 'Genesis::CI::Propagation';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Stub Service::Git instance with controllable branch_exists / log_subjects.
sub stub_git {
	my (%opts) = @_;
	my $branch_exists = $opts{branch_exists} // {};   # { branch_name => 1 }
	my $log_subjects  = $opts{log_subjects}  // {};   # { branch_name => [subjects] }
	my $self = bless {
		_branch_exists => $branch_exists,
		_log_subjects  => $log_subjects,
	}, 'Test::Mock::Git';
	{
		no strict 'refs';
		no warnings 'redefine';
		*{'Test::Mock::Git::branch_exists'} = sub {
			my ($self, $b) = @_;
			return $self->{_branch_exists}{$b} ? 1 : 0;
		};
		*{'Test::Mock::Git::log_subjects'} = sub {
			my ($self, $b, %opts) = @_;
			my $list = $self->{_log_subjects}{$b} // [];
			my @subjects = @$list;
			@subjects = @subjects[0 .. ($opts{limit} - 1)]
				if $opts{limit} && @subjects > $opts{limit};
			return @subjects;
		};
	}
	$self;
}

# ======================================================================
# _pr_branch_has_control_sha($git, $branch, $control_short)
# ----------------------------------------------------------------------
# Idempotency predicate for rolling-branch PR propagation: returns
# true iff the latest commit on $branch is the propagation for the
# given control SHA.  Used to skip duplicate-commit creation when
# `genesis propagate` is re-run against an unchanged control HEAD.
# ======================================================================

subtest 'returns false when branch does not exist' => sub {
	plan tests => 1;
	my $git = stub_git();
	ok !Genesis::CI::Propagation::_pr_branch_has_control_sha($git, 'pr/staging', 'abc1234'),
		'no branch => not idempotent (caller will create the branch)';
};

subtest 'returns false when branch exists but has no commits' => sub {
	plan tests => 1;
	my $git = stub_git(
		branch_exists => { 'pr/staging' => 1 },
		log_subjects  => { 'pr/staging' => [] },
	);
	ok !Genesis::CI::Propagation::_pr_branch_has_control_sha($git, 'pr/staging', 'abc1234'),
		'empty branch => not idempotent';
};

subtest 'returns true when latest commit references the same control sha' => sub {
	plan tests => 1;
	my $git = stub_git(
		branch_exists => { 'pr/staging' => 1 },
		log_subjects  => {
			'pr/staging' => [
				'[pipeline] control@abc1234 -> staging',
				'[pipeline] control@def5678 -> staging',
			],
		},
	);
	ok Genesis::CI::Propagation::_pr_branch_has_control_sha($git, 'pr/staging', 'abc1234'),
		'matching control sha in latest commit => idempotent (skip duplicate)';
};

subtest 'returns false when latest commit is a different control sha' => sub {
	plan tests => 1;
	my $git = stub_git(
		branch_exists => { 'pr/staging' => 1 },
		log_subjects  => {
			'pr/staging' => [
				'[pipeline] control@def5678 -> staging',
				'[pipeline] control@abc1234 -> staging',
			],
		},
	);
	ok !Genesis::CI::Propagation::_pr_branch_has_control_sha($git, 'pr/staging', 'abc1234'),
		'latest commit is a different sha => not idempotent (even if older commit matches)';
};

subtest 'returns false when latest commit is unrelated' => sub {
	plan tests => 1;
	my $git = stub_git(
		branch_exists => { 'pr/staging' => 1 },
		log_subjects  => { 'pr/staging' => ['operator-manual-edit'] },
	);
	ok !Genesis::CI::Propagation::_pr_branch_has_control_sha($git, 'pr/staging', 'abc1234'),
		'unrelated latest commit => not idempotent';
};

subtest 'matches even when control sha is a substring of a longer sha' => sub {
	# Defensive: control_short is typically 7-8 chars; ensure we
	# anchor the match so 'abc1234' doesn't accidentally match a
	# commit message containing 'abc1234567' (a longer sha).
	plan tests => 2;
	my $git = stub_git(
		branch_exists => { 'pr/staging' => 1 },
		log_subjects  => {
			'pr/staging' => ['[pipeline] control@abc1234567 -> staging'],
		},
	);
	# This SHOULD be false: 'abc1234' is a prefix of the actual sha
	# 'abc1234567', not an equal match.
	ok !Genesis::CI::Propagation::_pr_branch_has_control_sha($git, 'pr/staging', 'abc1234'),
		'shorter sha does not match a longer sha that starts with the same chars';
	# And the full sha SHOULD match.
	ok Genesis::CI::Propagation::_pr_branch_has_control_sha($git, 'pr/staging', 'abc1234567'),
		'full sha matches its own commit';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
