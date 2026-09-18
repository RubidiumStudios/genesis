#!/usr/bin/env perl
# Proves T210, that a successful deploy moves L on no branch, makes no commit
# and no push, and still writes the exodus record; T238, which is an absence
# guard now that the writer it reproduced is gone; and T228, the sweep of the
# retired routing sense of "entry point" from the files this step touches.
#
# T210 and T238 arrived a task late.  Two walls stood in front of them: the
# deploy switched to a branch named for the environment alone while every
# branch the harness builds is <env>/<type>, which git will not let stand
# beside it, and no deploy in this suite reached its end, because the harness
# stood up no BOSH for one to reach.  The task that declares the deploy's
# branch class removes both.
#
# Both deploys run with --no-propagate.  The auto-cascade hands off to a
# child genesis propagate, which is a command that writes to the deployment
# branches on purpose and which M15 owns, so a row about what the deploy
# itself writes says so rather than reading the child's work as the deploy's.
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

subtest 'a successful deploy writes no git and writes its record' => sub {
	# Four assertions, and the fifth row is the one run_genesis adds for
	# itself when it asserts the restoration.
	plan tests => 5;

	my $h = seeded_harness();
	fixture_bosh($h);
	# The step log is armed and nothing is planned to fail.  Only fault_git
	# writes the variable the child logs through, so a row that reads the
	# log without calling it first reads an empty list and its assertion
	# passes against a deploy that committed and pushed.
	fault_git($h);

	my $before = refs_in($h->a);

	my ($out, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'a reason');
	is($exit, 0, 'the deploy succeeded');

	is_deeply(refs_in($h->a), $before, 'L moved on no branch in copy A');

	my @writes = grep {$_->[0] =~ /^(commit|push|add|rm|checkout_file)$/}
		step_log($h->git('a'));
	is_deeply(\@writes, [], 'the run made no commit, no push, and no file write');

	ok(newest_record($h, $h->env_path('qa').'/deployments'),
		'the exodus deployment record was written under the exodus store');
};

subtest 'no deploy path writes a file into the propagation set' => sub {
	# An absence guard.  It catches a step that puts a propagation write
	# back on the deploy path, which is what overwrote an operator's
	# uncommitted edit under -F before M8 withdrew it.  The edit itself is
	# no longer the way to read that, because the session refuses a tracked
	# modification before the deploy runs at all, so the row watches the
	# files a clean deploy leaves behind instead.  A deploy that copied the
	# predecessor's state onto the branch would change one of them.
	#
	# Four assertions, and the fifth is run_genesis's own restoration row.
	plan tests => 5;

	my $h = seeded_harness();
	fixture_bosh($h);
	stand_on($h, $h->slug('qa'));

	my @set = propagation_set($h, 'qa');
	my %before = map {($_ => slurp($h->a.'/'.$_))} grep {-f $h->a.'/'.$_} @set;
	ok(scalar(keys %before), 'the branch carries a propagation set to watch');

	my ($out, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-F', '-y', 'a reason');

	is($exit, 0, 'the deploy succeeded');
	my %after = map {($_ => slurp($h->a.'/'.$_))} grep {-f $h->a.'/'.$_} @set;
	is_deeply(\%after, \%before, 'every file in the set survives untouched');
	my ($staged) = run({dir => $h->a}, 'git', 'diff', '--name-only', '--cached');
	is($staged // '', '', 'nothing was staged');
};

subtest 'the retired routing sense of entry point is gone' => sub {
	plan tests => 1;

	# The paths are read under the checkout root and reported relative to
	# it, because a row that ran before this one may have left the process
	# standing somewhere else and the name a reader needs is the short one.
	my @files = qw(
		lib/Genesis/Commands/Env.pm
		lib/Genesis/Commands/Env.pod
		lib/Genesis/Env.pm
		lib/Genesis/Env.pod
	);
	my @hits;
	for my $file (@files) {
		my @lines = split(/\n/, slurp("$helper::TOPDIR/$file"));
		for my $i (0 .. $#lines) {
			push @hits, sprintf('%s:%d', $file, $i + 1)
				if $lines[$i] =~ /entry[- ]point/i;
		}
	}
	is_deeply(\@hits, [], 'no file this step touches carries the retired term');
};

done_testing;
