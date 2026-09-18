#!/usr/bin/env perl
# Proves T336: a run that opens a pull request writes the proposed record at
# <exodus_base>/proposed with its at in EXODUS_TIME_FORMAT and no timestamp in
# the path, and proves the require_pr guard is gone, because none of it is
# reachable while that guard stands.
#
# Neither row is green on arrival.  The first would catch an arm that recorded
# the environment as a path that is not built, one that delivered without
# opening a pull request, and one that wrote the pointer at a path of its own
# rather than beside the environment's other records.  The second would catch
# a colliding pull request prefix refused inside the run's own eval, where the
# named CONFIG exit becomes a bare 1 and the operator is left on a branch the
# run switched them onto.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;
use Genesis::Env;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'opening a pull request writes the proposed record' => sub {
	plan tests => 10;

	# The due commit is written through the harness rather than composed
	# here, because the run reads require_pr out of this very file and a body
	# written by hand that dropped the key would take the whole arm with it.
	my $h = ready(kit => 'omega-v2.7.0');
	$h->write_env_file('prod', params => {instances => 2});
	$h->push_from('a', $h->control);
	$h->refresh('a');

	my $due = $h->git('a')->sha($h->control);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');
	# The report is written to standard error, which is where every other
	# row in the suite reads a run's own words from.
	unlike($err, qr/not attempted/,
		'prod is no longer recorded as a path that is not built');
	like($err, qr/prod.*propagated/, 'and is delivered by pull request');

	my $env = Genesis::Env->bare('prod', top_for($h));
	is($env->proposed_record_path, $h->env_path('prod').'/proposed',
		'the record is a sibling of deployments and hold');
	unlike($env->proposed_record_path, qr/\d{8,}/,
		'no part of the path is a timestamp');

	my $rec = record_at($h, $h->env_path('prod').'/proposed');
	is($rec->{control_commit}, $due, 'the record names the control commit');
	cmp_ok($rec->{number}, '>', 0, 'and the number the API answered with');
	my $repo = top_for($h)->source_control_repository;
	like($rec->{url}, qr{^https://github\.test/\Q$repo\E/pull/\d+$},
		'and the url beside it');
	like($rec->{at}, qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [-+]\d{4}$/,
		'and at is a value in EXODUS_TIME_FORMAT');
};

subtest 'a colliding pull request prefix refuses before the session opens' => sub {
	plan tests => 6;

	my $h = ready(kit => 'omega-v2.7.0', envs => ['lab', 'pr-lab']);
	$h->set_repo_config('pipeline.source_control.pr_prefix', 'pr-');
	$h->push_from('a', $h->control);
	my $before = $h->git('a')->current_branch;

	$h->write_env_file('lab', params => {instances => 2});
	$h->push_from('a', $h->control);
	$h->refresh('a');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, Genesis::Exit::CONFIG, 'the run exits CONFIG');
	like($err, qr/pull request branch for/i,
		'naming the branch it would have used');
	like($err, qr/pr_prefix/, 'and the key to change');
	is($h->git('a')->current_branch, $before,
		'the operator is left on the branch they started from');
	is(scalar(gh_calls($h->{gh})), 0, 'and no call was made to the API');
};

# The same collision, carried only by control's own files.  The run reads the
# working tree's environment files before it opens a session, so a repository
# whose checked-out branch does not hold the colliding environment gets past
# that first reading and meets the second one, which is asked on control once
# the session has stood the run there.  That refusal is caught and re-raised
# through the run's own closure, so it is the one that quoted a message
# already wrapped and already bannered and put a second banner on top of it.
subtest 'a collision only control carries refuses with one banner' => sub {
	plan tests => 6;

	my $h = ready(kit => 'omega-v2.7.0', envs => ['lab', 'pr-lab']);
	$h->set_repo_config('pipeline.source_control.pr_prefix', 'pr-');
	$h->push_from('a', $h->control);

	# The operator's own branch, which drops the environment whose deployment
	# branch the prefix would collide with, so the pre-session reading finds
	# no collision and control's reading still does.  The branch is cut with
	# git itself rather than through the handle, because every checkout the
	# handle makes is refused outside a branch session.
	my $env_file = join('/', grep {length} $h->{root}, 'pr-lab.yml');
	run({dir => $h->a}, 'git', 'checkout', '-q', '-b', 'tidy-the-pipeline');
	run({dir => $h->a, onfailure => "Failed to remove $env_file"},
		'git', 'rm', '-q', '--', $env_file);
	run({dir => $h->a, onfailure => 'Failed to retire pr-lab'},
		'git', 'commit', '-q', '-m', 'Retire the pr-lab environment');
	$h->refresh('a');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, Genesis::Exit::CONFIG, 'the run exits CONFIG');
	like($err, qr/pull request branch for/i,
		'naming the branch it would have used');
	like($err, qr/pr_prefix/, 'and the key to change');
	unlike(unfolded($out, $err), qr/\[FATAL\][\s\S]*\[FATAL\]/,
		'with the refusal quoted once rather than bannered twice');
	is($h->git('a')->current_branch, 'tidy-the-pipeline',
		'the operator is left on the branch they started from');
};

done_testing;
