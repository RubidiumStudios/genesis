#!/usr/bin/env perl
# Proves T449: a deployment audit names who ran the deploy even where a
# pipeline task runs it, with no login session for `who -m` to report and no
# USER or LOGNAME in its environment.  The audit refuses a record without
# user.shell, so a deploy there wrote no audit and no deployed commit.
#
# What the rows catch: the fallback stopping at USER, which is what a
# Concourse task container lacks; and a pipeline run recorded as if a person
# named after the container's account had deployed.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis::Env::DeploymentManager;

my $account = scalar(getpwuid($<));

# Whatever `who -mH` answers, as the one table it would print.
sub with_who {
	my ($answer, $fn) = @_;
	no warnings 'redefine';
	local *Genesis::Env::DeploymentManager::run = sub {
		return $answer if grep {defined && $_ eq 'who'} @_;
		die "unexpected run(@_)\n";
	};
	return $fn->();
}

subtest 'a pipeline task, with no login and no USER' => sub {
	local $ENV{GENESIS_PIPELINE_TASK} = 1;
	local $ENV{USER};    delete $ENV{USER};
	local $ENV{LOGNAME}; delete $ENV{LOGNAME};
	my $user = with_who("NAME     LINE         TIME             COMMENT\n",
		sub {Genesis::Env::DeploymentManager::_shell_user()});
	is($user, "$account (pipeline task)", 'the process account, marked as a pipeline run');
};

subtest 'an operator with USER and no login session' => sub {
	local $ENV{GENESIS_PIPELINE_TASK}; delete $ENV{GENESIS_PIPELINE_TASK};
	local $ENV{USER} = 'operator';
	my $user = with_who('', sub {Genesis::Env::DeploymentManager::_shell_user()});
	is($user, 'operator', 'USER, as before');
};

subtest 'a login session' => sub {
	local $ENV{GENESIS_PIPELINE_TASK}; delete $ENV{GENESIS_PIPELINE_TASK};
	local $ENV{USER} = 'not-this-one';
	my $user = with_who(
		"NAME     LINE         TIME             COMMENT\n".
		"alice    ttys001      2026-10-29 10:00 (10.0.0.5)\n",
		sub {Genesis::Env::DeploymentManager::_shell_user()});
	is($user, 'alice (10.0.0.5)', "the session's user and where it came from, ahead of USER");
};

done_testing;
