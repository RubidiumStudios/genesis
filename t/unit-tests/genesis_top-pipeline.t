#!perl
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
use_ok 'Genesis::Config';
# Initialize $Genesis::RC for tests that consult global config
provide_rc();
use_ok 'Genesis::Top';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Helper: top with CI config primed (so ci_configured is true) and a
# dev kit linked so env-file validation passes.
sub make_ci_top {
	my $top = make_top(name => 'pipeline-test', no_vault => 1);
	$top->link_dev_kit('t/src/simple');
	$top->config->set('ci.enabled',       1);
	$top->config->set('ci.provider.type', 'manual');
	return $top;
}

# Helper: drop a valid env yaml file into a Top's path.
sub put_env {
	my ($top, $name) = @_;
	put_file($top->path("$name.yml"), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: $name
EOF
}

# ======================================================================
# pipeline_env_names
# ======================================================================

subtest 'pipeline_env_names - empty list when CI is not configured' => sub {
	plan tests => 1;

	# make_top creates .genesis/config with no ci.* keys → ci_configured false
	my $top = make_top(name => 'no-ci', no_vault => 1);
	is_deeply [$top->pipeline_env_names], [],
		'no-CI top returns empty env list';
};

subtest 'pipeline_env_names - returns sorted env names when CI is configured' => sub {
	plan tests => 1;

	my $top = make_ci_top();
	put_env($top, $_) for qw(qa lab prod np1);

	is_deeply [$top->pipeline_env_names], [qw(lab np1 prod qa)],
		'env names returned sorted alphabetically';
};

subtest 'pipeline_env_names - empty list when no env files exist' => sub {
	plan tests => 1;

	my $top = make_ci_top();
	# no env yaml files dropped → envs() returns empty

	is_deeply [$top->pipeline_env_names], [],
		'no env files yields empty list';
};

# ======================================================================
# fetch_pipeline_envs
# ======================================================================
#
# Build a captured-call mock git so we can assert fetch_branches was
# invoked with the right inputs (or not invoked at all).
sub mock_git {
	my %opts = @_;
	my $calls = [];
	my $git = bless {
		_calls         => $calls,
		_default_remote => $opts{default_remote},
		_result         => $opts{result},  # optional override of result hash
	}, 'Test::Mock::Git';
	$git;
}

{
	package Test::Mock::Git;
	sub default_remote { $_[0]->{_default_remote} }
	sub fetch_branches {
		my ($self, $names, $remote) = @_;
		push @{$self->{_calls}}, {
			method  => 'fetch_branches',
			names   => [@$names],
			remote  => $remote,
		};
		my $result = $self->{_result} // { ok => 1, kind => 'success' };
		return wantarray ? ($self, $result) : $self;
	}
}

subtest 'fetch_pipeline_envs - no-op when CI is not configured' => sub {
	plan tests => 2;

	my $top = make_top(name => 'fp-no-ci', no_vault => 1);
	my $git = mock_git(default_remote => 'origin');

	is $top->fetch_pipeline_envs($git), 1, 'returns 1 (success no-op)';
	is scalar @{$git->{_calls}}, 0, 'fetch_branches not invoked';
};

subtest 'fetch_pipeline_envs - no-op when no default remote' => sub {
	plan tests => 2;

	my $top = make_ci_top();
	my $git = mock_git();  # no remote

	is $top->fetch_pipeline_envs($git), 1, 'returns 1';
	is scalar @{$git->{_calls}}, 0, 'fetch_branches not invoked';
};

subtest 'fetch_pipeline_envs - no-op when no env files exist' => sub {
	plan tests => 2;

	my $top = make_ci_top();
	my $git = mock_git(default_remote => 'origin');

	is $top->fetch_pipeline_envs($git), 1, 'returns 1';
	is scalar @{$git->{_calls}}, 0, 'fetch_branches not invoked with empty list';
};

subtest 'fetch_pipeline_envs - calls fetch_branches with sorted names + remote' => sub {
	plan tests => 4;

	my $top = make_ci_top();
	put_env($top, $_) for qw(qa lab prod);
	my $git = mock_git(default_remote => 'dev');

	is $top->fetch_pipeline_envs($git), 1, 'returns 1 on success';
	is scalar @{$git->{_calls}}, 1, 'fetch_branches called exactly once';

	my $call = $git->{_calls}[0];
	is_deeply $call->{names}, [qw(lab prod qa)],
		'names are sorted env list, no control';
	is $call->{remote}, 'dev',
		'remote is passed through from default_remote';
};

subtest 'fetch_pipeline_envs - include_control prepends control to names' => sub {
	plan tests => 1;

	my $top = make_ci_top();
	put_env($top, $_) for qw(qa prod);
	my $git = mock_git(default_remote => 'origin');

	$top->fetch_pipeline_envs($git, include_control => 1);

	is_deeply $git->{_calls}[0]{names},
		[qw(control prod qa)],
		'control is included in the refspec list when requested';
};

# ======================================================================
# fetch_pipeline_envs - failure-kind routing
# ======================================================================

# Capture warning/debug calls inside Top so we can assert routing without
# parsing stderr. warning/debug are imported into Genesis::Top via
# `use Genesis;`, so the symbols to override live in Genesis::Top.
sub capture_log {
	my ($warns, $debugs) = ([], []);
	no warnings qw(redefine once);
	# Returning a guard pair so callers can `my ($w, $d, $guard) = capture_log()`.
	# Since `local *` can't escape its scope, we instead install plain
	# overrides and rely on the test cleaning up by going out of scope
	# at end of subtest.  Easier: the caller owns the locals.
	($warns, $debugs);
}

subtest 'fetch_pipeline_envs - a branch the remote lacks is not a failure' => sub {
	plan tests => 1;

	# An environment whose branch exists nowhere yet is the ordinary state
	# of a repository that has not been prepared, and it is what propagate's
	# missing-branch bail exists to diagnose.  Raising here would preempt
	# that bail with a raw git error and leave the operator without the
	# pipeline-prepare hint.
	my $top = make_ci_top();
	put_env($top, $_) for qw(qa lab);
	my $git = mock_git(
		default_remote => 'origin',
		result         => { ok => 1, kind => 'success',
		                    fetched => ['qa'], absent => ['lab'] },
	);

	is $top->fetch_pipeline_envs($git), 1,
		'absent branches are reported by fetch_branches, not raised here';
};

subtest 'fetch_pipeline_envs - network failure bails with --no-fetch hint' => sub {
	plan tests => 1;

	my $top = make_ci_top();
	put_env($top, 'qa');
	my $git = mock_git(
		default_remote => 'origin',
		result         => { ok => 0, kind => 'network', err => 'Could not resolve host: ...' },
	);

	throws_ok {
		$top->fetch_pipeline_envs($git);
	} qr/Failed to reach.*origin.*--no-fetch/is,
		'network failure bails with remote name and --no-fetch hint';
};

subtest 'fetch_pipeline_envs - auth failure bails with --no-fetch hint' => sub {
	plan tests => 1;

	my $top = make_ci_top();
	put_env($top, 'qa');
	my $git = mock_git(
		default_remote => 'origin',
		result         => { ok => 0, kind => 'auth', err => 'Authentication failed' },
	);

	throws_ok {
		$top->fetch_pipeline_envs($git);
	} qr/authenticate.*origin.*--no-fetch/is,
		'auth failure bails with retry guidance and --no-fetch hint';
};

subtest 'fetch_pipeline_envs - unknown failure bails with raw err' => sub {
	plan tests => 1;

	my $top = make_ci_top();
	put_env($top, 'qa');
	my $git = mock_git(
		default_remote => 'origin',
		result         => { ok => 0, kind => 'unknown', err => 'weird transient error' },
	);

	throws_ok {
		$top->fetch_pipeline_envs($git);
	} qr/weird transient error.*--no-fetch/is,
		'unknown failure bails with raw err and --no-fetch hint';
};

# ======================================================================
# pipeline_topology
#
# The single answer to "what environments are in this pipeline, and in
# what order".  Before this existed the question had two implementations
# -- Top::envs by glob, and ASTBuilder::_build_from_env_files by DAG --
# which agreed by coincidence rather than by construction, and the DAG
# one was private and called from four places.
# ======================================================================

# Helper: env yaml carrying a genesis.pipeline.prior_env edge.
sub put_env_after {
	my ($top, $name, $prior) = @_;
	put_file($top->path("$name.yml"), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: $name
  pipeline:
    prior_env: $prior
EOF
}

subtest 'pipeline_topology - empty when CI is not configured' => sub {
	plan tests => 2;

	my $top = make_top(name => 'no-ci', no_vault => 1);
	my $topo = $top->pipeline_topology;

	is_deeply $topo->{nodes}, {}, 'no nodes without CI configured';
	is_deeply $topo->{order}, [],  'no order without CI configured';
};

subtest 'pipeline_topology - every valid env is a node' => sub {
	plan tests => 2;

	# Envs with no genesis.pipeline block still belong: pipeline-status
	# reports on them, and pipeline-prepare must give them branches.
	my $top = make_ci_top();
	put_env($top, $_) for qw(alpha beta);

	my $topo = $top->pipeline_topology;
	is_deeply [sort keys %{$topo->{nodes}}], [qw(alpha beta)],
		'envs without pipeline metadata are still nodes';
	is_deeply $topo->{edges}, [], 'and carry no edges';
};

subtest 'pipeline_topology - prior_env becomes an edge' => sub {
	plan tests => 3;

	my $top = make_ci_top();
	put_env($top, 'mgmt');
	put_env_after($top, 'lab', 'mgmt');

	my $topo = $top->pipeline_topology;
	is_deeply $topo->{edges}, [{from => 'mgmt', to => 'lab'}],
		'prior_env produces one edge';
	is $topo->{parent_of}{lab}, 'mgmt', 'parent_of resolves upward';
	is_deeply $topo->{children}{mgmt}, ['lab'], 'children resolves downward';
};

subtest 'pipeline_topology - order is topological, roots first' => sub {
	plan tests => 1;

	# Deliberately created out of order: a caller iterating this must
	# see mgmt before lab, and lab before its own children.
	my $top = make_ci_top();
	put_env_after($top, 'qa',  'lab');
	put_env_after($top, 'lab', 'mgmt');
	put_env($top, 'mgmt');

	is_deeply $top->pipeline_topology->{order}, [qw(mgmt lab qa)],
		'ancestors precede descendants regardless of file order';
};

subtest 'pipeline_topology - siblings are ordered deterministically' => sub {
	plan tests => 1;

	# Two envs at the same depth must not come back in hash order, or
	# output and test expectations wobble between runs.
	my $top = make_ci_top();
	put_env($top, 'mgmt');
	put_env_after($top, 'qa',  'mgmt');
	put_env_after($top, 'lab', 'mgmt');

	is_deeply $top->pipeline_topology->{order}, [qw(mgmt lab qa)],
		'siblings sort by name';
};

subtest 'pipeline_env_names agrees with the topology' => sub {
	plan tests => 2;

	# The point of the consolidation: one source, so these cannot drift.
	my $top = make_ci_top();
	put_env($top, 'mgmt');
	put_env_after($top, 'lab', 'mgmt');

	my @names = $top->pipeline_env_names;
	is_deeply [@names], [qw(lab mgmt)],
		'pipeline_env_names stays sorted for its existing callers';
	is_deeply [sort @names], [sort keys %{$top->pipeline_topology->{nodes}}],
		'and covers exactly the topology nodes';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
