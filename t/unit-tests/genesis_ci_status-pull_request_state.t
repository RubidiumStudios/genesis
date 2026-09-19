#!/usr/bin/env perl
# Proves that the read-only report degrades where the run cannot be told
# which repository to ask GitHub about.  M17 ruling 49 gives genesis
# pipeline-status one refusal, which is the disowned pipeline, so a
# repository that asks for pull requests and resolves no owner and
# repository pair leaves every column unread rather than ending the report
# at CONFIG in a writing run's words.
#
# The row is a unit row rather than a command row because Genesis::Top
# refuses a repository like that as it resolves the source control block, so
# no command ever reaches the client with the pair missing and the pair can
# only be taken away from _pull_request_state itself.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Output;

use Genesis::CI::Status;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# A deployment root that answers no owner and repository pair, and that is
# asked for nothing else.  client_for_run reads the pair off the root and
# refuses where it is missing, and that refusal is the whole of what this
# row weighs.
{
	package Repoless::Top;
	sub new { return bless {}, shift }
	sub source_control_repository { return undef }
}

subtest 'a missing owner and repository pair leaves the column unread' => sub {
	plan tests => 4;

	# Without a token the report reads nothing at all and the refusal below
	# is never reached, so the row names one to get past that arm.
	local $ENV{GITHUB_AUTH_TOKEN} = 'a-token';

	my ($github, $state_of, $raised);
	my $said = stderr_from {
		local $@;
		($github, $state_of) = eval {
			Genesis::CI::Status::_pull_request_state(Repoless::Top->new,
				[{env => 'qa', branch => 'qa/bosh', pr_branch => 'pr/qa/bosh'}]);
		};
		$raised = $@;
	};

	is($raised, '', 'the report is not ended by the missing pair');
	like($said, qr/pull request column/,
		'and standard error says why the API was not consulted');
	is($github, undef, 'no client goes to the walk');
	is_deeply($state_of, {},
		'and no state is carried for any environment, so each one reads as '.
		'the no-token case does');
};

done_testing;
