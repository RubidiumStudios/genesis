#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Output;

use Genesis;
use_ok 'Genesis::CI::Propagation';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# =========================================================================
# Mock Service::Git
#
# Records every method call into $self->{_calls} as [name, @args].
# Configurable returns via constructor options.
# =========================================================================
sub mock_git {
	my (%opts) = @_;
	my $self = bless {
		_calls          => [],
		_branch_exists  => $opts{branch_exists}        // {},
		_remote_exists  => $opts{remote_branch_exists} // {},
		_log_subjects   => $opts{log_subjects}         // {},
		_default_remote => $opts{default_remote}       // 'origin',
		_push_results   => $opts{push_results}         // {},
		_current_branch => 'control',
	}, 'Test::Mock::PropEnvs::Git';
	$self;
}

# Install methods once (idempotent across tests)
{
	no strict 'refs';
	no warnings 'redefine';

	my $pkg = 'Test::Mock::PropEnvs::Git';

	*{"${pkg}::_record"} = sub {
		my ($self, $name, @args) = @_;
		push @{$self->{_calls}}, [$name, @args];
	};
	*{"${pkg}::calls"} = sub {
		my ($self, $name) = @_;
		return @{$self->{_calls}} unless $name;
		return grep { $_->[0] eq $name } @{$self->{_calls}};
	};

	# Mutating ops — record + return $self (chainable) or sensible default
	for my $m (qw(checkout create_branch checkout_file rm commit fetch_branch
	             delete_remote_branch reset_working_tree restore_branch)) {
		*{"${pkg}::${m}"} = sub {
			my $self = shift;
			$self->_record($m, @_);
			# Track the "current branch" for checkout-style ops
			$self->{_current_branch} = $_[0] if $m eq 'checkout' || $m eq 'create_branch';
			$self;
		};
	}

	# Read ops
	*{"${pkg}::branch_exists"} = sub {
		my ($self, $b) = @_;
		$self->_record('branch_exists', $b);
		return $self->{_branch_exists}{$b} ? 1 : 0;
	};
	*{"${pkg}::remote_branch_exists"} = sub {
		my ($self, $b) = @_;
		$self->_record('remote_branch_exists', $b);
		return $self->{_remote_exists}{$b} ? 1 : 0;
	};
	*{"${pkg}::log_subjects"} = sub {
		my ($self, $b, %opts) = @_;
		$self->_record('log_subjects', $b);
		my $list = $self->{_log_subjects}{$b} // [];
		my @subjects = @$list;
		@subjects = @subjects[0 .. ($opts{limit} - 1)]
			if $opts{limit} && @subjects > $opts{limit};
		return @subjects;
	};
	*{"${pkg}::current_branch"} = sub {
		my $self = shift;
		$self->_record('current_branch');
		$self->{_current_branch};
	};
	*{"${pkg}::default_remote"} = sub {
		my $self = shift;
		$self->_record('default_remote');
		$self->{_default_remote};
	};
	*{"${pkg}::push"} = sub {
		my ($self, $remote, @branches) = @_;
		$self->_record('push', $remote, @branches);
		# Default: every branch pushed succeeds unless overridden
		my %result = map { $_ => ($self->{_push_results}{$_} // 1) } @branches;
		\%result;
	};
	*{"${pkg}::unprefixed"} = sub {
		my $self = shift;
		# Identity in the mock (no prefix configured)
		return wantarray ? @_ : $_[0];
	};
}

# =========================================================================
# Mock Service::Github
# =========================================================================
sub mock_github {
	my (%opts) = @_;
	my $self = bless {
		_calls        => [],
		_open_prs     => $opts{open_prs}     // {},  # "base/head" => [\%pr, ...]
		_create_pr    => $opts{create_pr}    // { number => 42, html_url => 'https://example/pr/42' },
		_update_pr    => $opts{update_pr}    // { number => 42, html_url => 'https://example/pr/42' },
	}, 'Test::Mock::PropEnvs::Github';
	$self;
}

{
	no strict 'refs';
	no warnings 'redefine';
	my $pkg = 'Test::Mock::PropEnvs::Github';

	*{"${pkg}::_record"} = sub {
		my ($self, $name, @args) = @_;
		push @{$self->{_calls}}, [$name, @args];
	};
	*{"${pkg}::calls"} = sub {
		my ($self, $name) = @_;
		return @{$self->{_calls}} unless $name;
		return grep { $_->[0] eq $name } @{$self->{_calls}};
	};

	*{"${pkg}::open_prs"} = sub {
		my ($self, $owner_repo, $base, $head) = @_;
		$self->_record('open_prs', $owner_repo, $base, $head);
		my $key = "$base/" . ($head // '');
		return $self->{_open_prs}{$key} // [];
	};
	*{"${pkg}::create_pr"} = sub {
		my ($self, $owner_repo, %opts) = @_;
		$self->_record('create_pr', $owner_repo, %opts);
		$self->{_create_pr};
	};
	*{"${pkg}::update_pr"} = sub {
		my ($self, $owner_repo, $number, %opts) = @_;
		$self->_record('update_pr', $owner_repo, $number, %opts);
		$self->{_update_pr};
	};
}

# =========================================================================
# Helpers
# =========================================================================
sub direct_target {
	my ($env, %opt) = @_;
	return {
		env        => $env,
		require_pr => 0,
		detail     => {
			changed => $opt{changed} // ['cloud-config/aws.yml'],
			deleted => $opt{deleted} // [],
			renamed => $opt{renamed} // {},
		},
	};
}

sub pr_target {
	my ($env, %opt) = @_;
	my $t = direct_target($env, %opt);
	$t->{require_pr} = 1;
	$t;
}

# Capture-and-return wrapper around propagate_envs.  Every subtest
# below exercises one propagate_envs() call which emits multi-line
# progress banners through info()/output() (e.g. "  staging: pushed",
# "Pushing to origin...").  Without capture these leak into the prove
# progress line.
#
# Returns the call's result in scalar context (so existing
#   `my $result = propagate_envs_captured(...)`
# call sites work unchanged) and (result, stdout, stderr) in list
# context for subtests that want to assert on the banner content.
sub propagate_envs_captured {
	my @args = @_;
	my $result;
	my ($stdout, $stderr) = output_from {
		$result = Genesis::CI::Propagation::propagate_envs(@args);
	};
	return wantarray ? ($result, $stdout, $stderr) : $result;
}

# Standard args bundle, mergeable with subtest-specific overrides
sub base_args {
	my (%over) = @_;
	return (
		control       => 'control',
		control_sha   => 'abcdef1234567890',
		control_short => 'abcdef1',
		owner_repo    => 'acme/widgets',
		push_direct_commits => 1,
		push_pr_branches    => 1,
		create_prs          => 1,
		no_push             => 0,
		dry_run             => 0,
		%over,
	);
}

# =========================================================================
# DIRECT MODE
# =========================================================================

subtest 'direct mode + push_direct_commits=1 commits and pushes <env>' => sub {
	plan tests => 5;
	my $git = mock_git();
	my $result = propagate_envs_captured(
		base_args(),
		git     => $git,
		github  => undef,
		targets => [ direct_target('staging') ],
	);

	is $result->{propagated}, 1, 'one env propagated';
	my @checkouts = $git->calls('checkout');
	ok( (grep { $_->[1] eq 'staging' } @checkouts), 'checked out staging');
	ok( scalar($git->calls('commit')),              'committed change' );
	my @pushes = $git->calls('push');
	is scalar(@pushes), 1, 'single push call';
	ok( (grep { $_ eq 'staging' } @{$pushes[0]}[2..$#{$pushes[0]}]),
		'staging branch present in push args' );
};

subtest 'direct mode + push_direct_commits=0 commits but does not push' => sub {
	plan tests => 3;
	my $git = mock_git();
	my $result = propagate_envs_captured(
		base_args(push_direct_commits => 0),
		git     => $git,
		github  => undef,
		targets => [ direct_target('staging') ],
	);

	is $result->{propagated}, 1, 'one env propagated';
	ok( scalar($git->calls('commit')), 'committed change' );
	is scalar($git->calls('push')), 0,
		'no push when push_direct_commits is false (concourse mode)';
};

subtest 'no_push master kill switch suppresses all pushes' => sub {
	plan tests => 3;
	my $git = mock_git();
	my $result = propagate_envs_captured(
		base_args(no_push => 1),
		git     => $git,
		github  => undef,
		targets => [ direct_target('staging') ],
	);

	is $result->{propagated}, 1, 'one env propagated locally';
	ok( scalar($git->calls('commit')), 'commit still happens locally' );
	is scalar($git->calls('push')), 0, 'no push under no_push';
};

subtest 'dry_run reports without mutating git' => sub {
	plan tests => 3;
	my $git = mock_git();
	my $result = propagate_envs_captured(
		base_args(dry_run => 1),
		git     => $git,
		github  => undef,
		targets => [ direct_target('staging') ],
	);

	is $result->{propagated}, 1, 'reported as would-propagate';
	is scalar($git->calls('commit')), 0, 'no commit under dry_run';
	is scalar($git->calls('push')),   0, 'no push under dry_run';
};

subtest 'multiple direct envs all pushed in a single push call' => sub {
	plan tests => 3;
	my $git = mock_git();
	propagate_envs_captured(
		base_args(),
		git     => $git,
		github  => undef,
		targets => [ direct_target('staging'), direct_target('preprod') ],
	);

	my @pushes = $git->calls('push');
	is scalar(@pushes), 1, 'single batched push call';
	my @branches = @{$pushes[0]}[2..$#{$pushes[0]}];
	ok( (grep { $_ eq 'staging' } @branches), 'staging in push' );
	ok( (grep { $_ eq 'preprod' } @branches), 'preprod in push' );
};

# =========================================================================
# PR MODE — rolling-branch decision tree
#
# Branch naming: pr/<env>
# Decisions driven by GitHub API open-PR count for (base=<env>, head=pr/<env>):
#   0 → stale cleanup, fresh branch, commit, push, create_pr
#   1 → fetch if missing, checkout, append commit (unless idempotent), push, update_pr
#   >1 → warn + treat as 1 using most-recent
# =========================================================================

subtest 'PR mode count=0 creates fresh branch and PR' => sub {
	plan tests => 6;
	my $git    = mock_git();
	my $github = mock_github();   # default: open_prs returns []
	my $result = propagate_envs_captured(
		base_args(),
		git     => $git,
		github  => $github,
		targets => [ pr_target('staging') ],
	);

	is $result->{propagated}, 1, 'one env propagated';

	# Should have created pr/staging from staging
	my @create_branch = $git->calls('create_branch');
	ok( (grep { $_->[1] eq 'pr/staging' } @create_branch),
		'created local pr/staging branch' );

	# Should have committed
	ok( scalar($git->calls('commit')), 'committed propagation' );

	# Should have pushed pr/staging
	my @pushes = $git->calls('push');
	is scalar(@pushes), 1, 'one push call';
	ok( (grep { $_ eq 'pr/staging' } @{$pushes[0]}[2..$#{$pushes[0]}]),
		'pr/staging in push args' );

	# Should have created a PR (no existing → create_pr, not update_pr)
	ok( scalar($github->calls('create_pr')),
		'create_pr invoked for count=0 case' );
};

subtest 'PR mode count=0 cleans up stale remote branch first' => sub {
	plan tests => 2;
	my $git    = mock_git(remote_branch_exists => { 'pr/staging' => 1 });
	my $github = mock_github();
	propagate_envs_captured(
		base_args(),
		git     => $git,
		github  => $github,
		targets => [ pr_target('staging') ],
	);

	# Should have queried for stale remote presence and deleted it
	my @rb_exists = $git->calls('remote_branch_exists');
	ok( (grep { $_->[1] eq 'pr/staging' } @rb_exists),
		'checked remote for stale pr/staging' );
	my @deletes = $git->calls('delete_remote_branch');
	ok( (grep { $_->[1] eq 'pr/staging' } @deletes),
		'deleted stale remote pr/staging' );
};

subtest 'PR mode count=1 with new control_sha appends commit and updates PR' => sub {
	plan tests => 5;
	my $github = mock_github(
		open_prs => {
			'staging/pr/staging' => [
				{ number => 17, head => { ref => 'pr/staging' }, html_url => 'https://example/pr/17' },
			],
		},
	);
	# Local branch already exists from a prior propagation
	my $git = mock_git(
		branch_exists => { 'pr/staging' => 1 },
		# HEAD references a DIFFERENT control sha (not idempotent)
		log_subjects  => { 'pr/staging' => ['[pipeline] control@9999999 -> staging'] },
	);

	my $result = propagate_envs_captured(
		base_args(),
		git     => $git,
		github  => $github,
		targets => [ pr_target('staging') ],
	);

	is $result->{propagated}, 1, 'env counted as propagated';

	# Should NOT create a new local branch (already exists)
	is scalar($git->calls('create_branch')), 0,
		'no create_branch when local branch already present';

	# Should have appended a commit
	ok( scalar($git->calls('commit')), 'appended commit on existing branch' );

	# Should push the branch
	my @pushes = $git->calls('push');
	ok( (grep { $_ eq 'pr/staging' } @{$pushes[0]}[2..$#{$pushes[0]}]),
		'pushed pr/staging' );

	# Should call update_pr (not create_pr) for the existing PR
	ok( scalar($github->calls('update_pr')),
		'update_pr invoked for existing PR' );
};

subtest 'PR mode count=1 idempotent: HEAD matches control_sha → full skip' => sub {
	plan tests => 5;
	my $github = mock_github(
		open_prs => {
			'staging/pr/staging' => [
				{ number => 17, head => { ref => 'pr/staging' }, html_url => 'https://example/pr/17' },
			],
		},
	);
	# HEAD commit ALREADY references this control_short
	my $git = mock_git(
		branch_exists => { 'pr/staging' => 1 },
		log_subjects  => { 'pr/staging' => ['[pipeline] control@abcdef1 -> staging'] },
	);

	my $result = propagate_envs_captured(
		base_args(),
		git     => $git,
		github  => $github,
		targets => [ pr_target('staging') ],
	);

	cmp_deeply $result->{skipped_idempotent}, ['staging'],
		'env reported as skipped_idempotent';

	is scalar($git->calls('commit')),       0, 'no commit on idempotent re-run';
	is scalar($git->calls('push')),         0, 'no push on idempotent re-run';
	is scalar($github->calls('create_pr')), 0, 'no create_pr on idempotent re-run';
	is scalar($github->calls('update_pr')), 0, 'no update_pr on idempotent re-run';
};

subtest 'PR mode count>1 warns and uses first PR' => sub {
	plan tests => 3;
	my $github = mock_github(
		open_prs => {
			'staging/pr/staging' => [
				{ number => 17, head => { ref => 'pr/staging' }, html_url => 'https://example/pr/17' },
				{ number => 18, head => { ref => 'pr/staging' }, html_url => 'https://example/pr/18' },
			],
		},
	);
	my $git = mock_git(
		branch_exists => { 'pr/staging' => 1 },
		log_subjects  => { 'pr/staging' => ['[pipeline] control@9999999 -> staging'] },
	);

	# List-context capture so we can assert on the warning banner.
	my ($result, $stdout, $stderr) = propagate_envs_captured(
		base_args(),
		git     => $git,
		github  => $github,
		targets => [ pr_target('staging') ],
	);

	is $result->{propagated}, 1, 'still propagates';
	like "$stdout$stderr",
		qr/Multiple open PRs for staging with head pr\/staging.*using PR #17/s,
		'warns that multiple PRs were found and names the one being used';

	# Should have called update_pr against PR #17 (the first one)
	my @updates = $github->calls('update_pr');
	is $updates[0][2], 17, 'updated the first PR (number 17)';
};

subtest 'no_push kill switch suppresses all push and PR API writes in PR mode' => sub {
	plan tests => 4;
	my $git    = mock_git();
	my $github = mock_github();   # open_prs returns []

	my $result = propagate_envs_captured(
		base_args(no_push => 1),
		git     => $git,
		github  => $github,
		targets => [ pr_target('staging') ],
	);

	is $result->{propagated}, 1, 'env propagated locally';
	ok( scalar($git->calls('commit')), 'local commit still happens' );
	is scalar($git->calls('push')),         0, 'no git push under no_push';
	is scalar($github->calls('create_pr')) + scalar($github->calls('update_pr')), 0,
		'no PR API writes under no_push';
};

subtest 'PR mode dry_run reports without git or API mutations' => sub {
	plan tests => 4;
	my $git    = mock_git();
	my $github = mock_github();

	my $result = propagate_envs_captured(
		base_args(dry_run => 1),
		git     => $git,
		github  => $github,
		targets => [ pr_target('staging') ],
	);

	is $result->{propagated}, 1, 'reported as would-propagate';
	is scalar($git->calls('commit')),       0, 'no commit under dry_run';
	is scalar($git->calls('push')),         0, 'no push under dry_run';
	is scalar($github->calls('create_pr')) + scalar($github->calls('update_pr')), 0,
		'no PR API calls under dry_run';
};

subtest 'mixed direct + PR envs: direct envs and pr/ branches batched in one push' => sub {
	plan tests => 3;
	my $git    = mock_git();
	my $github = mock_github();

	propagate_envs_captured(
		base_args(),
		git     => $git,
		github  => $github,
		targets => [ direct_target('staging'), pr_target('preprod') ],
	);

	my @pushes = $git->calls('push');
	is scalar(@pushes), 1, 'single batched push call';
	my @branches = @{$pushes[0]}[2..$#{$pushes[0]}];
	ok( (grep { $_ eq 'staging' }    @branches), 'direct env staging in push' );
	ok( (grep { $_ eq 'pr/preprod' } @branches), 'PR branch pr/preprod in push' );
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
