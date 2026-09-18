#!/usr/bin/env perl
# A run whose one branch the remote refused published nothing, so the totals
# line counts none of its commits and says nothing about changes to
# propagate, while the same run with nothing in its way counts the one commit
# it published.  An environment the run could not read keeps the outcome that
# says so, whether or not a branch was ever cut for it, and contributes
# nothing to the count either.
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

sub ghost_env_file {
	# A file every reader accepts as an environment and no run can load,
	# because the kit it names is one nothing here holds.  The row below
	# needs an environment that reaches the walk and fails inside it, and a
	# file no reader accepts would never do that.  The repository would
	# simply have no environment of that name at all.
	my ($env) = @_;
	return join("\n", '---', 'kit:', '  name:    ghost', '  version: 9.9.9',
		'  features: []', 'genesis:', "  env: $env", '  pipeline:',
		'    track_additional_files:', '    - ops/shared.yml', '');
}

subtest 'a refused branch contributes none of its commits' => sub {
	# Three assertions and one restoration.
	plan tests => 4;

	my ($h) = due_harness(envs => ['lab'], count => 1, kit => 'omega-v2.7.0');
	move_on_r_at($h, 'lab/bosh', at => 'push', nth => 1);

	my ($out, $err) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);

	like($said, qr/publish rejected/, 'the environment records the rejection');
	unlike($said, qr/Delivered 1 commit/,
		'the totals line counts no commit the remote refused');
	unlike($said, qr/No changes to propagate/,
		'and it does not read as a quiet run either');
};

subtest 'a run that published its commit counts it' => sub {
	# One assertion and one restoration.
	plan tests => 2;

	my ($h) = due_harness(envs => ['lab'], count => 1, kit => 'omega-v2.7.0');

	my ($out, $err) = run_genesis($h, 'propagate', '-y');
	like(unfolded($out, $err), qr/Delivered 1 commit/,
		'the one published commit is the one the totals line counts');
};

subtest 'a branchless environment that fails to load stays failed' => sub {
	# Four assertions and one restoration.
	plan tests => 5;

	# No branch is cut for lab on either side, so the run reads it as one
	# genesis pipeline-apply has not reached, and its file names a kit
	# nothing here holds, so the walk cannot load it either.  An environment
	# in both states at once is the one the two readings compete over, and
	# the failure is the one that has to survive, because it is the reading
	# with an error under it.  The wait for the apply would send an operator
	# to a command that loads the same file and fails on it again.
	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml']);
	fixture_vault($h);
	my $c = commit_on_control($h,
		files   => {
			'lab.yml'        => ghost_env_file('lab'),
			'ops/shared.yml' => "---\nshared: one\n",
		},
		message => 'Point lab at a kit nobody has',
		push    => 1,
	);
	fixture_applied($h, control => $c);
	refresh($h, 'a');

	my ($out, $err) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);

	like($said, qr/lab: failed/,
		'the environment the run could not read reads failed');
	unlike($said, qr/lab: held/,
		'and nothing downstream overwrites that with the wait for the apply');
	like($said, qr/error: .*could not be loaded/,
		'the load error stands under the outcome');
	unlike($said, qr/Delivered \d+ commit/,
		'and the totals line counts none of its commits');
};

done_testing;
