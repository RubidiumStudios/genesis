#!/usr/bin/env perl
# Proves T208, the warning naming both due commits and its silence when
# nothing is due; the non-terminal half of T209; T218, the proposed record read
# with no GitHub client built; and the ordering half of T215, that the
# stale-pipeline warning prints ahead of this one.
#
# The prompt's own rows are in
# t/unit-tests/genesis_commands_env-deploy_due_prompt.t, the suite being
# unable to give a spawned command a terminal to answer from.  The two rows
# about a holding ancestor are there as well, and that file says why the
# deploy path cannot reach that state at all.
#
# Every tree here is built with bosh => 1, which stands the director, the fake
# bosh, and the kit up before the seeding.  Each of these rows asserts that the
# deploy proceeded, which needs the director; and each of them asks the walk to
# route a control commit, which needs the kit on control, because the kit
# source is a kind of the propagation set and reading that set at a commit
# carrying no kit refuses by name.
#
# Every run passes --no-propagate.  The auto-cascade hands off to a child
# genesis propagate, which fails today, and a row about what the deploy said
# should not be reading the child's failure as the deploy's.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the warning names both due commits, and says nothing when none are' => sub {
	plan tests => 7;

	# due_harness seeds the environment, delivers it, certifies it, and then
	# lays two control commits that write the environment's own file, so both
	# of them route to qa and neither has reached its branch.
	my ($h, @due) = due_harness(bosh => 1);

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the deploy proceeded');
	like(unfolded($err), qr/\Q@{[substr($due[0],0,8)]}\E/,
		'it names the first due commit')
		or diag("what the deploy said:\n$err");
	like(unfolded($err), qr/\Q@{[substr($due[1],0,8)]}\E/, 'and the second');
	like(unfolded($err), qr/genesis propagate/, 'and the one remedy');

	# The second delivery carries the newer of the two commits, and a mirror
	# carries everything before it, so nothing stands between control and the
	# branch and the warning has nothing to say.
	deliver($h, 'qa', control => $due[1]);
	refresh($h, 'a', $h->control, $h->slug('qa'));
	my (undef, $err2, undef) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	# This row was green before the warning existed, nothing printing at all,
	# and it stays as the pair to the three above it: what it catches is a
	# warning that fires on every deploy, naming the branch's whole pending
	# set or an empty one, which would be right in the rows above and wrong
	# here.
	#
	# The phrase is the warning's own opening, rather than the bare word due,
	# because the commit subjects this harness lays carry that word too and a
	# looser pattern would read one of them as the warning.
	unlike(unfolded($err2 // ''), qr/commits? due to/,
		'with nothing due it prints no due-commits line')
		or diag("what the second deploy said:\n$err2");
};

subtest 'outside a terminal it warns and proceeds without asking' => sub {
	plan tests => 3;

	# No --yes here, which is the whole point: a spawned command has no
	# controlling terminal, so the confirmation returns true without asking
	# and the deploy carries on having warned.
	my ($h) = due_harness(bosh => 1);

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', 'r');

	is($exit, 0, 'it proceeds without asking');
	like(unfolded($err), qr/genesis propagate/, 'having warned first')
		or diag("what the deploy said:\n$err");
};

subtest 'a proposed record is read with no GitHub client built' => sub {
	plan tests => 4;

	my ($h, @due) = due_harness(bosh => 1);
	my $gh = github_double($h);
	# fixture_proposed takes the commit as control and the number as pr,
	# which are the names the GitHub double and every row that opens a pull
	# request use.
	fixture_proposed($h, 'qa',
		control => $due[1], pr => 41,
		url => 'https://github.com/owner/repo/pull/41',
		at => '2026-09-12 09:14:02 -0400');

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the deploy proceeded');
	like(unfolded($err),
		qr/PR #41 proposes control\@\Q@{[substr($due[1],0,8)]}\E, not yet merged/,
		'the warning names the pull request and what it proposes')
		or diag("what the deploy said:\n$err");
	# What the warning must not have done is ask GitHub about the pull
	# request, and that is what this reads.  The run does make one call, which
	# is the identity probe the deployment audit makes to record which GitHub
	# user deployed; it happens after the deploy has finished, it asks about
	# the operator rather than about a pull request, and it is not the
	# warning's.  A row demanding an empty log would be red for it and would
	# stay red however the warning was written.
	my @asked = grep {($_->{url} // '') =~ m{/pulls\b}} gh_calls($gh);
	is_deeply(\@asked, [], 'and nothing asked GitHub about the pull request')
		or diag(explain \@asked);
};

subtest 'the stale-pipeline warning prints ahead of this one' => sub {
	plan tests => 3;

	# This row sits here because it reads one warning against the other, and
	# nothing printed a due-commits line before.
	#
	# One tree answers both.  Each commit due_harness lays writes the
	# environment's own file, which is a path that defines the pipeline,
	# so control has moved away from the commit the pipeline was applied from
	# and the staleness query answers as well.
	my ($h) = due_harness(bosh => 1);

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the deploy proceeded past both warnings');

	my $said  = unfolded($err);
	my $stale = index($said, 'The pipeline is stale.');
	my $due   = $said =~ /commits? due to/ ? $-[0] : -1;
	ok($stale >= 0 && $due >= 0 && $stale < $due,
		'what is stale is said before what is due')
		or diag("stale at $stale, due at $due, in:\n$err");
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
