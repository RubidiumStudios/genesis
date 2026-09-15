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
# The body, now that the refresh is unconditional
# ======================================================================
#
# Reaching the body takes a working tree, a vault and a git repository,
# which is why the rows above stop at the scope decision.  The propagation
# harness builds all three, so what the command decides about a branch can be
# read off the command itself rather than off the mapping behind it.
#
# --no-fetch is gone.  Every command refreshes before its first read of a
# branch (D40), so the question the flag used to raise cannot be asked any
# more.  A branch that is in neither this clone nor its tracking refs is one
# the remote has just been asked about and does not have, which is a branch
# to create rather than a branch to withhold.

subtest 'a branch this clone has is reconciled and not withheld' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	plan tests => 4;

	# The embedded genesis is one of the files the propagation set carries,
	# so the branch has something real on it either way.
	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0', embed => 1);

	# The branch is this clone's alone.  The stray file stands for whatever
	# else the branch has picked up, so the environment has a real
	# reconciliation waiting for it rather than nothing to do.
	local_branch($h, 'qa');
	hand_commit($h, 'qa', copy => 'a', push => 0,
		files => {'stray.yml' => "---\nno environment depends on this\n"});
	stand_on($h, 'control');

	# The run is dry, because a dry run reports the answer and stops there,
	# where a writing run goes on to the reconciliation and dies on this
	# fixture.  The answer is decided before the two part company, so a dry
	# run is where it can be read rather than inferred.  Genesis reports on
	# standard error, so the run's account of itself comes back in the second
	# value rather than the first.
	my (undef, $err) = $h->run_genesis('pipeline-prepare', '-n');

	like $err, qr/reconciled\s+\S*qa/,
		'the run says it would reconcile the branch, and names it';
	like $err, qr/Would prepare: .*1 reconciled/,
		'and counts it among the environments it would prepare';
	unlike $err, qr/skipped/,
		'so a branch that is here is not withheld for want of the remote';
};

subtest 'a branch in neither place is created, the remote having been asked' => sub {
	# Four rows, and one more for each of the two runs' restoration assertions.
	plan tests => 6;

	# The embed is the fixture and not the claim: .genesis/bin/genesis is one
	# of the propagation files every environment carries, so a branch cut
	# from a control tree that lacks it cannot be seeded at all.
	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0', embed => 1);

	# The answer comes off a dry run, for the reason the row above gives.
	my (undef, $dry) = $h->run_genesis('pipeline-prepare', '-n');

	like $dry, qr/created\s+\S*lab/,
		'a branch that is nowhere is one the run would create';
	like $dry, qr/Would prepare: .*1 created/,
		'and counts it among the environments it would prepare';
	unlike $dry, qr/skipped/,
		'rather than withholding it for want of the remote';

	# The writing run is here for the ref alone.  It dies on this fixture
	# once the branch is cut, because this control tree already carries the
	# whole propagation set and the seed commit then stages nothing, but the
	# ref is written before that happens and a withheld branch has no ref at
	# all.
	$h->run_genesis('pipeline-prepare');

	isnt ref_in($h->a, 'refs/heads/lab'), undef,
		'and the run writes the local ref';
};

done_testing;
