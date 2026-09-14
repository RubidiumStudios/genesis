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
use Test::More;
use Test::Exception;

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

done_testing;
