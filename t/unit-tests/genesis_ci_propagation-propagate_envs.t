#!/usr/bin/env perl
# Proves T6: the baseline propagate tests, read through the two assertions.
# Each of the three shapes passes the structural assertions the file already
# makes and fails the invariant assertion, which is the point.  Their
# closures land at M5 and M10.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Deep;
use Test::Output;

use Genesis;
use Service::Git;
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
	             delete_remote_branch)) {
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
	# The run drives a session now, and this is the one the double hands
	# it.  Its switch goes through the double's own checkout, because a
	# switch is the checkout every row below was written against and
	# nothing about them changed but the door it comes through.
	*{"${pkg}::session"} = sub {
		my ($self, %opts) = @_;
		return $self->{_session} //=
			Test::Mock::PropEnvs::Session->new($self, %opts);
	};

	*{"${pkg}::unprefixed"} = sub {
		my $self = shift;
		# Identity in the mock (no prefix configured)
		return wantarray ? @_ : $_[0];
	};
}

# =========================================================================
# Mock Service::Git::Session
#
# The four verbs, recorded on the git double so a row can read the whole
# sequence in one log.  abort dies the way the real one does, because the
# rows that reach it are asserting that a failed run does not come back.
# =========================================================================
{
	package Test::Mock::PropEnvs::Session;

	sub new {
		my ($class, $git, %opts) = @_;
		return bless {git => $git, control => $opts{control}}, $class;
	}

	sub begin {
		my ($self) = @_;
		$self->{git}->_record('session_begin');
		$self->{active} = 1;
		return $self;
	}

	sub switch {
		my ($self, $target) = @_;
		$self->{git}->checkout($target);
		return $self;
	}

	sub finish {
		my ($self) = @_;
		$self->{git}->_record('session_finish');
		$self->{active} = 0;
		return $self;
	}

	sub abort {
		my ($self, $error) = @_;
		$self->{git}->_record('session_abort', $error);
		$self->{active} = 0;
		die $error;
	}
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
# Mock Genesis::Top
#
# propagate_envs asks the top for the branch a pull request opens on, and
# nothing else.  Every row below is about the decision tree and the
# batched push rather than about how a branch is named, so the mock
# answers with the short pr/<env> name those rows were written against
# and leaves the composition itself to genesis_top-pr_branch.t.
# =========================================================================
sub mock_top {
	my (%opts) = @_;
	my $self = bless {_refuse => $opts{refuse} // 0},
		'Test::Mock::PropEnvs::Top';
	$self;
}

{
	no strict 'refs';
	no warnings 'redefine';
	my $pkg = 'Test::Mock::PropEnvs::Top';

	*{"${pkg}::pr_branch_for"} = sub {
		my ($self, $env_name) = @_;
		# The real accessor refuses a prefix that collides with a branch
		# some environment already owns, and it refuses by dying, because
		# Genesis::bail dies rather than exits wherever an eval is open.
		# The refuse option stands in for that refusal.
		die "pr/$env_name would collide with a deployment branch\n"
			if $self->{_refuse};
		return "pr/$env_name";
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
		top           => mock_top(),
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

subtest 'a refusal to name a PR branch reaches the caller' => sub {
	plan tests => 3;
	my $git    = mock_git();
	my $github = mock_github();

	# The per-target eval turns whatever a target throws into a propagation
	# failure, which is right for a failed checkout and wrong for a prefix
	# the repository cannot use at all.  So the branch names are composed
	# before the loop, and a refusal to compose one leaves by the front
	# door, where the command can exit on the code the refusal chose.
	my ($result, $err);
	output_from {
		$result = eval {
			Genesis::CI::Propagation::propagate_envs(
				base_args(),
				top     => mock_top(refuse => 1),
				git     => $git,
				github  => $github,
				targets => [ direct_target('staging'), pr_target('preprod') ],
			);
		};
		$err = $@;
	};

	is $result, undef, 'the call does not answer';
	like $err, qr{would collide with a deployment branch},
		'the refusal reaches the caller unchanged';
	is scalar($git->calls('commit')), 0,
		'and nothing was committed before it was raised';
};

# =========================================================================
# The baseline shapes, read through the harness assertions
#
# Every row above asserts on the structure propagate_envs returns and none
# of them reads working state, which is how a run that reported its files
# propagated and lost them passed.  The three rows below read what the run
# left behind instead.  Each of the three fails on an assertion that names
# the breach, which is the point of writing them now.
# =========================================================================

# A git double that dies while committing to one named environment, so a
# walk meets its failure in the middle of its targets rather than at the
# end.  It sits on the recording double so every other call is still
# recorded, which is what the row after the failure reads.
{
	no strict 'refs';
	no warnings 'redefine';
	my $pkg = 'Test::Mock::PropEnvs::Git::Failing';
	@{"${pkg}::ISA"} = ('Test::Mock::PropEnvs::Git');
	*{"${pkg}::commit"} = sub {
		my ($self, @args) = @_;
		die "the write to $self->{_current_branch} failed\n"
			if ($self->{_fail_env} // '') eq ($self->{_current_branch} // '');
		return Test::Mock::PropEnvs::Git::commit($self, @args);
	};
}

sub _git_failing_on {
	my ($env, %opts) = @_;
	my $git = mock_git(%opts);
	$git->{_fail_env} = $env;
	return bless $git, 'Test::Mock::PropEnvs::Git::Failing';
}

# Two of the three rows that used to stand here are closed: H1 below, by the
# session taking the write sequence over, and H2, whose subject is gone with
# restore_branch.  The one that is still open is marked rather than skipped,
# because a skipped row is one nobody looks at and the whole reason these
# exist is that the shapes stayed invisible until a real loss surfaced one of
# them.  The mark names the step whose commit removes it.
subtest 'H1: a failed delivery leaves nothing staged' => sub {
	plan tests => 3;

	# H1 closed at M5, where the session took the write sequence over.  The
	# delivery writes two files into the index and then dies, and what the
	# run does with them is the whole point: it does not come back with an
	# errors list and a dirty tree, it names them, throws them away, and
	# leaves the operator where they started.
	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n", 'ops/one.yml' => "---\none: 1\n"},
		message => 'two files',
		push    => 1,
	);

	my $git = fault_git($h);
	fail_on($git, 'commit', 1, message => 'the harness stopped before the commit');

	my $w = snapshot_w($h);
	my $err = exception(sub {
		propagate_envs_captured(
			base_args(
				control_sha   => $control,
				control_short => substr($control, 0, 7),
				no_push       => 1,
			),
			git     => $git,
			github  => undef,
			targets => [
				direct_target($h->slug('qa'),
					changed => ['qa.yml', 'ops/one.yml']),
			],
		);
	});

	like($err, qr/qa\.yml/,
		'the run died naming what the failed delivery had written');
	like($err, qr/discard/i, 'and saying it was being thrown away');
	assert_w_restored($w, 'H1: the failed delivery left nothing staged');
};

# H2, the silent failed restore, was proved here against restore_branch, and
# the sub is gone.  Its closure is asserted where the restore now lives, in
# t/unit-tests/service_git_session-abort.t.

TODO: {
	local $TODO = 'H3 closes at M10, when the walk reports every environment';

	subtest 'H3: the loop stops at the first failing environment' => sub {
		plan tests => 2;

		my $git = _git_failing_on('lab');
		my $result = propagate_envs_captured(
			base_args(),
			git     => $git,
			github  => undef,
			targets => [
				direct_target('qa'), direct_target('lab'), direct_target('prod'),
			],
		);

		is(
			$result->{propagated} + scalar(@{$result->{errors} || []}), 3,
			'H3: every environment in scope has an outcome');
		ok(
			(grep {$_->[1] eq 'prod'} $git->calls('checkout')),
			'H3: the loop reached the environment after the failure');
	};
}

# A run that should not come back, read as the error it raised.  bail dies
# rather than exits wherever an eval is open, and the ignore switch is
# cleared so that stays true however the file was invoked.
sub exception {
	my ($code) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	eval { $code->(); 1 } and return '';
	return $@;
}

done_testing;

# vim: ts=2 sw=2 sts=2 noet
