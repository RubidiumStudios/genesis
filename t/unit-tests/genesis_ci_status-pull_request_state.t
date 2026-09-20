#!/usr/bin/env perl
# Proves that the read-only report degrades where the run cannot be told
# which repository to ask GitHub about.  genesis pipeline-status has one
# refusal on this path, which is the disowned pipeline, so a repository
# that asks for pull requests and resolves no owner and repository pair
# leaves every column unread rather than ending the report at CONFIG in a
# writing run's words.
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

# The root the token rows need, which answers a pair so that the build gets
# as far as asking GitHub who the token belongs to.
{
	package Paired::Top;
	sub new { return bless {}, shift }
	sub source_control_repository { return 'owner/repo' }
}

# A client GitHub answers for without naming anybody, which client_for_run
# reads as a token answering for somebody else and refuses on.  It stands in
# for Service::Github rather than reaching the API, because what the row
# weighs is what the report does with that refusal.
{
	package Nameless::Github;
	sub new { return bless {}, shift }
	sub base_url { return 'https://api.github.test' }
	sub get_authorized_user { return undef }
}

# The scope every row here hands in, which is one environment that would
# deliver into a pull request.
sub one_env { return [{env => 'qa', branch => 'qa/bosh',
                       pr_branch => 'pr/qa/bosh'}] }

# What _pull_request_state answered, what it said on standard error, and
# whatever it raised, since a row that only counted a death could not tell a
# refusal from a die inside the read.
#
# The warning comes back as one line.  The logger wraps it and indents every
# line after the first, so a phrase a row names below falls across two of
# them and would not match the sentence anybody reads.
sub asked {
	my ($top) = @_;
	my ($github, $state_of, $raised);
	my $said = stderr_from {
		local $@;
		($github, $state_of) = eval {
			Genesis::CI::Status::_pull_request_state($top, one_env());
		};
		$raised = $@;
	};
	$said =~ s/\s+/ /g;
	return ($said, $raised, $github, $state_of);
}

subtest 'a missing owner and repository pair leaves the column unread' => sub {
	plan tests => 4;

	# Without a token the report reads nothing at all and the refusal below
	# is never reached, so the row names one to get past that arm.
	local $ENV{GITHUB_AUTH_TOKEN} = 'a-token';

	my ($said, $raised, $github, $state_of) = asked(Repoless::Top->new);

	is($raised, '', 'the report is not ended by the missing pair');
	# The sentence names the pair, because that is what an operator sets,
	# and a row that matched the consequence alone would pass on any of the
	# three reasons the closure words.
	like($said, qr/resolves no owner and repository pair.*pull request column/s,
		'and standard error says the pair is what went missing');
	is($github, undef, 'no client goes to the walk');
	is_deeply($state_of, {},
		'and no state is carried for any environment, so each one reads as '.
		'the no-token case does');
};

subtest 'a token GitHub names no owner for leaves the column unread' => sub {
	plan tests => 4;

	local $ENV{GITHUB_AUTH_TOKEN} = 'a-token';

	# The build reaches the API for one question, which is who the token
	# belongs to, and this stands in for the answer rather than asking.  An
	# endpoint that answers and names nobody is answering for somebody else,
	# which client_for_run refuses on, and this command degrades on it like
	# the other two.
	no warnings 'once';
	local *Service::Github::new = sub { return Nameless::Github->new };

	my ($said, $raised, $github, $state_of) = asked(Paired::Top->new);

	is($raised, '', 'the report is not ended by the token either');
	# What the operator has to change here is the token they set, so the
	# sentence says the token.  It goes red against a report that words
	# every refusal but the unreadable API as a settings problem.
	like($said, qr/token/,
		'and standard error says the token is what GitHub named no owner for');
	is($github, undef, 'no client goes to the walk');
	is_deeply($state_of, {},
		'and no state is carried for any environment');
};

done_testing;
