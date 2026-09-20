#!/usr/bin/env perl
# Proves the deploy's branch classification, which is the six answers
# _deploy_branch_action gives for the six states a deployment branch can be
# in, and the two orderings the pre-flight around it rests on.
#
# The classification is driven directly rather than through a spawned deploy,
# because a spawned run reaches one state per run and stops at the first
# refusal, so six states would be six deploys and the two refusals that
# cannot be reached from a clean tree would still be unread.
#
# One harness carries every state, each on its own environment's branch, and
# the refusal is captured by standing in for bail, which is how the gate rows
# in t/unit-tests/genesis_ci_preflight-deploy_gate.t read a refusal's own
# words.
#
# The warning order and the gate's place are the two things the pre-flight
# argues in a comment alone.  The order is read by standing in for the four
# warnings and calling the sub that calls them, and the gate's place is read
# off the pre-flight's own source, because a refusal that does not fire
# leaves nothing behind for a run to be asked about.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Deep;

use Genesis;
use Genesis::Exit qw/DATAERR/;

use_ok 'Genesis::Commands::Env';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# One environment per state, because each state is a fact about one branch and
# a harness stands up in the time six of them would take one each.
my @ENVS = qw/qa dev prod lab ops staging perf sandbox/;
my $h = make_harness(envs => [@ENVS], vault => 0);
my $top = top_for($h);
my $git = $h->git('a');

# in-sync: the branch is on R and copy A holds the same commit.
init_branch($h, 'qa');
refresh($h, 'a');
local_branch($h, $h->slug('qa'), at => remote_sha($h, $h->slug('qa')));

# no-local: the branch is on R and copy A has only the tracking ref.
init_branch($h, 'dev');
refresh($h, 'a');

# behind, diverged, and ahead, each through the builder that lays the
# commits the state is made of.
init_branch($h, 'prod');
diverge($h, $h->slug('prod'), local => 0);
init_branch($h, 'lab');
diverge($h, $h->slug('lab'));
init_branch($h, 'ops');
diverge($h, $h->slug('ops'), remote => 0);

# no-remote: a branch copy A holds that R has never had.
local_branch_only($h, 'staging');

# unrelated: R has the branch and copy A's shares no ancestor with it.
init_branch($h, 'perf');
refresh($h, 'a');
unrelated_branch($h, 'perf');

# action_for - what the classification answered, or what it refused with
#
# The refusal is read as bail was handed it, because the message is wrapped
# for the terminal before it is printed and a read of the printed text would
# rest on where a line break landed.  The exit code comes off the options
# hash, which is the only part of a refusal that survives being raised inside
# an eval.
sub action_for {
	my ($env_name) = @_;

	my @raised;
	my $answer;
	{
		no warnings qw/once redefine/;
		local *Genesis::Commands::Env::bail =
			sub {push @raised, [@_]; die "refused\n"};
		eval {$answer = Genesis::Commands::Env::_deploy_branch_action(
			$top, $env_name, $git); 1};
	}
	return ($answer, '', undef) unless @raised;

	my @args = @{$raised[0]};
	my $opts = ref($args[0]) eq 'HASH' ? shift(@args) : {};
	my ($format, @rest) = @args;
	return (undef, sprintf($format, @rest), $opts->{exitcode});
}

subtest 'the three states that deploy, and the one ref move among them' => sub {
	plan tests => 4;

	my ($insync) = action_for('qa');
	is($insync->{action}, 'proceed', 'a branch in step with R deploys as it stands');
	is($insync->{divergence}{state}, 'in-sync',
		'and the classification hands the divergence on');

	my ($behind) = action_for('prod');
	is($behind->{action}, 'fast-forward',
		'a branch that is only behind is moved up to R first');

	my ($nolocal) = action_for('dev');
	is($nolocal->{action}, 'proceed',
		'a branch this clone has no ref for deploys, because the switch cuts one');
};

subtest 'an environment with no branch anywhere is refused' => sub {
	plan tests => 3;

	# sandbox is declared like the rest and no branch was ever cut for it.
	my ($answer, $said, $code) = action_for('sandbox');
	is($answer, undef, 'nothing is deployed');
	is($code, DATAERR, 'the refusal exits DATAERR');
	like($said, qr/awaiting #C\{pipeline-apply\}/,
		'and it says the environment is waiting for the branch to be cut');
};

subtest 'a branch R has never had is refused' => sub {
	plan tests => 3;

	my ($answer, $said, $code) = action_for('staging');
	is($answer, undef, 'nothing is deployed');
	is($code, DATAERR, 'the refusal exits DATAERR');
	like($said, qr/legacy checkout or was created by hand/,
		'and it says where such a branch comes from');
};

subtest 'a branch sharing no ancestor with R is refused' => sub {
	plan tests => 3;

	my ($answer, $said, $code) = action_for('perf');
	is($answer, undef, 'nothing is deployed');
	is($code, DATAERR, 'the refusal exits DATAERR');
	like($said, qr/shares no ancestor/,
		'and it says the two histories are unrelated');
};

subtest 'a branch that moved on its own is refused, and told which way' => sub {
	plan tests => 4;

	# The two states share one refusal and read differently, so each is read
	# for the verb it earns and for the counts beside it.
	my (undef, $diverged, $diverged_code) = action_for('lab');
	is($diverged_code, DATAERR, 'a diverged branch exits DATAERR');
	like($diverged, qr/has diverged from .*standing 1 commit ahead of it and 1 commit behind/,
		'and the refusal counts both sides, each with its noun');

	my (undef, $ahead, $ahead_code) = action_for('ops');
	is($ahead_code, DATAERR, 'a branch merely ahead exits DATAERR too');
	like($ahead, qr/is ahead of .* by 1 commit/,
		'and the refusal says only how far ahead it stands');
};

subtest 'the pre-flight warns in the order the design gives' => sub {
	plan tests => 3;

	my @order;
	my $fake_env = mock 'Mock::DeployBranchAction::Env' => {name => 'qa'};
	my $fake_top = mock 'Mock::DeployBranchAction::Top' => {
		load_env => sub {$fake_env},
	};

	no warnings qw/once redefine/;
	local *Genesis::Commands::Env::_warn_stale_pipeline =
		sub {push @order, 'stale'; return};
	local *Genesis::Commands::Env::_warn_hold =
		sub {push @order, 'hold'; return};
	local *Genesis::Commands::Env::_warn_commits_due =
		sub {push @order, 'due'; return []};
	local *Genesis::Commands::Env::_warn_drifted =
		sub {push @order, 'drifted'; return []};

	Genesis::Commands::Env::_warn_about_the_tip($fake_top, 'qa', $git,
		bare => undef, record => {}, target => undef);
	is_deeply(\@order, [qw/stale hold due drifted/],
		'what is stale comes first, then the hold, then what is due, then the drift');

	# A run that resolved a deployed commit is not deploying the tip, so the
	# two warnings that describe the tip are the two it skips.
	@order = ();
	my $answer = Genesis::Commands::Env::_warn_about_the_tip(
		$fake_top, 'qa', $git,
		bare => undef, record => {}, target => 'abc1234');
	is_deeply(\@order, [qw/stale hold/],
		'a run reading the deployed commit still hears the two that are not about the tip');
	is_deeply($answer, {due => [], drifted => []},
		'and it is told nothing is due and nothing has drifted');
};

subtest 'the gate is the last refusal the pre-flight raises on its own' => sub {
	plan tests => 3;

	# The source is read, because a refusal that does not fire leaves nothing
	# for a run to be asked about, and what is being pinned here is where the
	# gate stands among the steps rather than what it says.
	my $body = slurp('lib/Genesis/Commands/Env.pm');
	my ($preflight) = $body =~ m/\nsub _deploy_preflight \{(.*?)\n\}\n/s;
	isnt($preflight, undef, 'the pre-flight was found to read');

	my $prior = index($preflight, '_assert_prior_env_deployed');
	my $gate  = index($preflight, 'assert_provider_gate');
	my $warn  = index($preflight, '_warn_about_the_tip');

	ok($prior > -1 && $gate > $prior,
		'the gate is asked after every refusal no acknowledgement can settle');
	ok($warn > $gate,
		'and before the warnings, so nothing of ours refuses after it');
};

done_testing;
