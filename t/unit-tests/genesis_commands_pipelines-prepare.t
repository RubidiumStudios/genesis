#!perl
#
# `genesis pipeline-prepare` runs in one of two scopes, decided by
# Genesis' own dispatcher rather than by a flag:
#
#   genesis pipeline-prepare          repo mode -- every environment
#   genesis <env> pipeline-prepare    env mode  -- that one
#
# The scope decision is separated from the command body because reaching
# the body needs a working tree, a vault and a git repository, while the
# decision is what actually goes wrong: preparing the whole repository
# when one environment was asked for, or silently ignoring a name that
# is not in the pipeline.
#
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;
use Test::Exception;

provide_rc();

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';
$ENV{NOCOLOR}         = 1;

use_ok 'Genesis::Commands::Pipelines';

# The shape Genesis::Top::pipeline_topology returns, reduced to what the
# scope decision reads.
my $TOPO = {
	nodes => {map {($_ => {})} qw(mgmt lab np1 qa)},
	order => [qw(mgmt lab np1 qa)],
};

sub scope_for {
	return Genesis::Commands::Pipelines::_prepare_scope($TOPO, @_);
}

# ======================================================================
# Repo mode
# ======================================================================

subtest 'no environment given prepares the whole pipeline' => sub {
	plan tests => 1;

	# prepare_branch is idempotent, so healthy environments cost nothing
	# and the command can honestly claim to have ensured the repository.
	is_deeply [scope_for(undef)], [qw(mgmt lab np1 qa)],
		'repo mode covers every environment';
};

subtest 'repo mode follows topology order' => sub {
	plan tests => 1;

	# Ancestors first: an operator watching the output should see the
	# pipeline built in the order it will deploy in.
	is_deeply [scope_for(undef)], $TOPO->{order},
		'not alphabetical, not hash order';
};

subtest 'an empty pipeline is empty, not an error' => sub {
	plan tests => 1;

	my $empty = {nodes => {}, order => []};
	is_deeply
		[Genesis::Commands::Pipelines::_prepare_scope($empty, undef)],
		[],
		'nothing to prepare rather than a bail';
};

# ======================================================================
# Env mode
# ======================================================================

subtest 'an environment given prepares only that one' => sub {
	plan tests => 1;

	is_deeply [scope_for('lab')], ['lab'],
		'env mode does not touch its siblings or its parent';
};

subtest 'env mode works for a root environment' => sub {
	plan tests => 1;

	is_deeply [scope_for('mgmt')], ['mgmt'],
		'having no parent is not special here';
};

subtest 'an environment outside the pipeline is rejected' => sub {
	plan tests => 2;

	# Silently ignoring it would report success having prepared nothing,
	# which is the failure mode this command exists to end.
	throws_ok {scope_for('nope')} qr/nope/,
		'the offending name appears in the error';
	throws_ok {scope_for('nope')} qr/pipeline/i,
		'and it says what it is not part of';
};

# ======================================================================
# The body, under --no-fetch
# ======================================================================
#
# Reaching the body takes a working tree, a vault and a git repository,
# which is why the rows above stop at the scope decision.  The propagation
# harness builds all three, so the two answers --no-fetch turns on can be
# read off the command itself rather than off the mapping behind it.

subtest 'a branch this clone has is not skipped under --no-fetch' => sub {
	plan tests => 6;

	# The embedded genesis is one of the files the propagation set carries,
	# so the branch has something real on it either way.
	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0', embed => 1);

	# The branch is this clone's alone, which is the half of --no-fetch that
	# was answered backwards, because a record comes back for such a branch
	# and the flag was being read off that record.  The stray file stands for
	# whatever else the branch has picked up, so the environment has a real
	# reconciliation waiting for it rather than nothing to do.
	local_branch($h, 'qa');
	hand_commit($h, 'qa', copy => 'a', push => 0,
		files => {'stray.yml' => "---\nno environment depends on this\n"});
	stand_on($h, 'control');

	# Both runs are dry, because a dry run reports the answer and stops
	# there, where a writing run goes on to the reconciliation and dies on
	# this fixture whatever the flag says.  The answer is decided before
	# either run parts company with the other, so a dry run is where it can
	# be read rather than inferred.  Genesis reports on standard error, so
	# each run's account of itself comes back in the second value.
	my (undef, $with)    = $h->run_genesis('pipeline-prepare', '-n', '--no-fetch');
	my (undef, $without) = $h->run_genesis('pipeline-prepare', '-n');

	like $with, qr/reconciled\s+\S*qa/,
		'the run says it would reconcile the branch, and names it';
	like $with, qr/Would prepare: .*1 reconciled/,
		'and counts it among the environments it would prepare';
	unlike $with, qr/skipped/,
		'so a branch that is here is not withheld for want of the remote';
	is scalar($without =~ /reconciled\s+\S*qa/), 1,
		'which is the same answer the run gives without the flag';
};

subtest 'a branch in neither place is skipped under --no-fetch' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0');

	my (undef, $err) = $h->run_genesis('pipeline-prepare', '--no-fetch');

	like $err, qr/skipped.*lab/s,
		'a branch that is nowhere is withheld and named';
	is ref_in($h->a, 'refs/heads/lab'), undef,
		'and is not created off HEAD without the remote being asked';
	like $err, qr/1 skipped/, 'the summary counts it';
};

done_testing;
