#!/usr/bin/env perl
# Proves T286 and T289: the held qualifiers in the exact form the propagation
# run's report prints them, a standing hold answering ahead of a never-applied
# environment, and the overlap reason carrying the ancestor's own state in the
# same words genesis propagate --dry-run prints.
#
# The qualifier is what the operator reads to tell a hold that resolves itself
# from one that waits for a person, which is the whole reason the row shows it
# rather than the word blocked.  It is rendered by Genesis::CI::Report, which
# owns every word an operator reads about an outcome, so the rows below run
# the same fixture through both commands and assert one wording.
#
# Three of the four qualifiers are asserted here.  The fourth, awaiting merge
# with the pull request number, is written by the pull request mode work that
# fills the walk record's pr field, and nothing in this tree fills it yet, so
# the row for it belongs here once that lands.
#
# Which assertions discriminate and which guard is said beside each.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

subtest "the held qualifiers print in the run's words" => sub {
	# Five assertions and one restoration.
	plan tests => 6;

	my $h = make_harness(envs => ['lab', 'prod', 'sandbox', 'dev'],
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);

	# prod follows lab, so an ancestor holds its commit and the qualifier
	# names that ancestor.  The tracked list is written again because the
	# file is only in an environment's propagation set where that
	# environment declares it.
	#
	# sandbox keeps the file the harness seeded, which declares the same
	# tracked list and names no predecessor, so the hold somebody set is the
	# only thing holding its commit.  That is the state where the hold's own
	# text could reach the row twice, and the row below refuses it.
	write_env_file($h, 'prod', pipeline => {
		prior_env              => 'lab',
		track_additional_files => ['ops/shared.yml'],
	});
	init_branch($h, $_) for qw/lab prod sandbox dev/;

	my $c1 = commit_on_control($h,
		files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, $_, control => $c1) for qw/lab prod sandbox/;
	certify($h, $_, control_commit => $c1) for qw/lab prod sandbox/;

	my $c2 = commit_on_control($h,
		files => {'ops/shared.yml' => "---\ntwo\n"}, push => 1);
	deliver($h, 'lab', control => $c2);

	# prod waits for lab to deploy, sandbox waits for a hold somebody set,
	# and dev has deployed once without a control commit, which is the
	# environment the pipeline has never been applied to.
	fixture_hold($h, 'sandbox', reason => 'vsphere maintenance');
	certify($h, 'dev', control_commit => '');
	fixture_applied($h, control => $c2);
	fixture_pipeline_record($h, $_) for qw/lab prod sandbox dev/;
	refresh($h, 'a');

	my ($out, undef, $exit) = run_genesis($h, 'pipeline-status');
	# A guard.  The command has exited zero over a held environment since the
	# read model landed, so nothing in the tree can fail this today.  It
	# stands because every assertion below reads a rendered row, and a
	# command that had come to refuse a hold would leave them all matching
	# against an empty string and saying so for the wrong reason.
	is($exit, 0, 'the command exits zero');

	like(env_line($out, 'prod'),
		qr/held, awaiting deployment \(lab at control\@[0-9a-f]{7}\)/,
		'prod shows awaiting deployment with the environment and the commit');
	like(env_line($out, 'sandbox'),
		qr/held, needs clearing \(vsphere maintenance\)/,
		'sandbox shows needs clearing with the reason somebody wrote');
	# The hold stamps its own text onto every commit it takes, so a phrase
	# that rendered the per-commit reason beside the qualifier would print
	# what somebody wrote on the record twice in one row.  The environment
	# waits for one thing, and the row says it once.
	unlike(env_line($out, 'sandbox'),
		qr/\(vsphere maintenance\).*\(vsphere maintenance\)/,
		'and says it once rather than beside every commit the hold took');
	like(env_line($out, 'dev'), qr/held, awaiting pipeline-apply/,
		'dev shows awaiting pipeline-apply');
};

subtest 'a standing hold answers ahead of a never-applied environment' => sub {
	# Two assertions and one restoration for the status, and one assertion
	# and one restoration for the run.
	plan tests => 5;

	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');
	my $c1 = commit_on_control($h,
		files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, 'lab', control => $c1);

	# Deployed once with no control commit, which reads as never applied,
	# and holding a hold somebody set on top of it.
	certify($h, 'lab', control_commit => '');
	fixture_hold($h, 'lab', reason => 'waiting on the network change');
	fixture_applied($h, control => $c1);
	fixture_pipeline_record($h, 'lab');
	refresh($h, 'a');

	my ($out) = run_genesis($h, 'pipeline-status');
	my $line = env_line($out, 'lab');
	like($line, qr/held, needs clearing \(waiting on the network change\)/,
		'the hold somebody set is what the row says the environment waits for');
	unlike($line, qr/awaiting pipeline-apply/,
		'the never-applied phrase gives way to it');

	my (undef, $err) = run_genesis($h, 'propagate', '--dry-run', '-y');
	like($err, qr/held, needs clearing \(waiting on the network change\)/,
		'the run reads the same order through the same renderer');
};

subtest "the overlap reason carries the ancestor's state" => sub {
	# One assertion and one restoration for each of the four commands.
	plan tests => 8;

	# The manual harness is run out before the automated one is built,
	# because two harnesses share one vault mount and one set of environment
	# names, so the second one to attach owns every record the first wrote.
	my $h = make_harness(envs => ['lab', 'qa'], provider => 'manual',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	write_env_file($h, 'qa', pipeline => {
		prior_env              => 'lab',
		track_additional_files => ['ops/shared.yml'],
	});
	init_branch($h, $_) for qw/lab qa/;
	my $c1 = commit_on_control($h,
		files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, $_, control => $c1) for qw/lab qa/;
	certify($h, $_, control_commit => $c1) for qw/lab qa/;
	my $c2 = commit_on_control($h,
		files => {'ops/shared.yml' => "---\ntwo\n"}, push => 1);
	deliver($h, 'lab', control => $c2);
	fixture_applied($h, control => $c2);
	fixture_pipeline_record($h, $_) for qw/lab qa/;
	refresh($h, 'a');

	my ($status) = run_genesis($h, 'pipeline-status');
	like(env_line($status, 'qa'),
		qr/held by lab \(ops\/shared\.yml\), lab awaiting deployment/,
		'the routing reason names the ancestor, the files, and its state');

	# A guard.  The run has printed this clause since the walk learned to
	# annotate the overlap, so nothing in the tree can fail it today.  It
	# stands because the claim the row above makes is that the two commands
	# print one wording, and half of a comparison proves nothing.
	my (undef, $dry) = run_genesis($h, 'propagate', '--dry-run', '-y');
	like($dry, qr/held by .?lab.? \(.?ops\/shared\.yml.?\), lab awaiting deployment/,
		'the dry run prints the same words');

	# Under an automated provider an ancestor whose deploy job waits for a
	# person awaits its trigger rather than a deployment.
	my $g = make_harness(envs => ['lab', 'qa'], provider => 'concourse',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($g);
	write_env_file($g, 'lab', pipeline => {
		manual                 => 'true',
		track_additional_files => ['ops/shared.yml'],
	});
	write_env_file($g, 'qa', pipeline => {
		prior_env              => 'lab',
		track_additional_files => ['ops/shared.yml'],
	});
	init_branch($g, $_) for qw/lab qa/;
	my $d1 = commit_on_control($g,
		files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($g, $_, control => $d1) for qw/lab qa/;
	certify($g, $_, control_commit => $d1) for qw/lab qa/;
	my $d2 = commit_on_control($g,
		files => {'ops/shared.yml' => "---\ntwo\n"}, push => 1);
	deliver($g, 'lab', control => $d2);
	fixture_applied($g, control => $d2, provider => 'concourse');
	fixture_pipeline_record($g, $_) for qw/lab qa/;
	refresh($g, 'a');

	my ($auto) = run_genesis($g, 'pipeline-status');
	like(env_line($auto, 'qa'),
		qr/held by lab \(ops\/shared\.yml\), lab awaiting its trigger/,
		'an automated provider with a manual ancestor awaits its trigger');

	# A guard for the same reason as the dry run above.  The run reaches the
	# walk as the pipeline's own job does, because the gate in front of a
	# hand run under an automated provider wants a controlling terminal and a
	# spawned command has none.
	my (undef, $auto_dry) = run_genesis($g, {pipeline_task => 'propagate'},
		'propagate', '--dry-run');
	like($auto_dry, qr/lab awaiting its trigger/,
		'the dry run prints the same clause');
};

done_testing;
