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

# Helper: top with the pipeline block primed, so pipeline_enabled is true,
# and a dev kit linked so env-file validation passes.
sub make_ci_top {
	my $top = make_top(name => 'pipeline-test', no_vault => 1);
	$top->link_dev_kit('t/src/simple');
	$top->config->set('pipeline.enabled',       1);
	$top->config->set('pipeline.provider.type', 'manual');
	# The deployment type is what the slug's second half is, and the refresh
	# asks for slugs, so it is named here rather than left as the repository
	# name and read back as qa/pipeline-test in every expectation below.
	$top->config->set('deployment_type', 'bosh');
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

	# make_top creates .genesis/config with no pipeline.* keys, so
	# pipeline_enabled is false
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

subtest 'fetch_pipeline_envs - undef where there is no pipeline' => sub {
	plan tests => 2;

	my $top = make_top(name => 'fp-no-ci', no_vault => 1);
	my $git = mock_git(default_remote => 'origin');

	is $top->fetch_pipeline_envs($git), undef, 'there is nothing to refresh';
	is scalar @{$git->{_calls}}, 0, 'fetch_branches not invoked';
};

subtest 'fetch_pipeline_envs - undef where there is no remote' => sub {
	plan tests => 2;

	my $top = make_ci_top();
	my $git = mock_git();  # no remote

	is $top->fetch_pipeline_envs($git), undef, 'there is nowhere to refresh from';
	is scalar @{$git->{_calls}}, 0, 'fetch_branches not invoked';
};

subtest 'fetch_pipeline_envs - control is refreshed even with no environments' => sub {
	plan tests => 2;

	# The old sub returned early on an empty environment list and refreshed
	# nothing at all, which left control read out of whatever the clone
	# happened to hold.  Control is the branch every other read is measured
	# against, so it is refreshed whether or not anything follows it.
	my $top = make_ci_top();
	my $git = mock_git(default_remote => 'origin');

	my $result = $top->fetch_pipeline_envs($git);

	is $result->{ok}, 1, 'the refresh happened and came back ok';
	is_deeply $git->{_calls}[0]{names}, ['control'],
		'and control was the one branch it asked for';
};

subtest 'fetch_pipeline_envs - control leads, and the rest are deployment branches' => sub {
	plan tests => 3;

	# The names are slugs rather than environment names, because the branch
	# is per deployment and not per environment.  A refresh asking for `qa`
	# fetched nothing at all in a typed repository, because the ref on the
	# remote is `qa/bosh`.
	my $top = make_ci_top();
	put_env($top, $_) for qw(qa lab prod);
	my $git = mock_git(default_remote => 'dev');

	$top->fetch_pipeline_envs($git);

	is scalar @{$git->{_calls}}, 1, 'fetch_branches called exactly once';

	my $call = $git->{_calls}[0];
	is_deeply $call->{names}, [qw(control lab/bosh prod/bosh qa/bosh)],
		'control leads the sorted deployment branches';
	is $call->{remote}, 'dev',
		'remote is passed through from default_remote';
};

subtest 'fetch_pipeline_envs - the refresh result is what comes back' => sub {
	plan tests => 2;

	# The caller reports the creation of a local ref from the `created`
	# list, so the whole result is handed back rather than a bare success.
	my $top = make_ci_top();
	put_env($top, $_) for qw(qa lab);
	my $git = mock_git(
		default_remote => 'origin',
		result         => { ok => 1, kind => 'success',
		                    fetched => ['control', 'qa/bosh'],
		                    created => ['qa/bosh'], absent => ['lab/bosh'] },
	);

	my $result = $top->fetch_pipeline_envs($git);

	is_deeply $result->{created}, ['qa/bosh'],
		'the created list reaches the caller';
	is_deeply $result->{absent}, ['lab/bosh'],
		'and so does the absent one';
};

subtest 'fetch_pipeline_envs - a branch the remote lacks is not a failure' => sub {
	plan tests => 1;

	# An environment whose branch exists nowhere yet is the ordinary state
	# of a repository the apply has not run against, and propagate reports
	# it as awaiting genesis pipeline-apply.  Raising here would preempt
	# that report with a raw git error and leave the operator without the
	# name of the command that cuts the branch.
	my $top = make_ci_top();
	put_env($top, $_) for qw(qa lab);
	my $git = mock_git(
		default_remote => 'origin',
		result         => { ok => 1, kind => 'success',
		                    fetched => ['qa/bosh'], created => [],
		                    absent => ['lab/bosh'] },
	);

	is $top->fetch_pipeline_envs($git)->{ok}, 1,
		'absent branches are reported by fetch_branches, not raised here';
};

# ======================================================================
# fetch_pipeline_envs - the refusal, and the three kinds it tells apart
# ======================================================================
#
# The refusal names the remote, says which of the three kinds it was, quotes
# git's own message, and closes with what was not done.  It advises no flag,
# because there is none to advise.  Every command but pipeline-status
# refreshes unconditionally, and a retry is the way out.  The exit code the
# refusal carries is TEMPFAIL, which is read from the product in
# t/integration-tests/genesis_commands_pipelines-refresh_flags.t, where a
# whole command runs and its exit status can be asked for.

subtest 'fetch_pipeline_envs - an unreachable remote names the network' => sub {
	plan tests => 2;

	my $top = make_ci_top();
	put_env($top, 'qa');
	my $git = mock_git(
		default_remote => 'origin',
		result         => { ok => 0, kind => 'network', err => 'Could not resolve host: ...' },
	);

	throws_ok {
		$top->fetch_pipeline_envs($git, command => 'propagate');
	} qr/Failed\s+to\s+reach.*origin.*network or the remote is\s+unreachable/is,
		'the refusal names the remote and the network';

	# The refusal is wrapped to the terminal width before it is raised, so a
	# phrase that spans the wrap arrives with a newline and an indent inside
	# it, and every match below allows for that.
	throws_ok {
		$top->fetch_pipeline_envs($git, command => 'propagate');
	} qr/Nothing\s+was\s+written/is,
		'and closes by saying nothing was written';
};

subtest 'fetch_pipeline_envs - a rejected credential names the credential' => sub {
	plan tests => 1;

	my $top = make_ci_top();
	put_env($top, 'qa');
	my $git = mock_git(
		default_remote => 'origin',
		result         => { ok => 0, kind => 'auth', err => 'Authentication failed' },
	);

	throws_ok {
		$top->fetch_pipeline_envs($git);
	} qr/Failed\s+to\s+reach.*origin.*rejected our\s+credentials/is,
		'the refusal says the remote rejected us rather than that it was down';
};

subtest 'fetch_pipeline_envs - anything else carries git\'s own message' => sub {
	plan tests => 1;

	my $top = make_ci_top();
	put_env($top, 'qa');
	my $git = mock_git(
		default_remote => 'origin',
		result         => { ok => 0, kind => 'unknown', err => 'weird transient error' },
	);

	throws_ok {
		$top->fetch_pipeline_envs($git);
	} qr/the remote failed the\s+request.*weird transient error/is,
		'the refusal quotes what git said';
};

subtest 'fetch_pipeline_envs - the caller names the act and the outcome' => sub {
	plan tests => 2;

	# The deploy does not "run genesis qa deploy" in its own refusal; it
	# deploys, and what it failed to do is deploy anything.  Both phrases
	# come from the caller so one sub can refuse for every command.
	my $top = make_ci_top();
	put_env($top, 'qa');
	my $git = mock_git(
		default_remote => 'origin',
		result         => { ok => 0, kind => 'network', err => 'Could not resolve host: ...' },
	);

	throws_ok {
		$top->fetch_pipeline_envs($git, action => 'deploy',
			outcome => 'Nothing was deployed.');
	} qr/Refusing\s+to\s+deploy/is, 'the act is the caller\'s word';

	throws_ok {
		$top->fetch_pipeline_envs($git, action => 'deploy',
			outcome => 'Nothing was deployed.');
	} qr/Nothing\s+was\s+deployed/is, 'and so is the outcome';
};

# ======================================================================
# pipeline_topology
#
# The single answer to "what environments are in this pipeline, and in
# what order".  Before this existed the question had two implementations
# -- Top::envs by glob, and ASTBuilder::build_from_env_files by DAG --
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
	# reports on them, and pipeline-apply must give them branches.
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
