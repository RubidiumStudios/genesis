#!/usr/bin/env perl
# Proves T272 and T332: a new environment's first pull request carries
# everything due from E onward as one aggregate whose first delivered commit
# deletes init, and an environment with no branch anywhere is held awaiting
# pipeline-apply with nothing created for it.  The last row is the one that
# says where that phrase comes from, because both halves above read the same
# in a tree that composed it in the command instead.
#
# Every due commit below is laid through the environment file at the
# deployment root, because a path under an environment's own name is in no
# propagation set and a commit written there would route nowhere and leave
# nothing due.
#
# The branchless environment is one pipeline-apply never ran for rather than
# one whose branch a row took away afterwards.  A refresh never prunes, so a
# deleted branch leaves its remote-tracking ref behind and the pre-flight
# still reads a branch there, which is a different state with a different
# answer.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::CI::Report ();

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the first pull request is the seed' => sub {
	plan tests => 7;

	my $h   = make_harness(envs => ['qa'], mode => 'pr', github => 1,
		kit => 'omega-v2.7.0');
	my $git = $h->git('a');
	$h->ready_envs;
	gh_protection($h->{gh});

	# E is the control commit that introduces prod, and pipeline-apply has
	# cut its init branch.
	my $path = write_env_file($h, 'prod', params => {instances => 1},
		commit => 0);
	my $e = commit_on_control($h,
		files   => {$path => slurp($h->a."/$path")},
		message => 'Add the prod environment', push => 1);
	init_branch($h, 'prod');
	fixture_pipeline_record($h, 'prod', dependencies => ['qa']);
	fixture_applied($h, control => $e);

	$path = write_env_file($h, 'prod', params => {instances => 2},
		commit => 0);
	my $after = commit_on_control($h,
		files   => {$path => slurp($h->a."/$path")},
		message => 'Raise the prod instance count', push => 1);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');

	my $pr = $h->pr_branch('prod');
	refresh($h, 'a', $pr);
	is(harness_marker($h, "origin/$pr"), $after,
		'the aggregate ends at the newest due commit');

	my ($body) = run({dir => $h->a}, 'git', 'log', '-1', '--format=%b',
		"origin/$pr");
	like($body, qr/Carries 2 control commits:/,
		'and carries everything due from E onward');

	my @files = $git->ls_tree("origin/$pr", '.');
	ok(!(grep {$_ eq 'init'} @files), 'the first delivered commit deleted init');
	ok((grep {$_ eq $path} @files),
		'and a reviewer sees the exact file set prod deploys from');
	assert_snapshot_invariant($h, 'prod', commit => "origin/$pr",
		name => 'the seed is a mirror of the set at the newest commit');
};

subtest 'an environment with no branch anywhere is held' => sub {
	plan tests => 7;

	my $h = make_harness(envs => ['qa', 'prod'], mode => 'pr', github => 1,
		kit => 'omega-v2.7.0');
	# prod's file is on control from the seeding commit and the pipeline
	# knows it, but pipeline-apply has never run for it, so nothing ever cut
	# it a deployment branch on either side.
	$h->ready_envs(envs => ['qa']);
	fixture_pipeline_record($h, 'prod');
	gh_protection($h->{gh});

	my $qa   = write_env_file($h, 'qa',   params => {instances => 2},
		commit => 0);
	my $prod = write_env_file($h, 'prod', params => {instances => 2},
		commit => 0);
	commit_on_control($h,
		files => {
			$qa   => slurp($h->a."/$qa"),
			$prod => slurp($h->a."/$prod"),
		},
		message => 'Raise the cf instance count', push => 1);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the run succeeded');

	like($said, qr/prod: held, awaiting pipeline-apply/,
		'prod is held, awaiting pipeline-apply');
	like($said, qr/qa: propagated/, 'while qa is delivered as usual');

	refresh($h, 'a');
	ok(!remote_sha($h, $h->slug('prod')),
		'no deployment branch was created for prod');
	ok(!remote_sha($h, $h->pr_branch('prod')),
		'and no pull request branch either');

	my @created = grep {($_->{method} // '') eq 'POST'} gh_calls($h->{gh});
	is(scalar(grep {($_->{body} // '') =~ /prod/} @created), 0,
		'and no pull request was opened for it');
};

subtest 'the phrase is composed where every other qualifier is' => sub {
	plan tests => 2;

	# The walk reads nothing at all about an environment it found no branch
	# for, so its certified state is never filled in, and that absence is
	# what the qualifier answers on.
	is(Genesis::CI::Report::held_qualifier({env => 'prod'}),
		Genesis::CI::Report::AWAITING_APPLY,
		'a record the walk never read answers awaiting pipeline-apply');

	# The comments come out first, because a comment that merely names the
	# constant says nothing about what the command writes.
	my $src = join("\n", map {strip_comment($_)} split(/\n/,
		slurp('lib/Genesis/Commands/Pipelines.pm'), -1));
	unlike($src, qr/AWAITING_APPLY/,
		'and the command that meets the state spells it nowhere');
};

done_testing;
