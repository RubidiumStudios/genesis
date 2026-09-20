#!/usr/bin/env perl
# Proves the terminal half of T209, that the deploy asks before going past due
# commits, that a no exits ABORTED, and that --yes proceeds without asking.
# These are here because helper::set_stdin gives a spawned command a pipe, so
# no spawned run ever sees a controlling terminal.
#
# The holding-ancestor half of the warning is here for a different reason.  A
# deploy stands on the environment's own
# deployment branch, which mirrors that environment's hierarchy and carries no
# sibling's file, so the topology the walk reads there has no node for the
# predecessor and Genesis::CI::Compiler::ASTBuilder lays no edge to a node it
# does not have.  The walk therefore finds no ancestor at all on the deploy
# path, and no spawned deploy can produce an ancestor-uncertified hold.  The
# arm is live for a hyphen-nested environment, whose parent's file is part of
# its own hierarchy and so does travel to the branch, and it is the walk that
# decides the reason in either case.  The warning is driven here with the
# record the walk would hand it, which is what this row is about.  The task
# report carries the reach of this as a concern.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Output;

use Genesis;
use Genesis::Exit qw/ABORTED/;

use_ok 'Genesis::Commands::Env';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

my $due = [{control_commit => 'a' x 40, subject => 'a change on control'}];

subtest 'at a terminal the deploy asks before going past due commits' => sub {
	plan tests => 2;

	no warnings 'redefine';
	local *Genesis::Commands::Env::in_controlling_terminal = sub {1};

	my $result;
	set_stdin("y\n");
	my ($out, $err) = output_from {
		$result = Genesis::Commands::Env::_confirm_commits_due('qa', $due, {})
	};
	reset_stdin();

	like($out.$err, qr/Deploy qa anyway\?/, 'it asks')
		or diag("what it said:\n$out$err");
	ok($result, 'and a yes carries the deploy past it');
};

subtest 'a no exits ABORTED' => sub {
	plan tests => 2;

	no warnings 'redefine';
	local *Genesis::Commands::Env::in_controlling_terminal = sub {1};

	my @raised;
	set_stdin("n\n");
	output_from {
		no warnings qw/once redefine/;
		local *Genesis::Commands::Env::bail =
			sub {push @raised, [@_]; die "refused\n"};
		eval {Genesis::Commands::Env::_confirm_commits_due('qa', $due, {})};
	};
	reset_stdin();

	is($raised[0][0]{exitcode}, ABORTED, 'declining exits ABORTED');
	like(sprintf($raised[0][1], @{$raised[0]}[2 .. $#{$raised[0]}]),
		qr/Nothing was deployed\./, 'saying nothing was deployed');
};

subtest '--yes proceeds without asking, and no terminal proceeds too' => sub {
	plan tests => 4;

	no warnings 'redefine';

	{
		local *Genesis::Commands::Env::in_controlling_terminal = sub {1};
		my ($out, $err) = output_from {
			ok(Genesis::Commands::Env::_confirm_commits_due('qa', $due, {yes => 1}),
				'-y proceeds');
		};
		unlike($out.$err, qr/anyway\?/, 'and asks nothing');
	}

	# The other half of the same rule, and the reason the deploy warns rather
	# than refusing in a pipeline job: nobody is there to answer.  The spawned
	# form of this is the second subtest of
	# t/integration-tests/genesis_commands_env-deploy_due_commits.t.
	{
		local *Genesis::Commands::Env::in_controlling_terminal = sub {0};
		my ($out, $err) = output_from {
			ok(Genesis::Commands::Env::_confirm_commits_due('qa', $due, {}),
				'no terminal proceeds too');
		};
		unlike($out.$err, qr/anyway\?/, 'and asks nothing there either');
	}
};

subtest 'a holding ancestor is named, and nothing is said to be due' => sub {
	plan tests => 3;

	# A real environment rather than a stand-in, because the warning names it
	# and the name is what this row reads.  No vault stands up, since the
	# holding arm answers before anything is read from one.
	my $h   = make_harness(envs => ['lab', 'qa'], chained => 1, vault => 0);
	my $top = top_for($h);
	my $env = Genesis::Env->bare('qa', $top);

	# The record the walk hands over when an ancestor has certified nothing:
	# every commit that routed here is held, with the reason naming the
	# ancestor that holds it, and nothing is pending.
	my $record = {
		pending => [],
		held    => [{
			control_commit => 'b' x 40,
			subject        => 'a change on control',
			reason         => 'ancestor-uncertified',
			ancestor       => 'lab',
			ancestor_state => 'never-applied',
		}],
	};

	my $answer;
	my ($out, $err) = output_from {
		$answer = Genesis::Commands::Env::_warn_commits_due($env, $record)
	};
	my $said = unfolded($out, $err);

	like($said, qr/\blab\b/, 'the warning names the ancestor that holds it')
		or diag("what it said:\n$out$err");
	unlike($said, qr/commits? due to/,
		'and says nothing is due while the hold stands')
		or diag("what it said:\n$out$err");
	is_deeply($answer, [], 'and it answers an empty due list');
};

subtest 'a walk that failed says so rather than saying nothing is due' => sub {
	plan tests => 3;

	# The record a failed walk leaves: the reason it failed, and an empty
	# pending list, which is the shape that would otherwise read as a branch
	# with nothing waiting for it.  It is composed here rather than provoked,
	# because what this row is about is which of the two the warning says.
	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $top = top_for($h);
	my $env = Genesis::Env->bare('qa', $top);

	my $record = {
		pending => [],
		held    => [],
		error   => 'the vault at http://127.0.0.1:8201 is unreachable',
		outcome => 'failed',
	};

	my $answer;
	my ($out, $err) = output_from {
		$answer = Genesis::Commands::Env::_warn_commits_due($env, $record)
	};
	my $said = unfolded($out, $err);

	like($said, qr/Could not tell what is due to qa/,
		'it says that it could not tell')
		or diag("what it said:\n$out$err");
	like($said, qr/\Qis unreachable\E/, 'and why')
		or diag("what it said:\n$out$err");
	is_deeply($answer, [], 'and it answers an empty due list');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
