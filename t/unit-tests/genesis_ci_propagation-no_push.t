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

# Minimal git double: records every push so we can assert that --no-push
# reaches the remote zero times.
{
	package FakeGit;
	sub new { bless { pushes => [] }, shift }
	sub default_remote { 'origin' }
	sub restore_branch { $_[0] }
	sub reset_working_tree { $_[0] }
	sub push {
		my ($self, $remote, @branches) = @_;
		push @{$self->{pushes}}, [$remote, @branches];
		return { map { $_ => 1 } @branches };
	}
}

subtest 'no_push suppresses the control branch push' => sub {
	# push_extra_branches always carries the control branch (Pipelines.pm
	# adds it whenever there are targets).  The no_push kill switch has to
	# cover it: honouring the flag for environment branches while still
	# pushing control is worse than not offering the flag at all.
	plan tests => 2;

	my $git = FakeGit->new;
	my $result = Genesis::CI::Propagation::propagate_envs(
		git                 => $git,
		targets             => [],
		control             => 'control',
		control_sha         => 'abc1234',
		control_short       => 'abc1234',
		no_push             => 1,
		push_extra_branches => ['control'],
	);

	is(scalar @{$git->{pushes}}, 0, 'nothing was pushed to the remote')
		or diag(explain($git->{pushes}));
	is(scalar @{$result->{errors} || []}, 0, 'no errors reported');
};

subtest 'without no_push the control branch is still pushed' => sub {
	# The default behaviour must be untouched: propagation pushes control
	# so the environment branches have a reachable ancestor.
	plan tests => 2;

	my $git = FakeGit->new;
	Genesis::CI::Propagation::propagate_envs(
		git                 => $git,
		targets             => [],
		control             => 'control',
		control_sha         => 'abc1234',
		control_short       => 'abc1234',
		no_push             => 0,
		push_extra_branches => ['control'],
	);

	is(scalar @{$git->{pushes}}, 1, 'one push happened');
	is_deeply($git->{pushes}[0], ['origin', 'control'],
		'control was pushed to origin');
};

subtest 'dry_run pushes nothing regardless of extras' => sub {
	plan tests => 1;

	my $git = FakeGit->new;
	Genesis::CI::Propagation::propagate_envs(
		git                 => $git,
		targets             => [],
		control             => 'control',
		control_sha         => 'abc1234',
		control_short       => 'abc1234',
		dry_run             => 1,
		push_extra_branches => ['control'],
	);

	is(scalar @{$git->{pushes}}, 0, 'dry run pushed nothing');
};

done_testing;
