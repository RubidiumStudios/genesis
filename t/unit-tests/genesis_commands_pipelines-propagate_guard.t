#!perl
#
# Propagation must not treat a missing env branch as "nothing to
# propagate".  The diff it computes is `git diff <env-branch>..<sha>`,
# which fails and yields an empty list when the branch is absent -- so
# without a guard, a repository whose branches were never created, or a
# --no-fetch run against a stale clone, reports success having done
# nothing.
#
use strict;
use warnings;

use lib 'lib';
use lib 't';
use Test::More;

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';
$ENV{NOCOLOR}         = 1;

use_ok 'Genesis::Commands::Pipelines';

# Stands in for Service::Git: only branch_exists is consulted.
{
	package FakeGit;
	sub new {
		my ($class, @branches) = @_;
		return bless {have => {map {($_ => 1)} @branches}}, $class;
	}
	sub branch_exists { return $_[0]{have}{$_[1]} ? 1 : 0 }
}

my @ENVS = qw(mgmt lab np1 qa);

subtest 'every branch present - nothing missing' => sub {
	plan tests => 1;

	my $git = FakeGit->new(@ENVS);
	is_deeply
		[Genesis::Commands::Pipelines::_missing_env_branches($git, \@ENVS)],
		[],
		'a fully set-up repository reports no missing branches';
};

subtest 'missing branches are reported in scope order' => sub {
	plan tests => 1;

	# Order matters for the operator: it should read like the DAG, not
	# like hash order.
	my $git = FakeGit->new('mgmt', 'qa');
	is_deeply
		[Genesis::Commands::Pipelines::_missing_env_branches($git, \@ENVS)],
		['lab', 'np1'],
		'absent branches come back in the order they were given';
};

subtest 'all branches missing' => sub {
	plan tests => 1;

	my $git = FakeGit->new();
	is_deeply
		[Genesis::Commands::Pipelines::_missing_env_branches($git, \@ENVS)],
		[@ENVS],
		'a repository with no env branches reports all of them';
};

subtest 'empty scope is not an error' => sub {
	plan tests => 1;

	# propagate exits earlier when scope is empty; this only asserts the
	# helper does not invent entries.
	my $git = FakeGit->new(@ENVS);
	is_deeply
		[Genesis::Commands::Pipelines::_missing_env_branches($git, [])],
		[],
		'an empty scope reports nothing missing';
};

done_testing;
