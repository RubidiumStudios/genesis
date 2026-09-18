#!/usr/bin/env perl
# Proves T221, the control-nowhere refusal at CONFIG, which arrives green and
# guards the refusal require_control already makes; T219, the disowned
# pipeline's local warning, which -y does not change; and T220, the same state
# inside a job, which errors before BOSH at CONFIG.
#
# Every message is read through unfolded, because Genesis wraps what it says
# to the terminal width on its way out and a phrase a row looks for can
# arrive with a newline and an indent in the middle of it.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'control existing nowhere refuses the deploy' => sub {
	# Green on arrival.  It catches a deploy that stops calling
	# require_control, or one that asks the same question in words of its
	# own, which would leave one state with two refusals.
	plan tests => 6;

	my $h = seeded_harness(applied => 0);
	# Control has to be gone from R, from the local ref, and from the
	# remote-tracking ref, which is what unset_control takes away and what
	# the three together mean by nowhere: the refresh never prunes, so a
	# surviving tracking ref writes the local branch back and the state the
	# row came to build is undone before the command reads it.  It parks
	# both copies on a branch cut from where they stood, so copy A still
	# carries the environment file the command resolves its argument from.
	unset_control($h);

	my ($out, $err, $exit) = run_genesis($h, 'qa', 'deploy', '-y', 'a reason');
	my $said = unfolded($err);

	is($exit, Genesis::Exit::CONFIG, 'it exits CONFIG');
	like($said, qr/Refusing to deploy\./, 'it says refusing to deploy');
	like($said, qr/exists neither on \S+ nor locally/, 'it says control is nowhere');
	like($said, qr/\Q@{[$h->control]}\E/, 'it names the configured branch');
	like($said, qr/Nothing was deployed\./, 'it says nothing was deployed');
};

subtest 'a disowned pipeline warns locally and deploys anyway' => sub {
	plan tests => 10;

	for my $argv (['-y'], []) {
		my $h = seeded_harness(applied => 0);
		my $applied = $h->git('a')->sha($h->control);
		fixture_applied($h, control => $applied, at => '2026-09-12 14:02:11 -0400');
		# The deploy has to reach its end for the warning to have been a
		# warning rather than a refusal, so it needs a director, a bosh, and
		# a kit whose blueprint writes a manifest.  It is called before the
		# configuration is disowned, because it catches copy A's deployment
		# branch up to what R carries and that read is the pipeline's.
		fixture_bosh($h);
		# .genesis/config is YAML and the deploy reads it off a commit, so
		# the key is written through Genesis::Config and committed rather
		# than appended in git-config's own syntax into an untracked edit.
		set_repo_config($h, 'pipeline.enabled', 0);

		my ($out, $err, $exit) = run_genesis($h,
			'qa', 'deploy', @$argv, 'a reason');
		my $said = unfolded($err);

		is($exit, 0, 'the deploy went ahead');
		# The patterns carry no delimiter around a name Genesis marks up
		# with #C{}, because NOCOLOR renders the markup away and a pattern
		# that expected the colour would be reading the escape rather than
		# the sentence.
		like($said, qr/pipeline is disabled in \.genesis\/config/,
			'the warning names the configuration');
		like($said, qr/applied it from control\@\Q@{[substr($applied,0,8)]}\E/,
			'and the applied record with its commit');
		like($said,
			qr/Set pipeline\.enabled: true again, or tear the pipeline down by hand/,
			'and gives the two remedies');
	}
};

subtest 'a disowned pipeline inside a job errors before BOSH' => sub {
	plan tests => 6;

	my $h = seeded_harness(applied => 0);
	my $applied = $h->git('a')->sha($h->control);
	fixture_applied($h, control => $applied);
	# The step log is armed and nothing is planned to fail.  Only fault_git
	# writes the variable the child logs through, so a row that reads the
	# log without calling it first reads an empty list and its assertion
	# passes against a deploy that switched.
	fault_git($h);
	set_repo_config($h, 'pipeline.enabled', 0);

	my ($out, $err, $exit) = run_genesis($h,
		{pipeline_task => 'deploy-qa'}, 'qa', 'deploy', '-y', 'a reason');
	my $said = unfolded($err);

	is($exit, Genesis::Exit::CONFIG, 'it exits CONFIG');
	like($said, qr/GENESIS_PIPELINE_TASK is set/, 'it names the task variable');
	like($said, qr/A job never deploys what its own configuration disowns\./,
		'it gives the reason');
	like($said, qr/Nothing was deployed\./, 'it says nothing was deployed');
	is_deeply([grep {$_->[0] eq 'checkout'} step_log($h->git('a'))], [],
		'it refused before it switched, so before it touched BOSH');
};

done_testing;
