#!perl
#
# Propagation must not treat a missing env branch as "nothing to
# propagate".  The diff it computes is `git diff <env-branch>..<sha>`,
# which fails and yields an empty list when the branch is absent -- so
# without a guard, a repository whose branches were never created reports
# success having done nothing.
#
# The branch it asks for is the deployment slug the top composes, not the
# environment's own name, because in a typed repository those are two
# different refs and the name has none.  The environments still come back by
# name, which is what the creator below the guard takes.
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

# Stands in for Genesis::Top: only branch_for is consulted.  The guard asks
# for the deployment slug rather than the environment's own name, so the
# branches the fake git holds are slugs and the scope is names.
{
	package FakeTop;
	sub new { return bless {}, $_[0] }
	sub branch_for { return "$_[1]/bosh" }
}

my @ENVS = qw(mgmt lab np1 qa);
my $TOP  = FakeTop->new;

sub slugs { return map {"$_/bosh"} @_ }

subtest 'every branch present - nothing missing' => sub {
	plan tests => 1;

	my $git = FakeGit->new(slugs(@ENVS));
	is_deeply
		[Genesis::Commands::Pipelines::_missing_env_branches($TOP, $git, \@ENVS)],
		[],
		'a fully set-up repository reports no missing branches';
};

subtest 'missing branches are reported in scope order' => sub {
	plan tests => 1;

	# Order matters for the operator: it should read like the DAG, not
	# like hash order.
	my $git = FakeGit->new(slugs('mgmt', 'qa'));
	is_deeply
		[Genesis::Commands::Pipelines::_missing_env_branches($TOP, $git, \@ENVS)],
		['lab', 'np1'],
		'absent branches come back in the order they were given';
};

subtest 'all branches missing' => sub {
	plan tests => 1;

	my $git = FakeGit->new();
	is_deeply
		[Genesis::Commands::Pipelines::_missing_env_branches($TOP, $git, \@ENVS)],
		[@ENVS],
		'a repository with no env branches reports all of them';
};

subtest 'empty scope is not an error' => sub {
	plan tests => 1;

	# propagate exits earlier when scope is empty; this only asserts the
	# helper does not invent entries.
	my $git = FakeGit->new(slugs(@ENVS));
	is_deeply
		[Genesis::Commands::Pipelines::_missing_env_branches($TOP, $git, [])],
		[],
		'an empty scope reports nothing missing';
};

done_testing;
