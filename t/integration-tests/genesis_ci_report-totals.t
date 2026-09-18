#!/usr/bin/env perl
# A run whose one branch the remote refused published nothing, so the totals
# line counts none of its commits and says nothing about changes to
# propagate, while the same run with nothing in its way counts the one commit
# it published.  A preview counts what it would have delivered, off the word
# its own report wrote.  An environment the run could not read keeps the
# outcome that says so, whether or not a branch was ever cut for it, and
# contributes nothing to the count either.
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
	# Four assertions and one restoration.
	plan tests => 5;

	my ($h) = due_harness(envs => ['lab'], count => 1, kit => 'omega-v2.7.0');
	move_on_r_at($h, 'lab/bosh', at => 'push', nth => 1);

	my ($out, $err) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);

	like($said, qr/publish rejected/, 'the environment records the rejection');
	unlike($said, qr/Delivered 1 commit/,
		'the totals line counts no commit the remote refused');
	unlike($said, qr/No changes to propagate/,
		'and it does not read as a quiet run either');
	# The commit axis under a refused environment, read off the report's own
	# lines rather than the unfolded text, because the word sits at the end
	# of one line and the unfolded form runs the lines together.  The publish
	# writes delivered onto the commits of an environment the remote took and
	# leaves a refused environment's alone, so a commit line here calling one
	# delivered is the totals line's own contradiction one axis down.
	unlike($err, qr/^\s*control\@[0-9a-f]{7}.*\bdelivered\b/m,
		'and no commit line under it calls a refused commit delivered');
};

subtest 'a run that published its commit counts it' => sub {
	# One assertion and one restoration.
	plan tests => 2;

	my ($h) = due_harness(envs => ['lab'], count => 1, kit => 'omega-v2.7.0');

	my ($out, $err) = run_genesis($h, 'propagate', '-y');
	like(unfolded($out, $err), qr/Delivered 1 commit/,
		'the one published commit is the one the totals line counts');
};

subtest 'a preview counts the commits it would deliver' => sub {
	# One assertion and one restoration.
	plan tests => 2;

	# A preview publishes nothing and settles no environment's outcome the
	# way a run does, so the count it ends on cannot be read off the word the
	# publish writes.  The report writes its own word first, and this is the
	# row that says the count and the report read the same record.
	my ($h) = due_harness(envs => ['lab'], count => 1, kit => 'omega-v2.7.0');

	my ($out, $err) = run_genesis($h, 'propagate', '--dry-run', '-y');
	like(unfolded($out, $err), qr/Would deliver 1 commit/,
		'the preview ends on the count of what it would have delivered');
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

	# The first two of these four are the row's own, and they were red
	# before the run read the error ahead of the missing branch.  The last
	# two arrived green and stand as guards.  The error line printed under
	# the bare word held as well, so the third says the error survives the
	# reordering rather than that the reordering put it there.  The fourth
	# was true because an environment that fails to load has nothing
	# pending to count, and it says the count stays honest about a row whose
	# outcome no longer passes through the branchless block.
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
