#!/usr/bin/env perl
# Proves T227: a kit hook that writes into the repository during a deploy BOSH
# completes aborts at finish naming the files, restores the branch, reports
# the deploy as succeeded, exits SOFTWARE, and leaves an untracked scratch
# file alone.
#
# The kit's post-deploy hook is the discriminator, because it is the last
# thing a kit runs and Genesis runs it inside _post_deploy before the
# session's assertion.  fixture_bosh installs the kit along with the director,
# and the hooks it is given are merged over the blueprint it writes itself, so
# the deploy still renders a manifest and still reaches its end.
#
# Neither run passes --no-propagate, which every other deploy file does pass,
# because the auto-cascade is the subject of the second row.  The abort leaves
# before the cascade, so the child that M15 owns is never spawned, and a run
# that had opted out of the cascade could not tell that apart from a cascade
# that was never reached.
#
# Two rows of the first subtest arrive green, and they are the third, which
# reads the modified file's name out of the abort, and the fourth, which
# reads the modification back as discarded.  The gate already called finish
# after the command returned and finish already aborted on a dirty tree, so
# the baseline did name the file and did discard it.  What it did not do is
# exit anything but 1, and it ran after the cascade had already handed off,
# which is what the first subtest's first row and the second subtest's third
# row drive.  Those are counted as the test output numbers them, where the
# restoration assertion run_genesis makes is the row that comes first.
#
# The two green rows stay as guards: the third catches an abort that discards
# the files without saying which, leaving an operator with no idea what was
# thrown away, and the fourth catches an abort that names them and keeps
# them, which is the warning this task replaced.
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

# The hook appends to the environment's own file, which the harness picks, so
# this file and the session files edit the same tracked path.  It is appended
# to rather than replaced, because a file the deploy has already read is one
# the abort has to be able to hand back whole.
sub writes_into_the_repository {
	my ($h) = @_;
	my $file = edited_file($h, 'qa');
	fixture_bosh($h, hooks => {
		'post-deploy' =>
			"echo '# written by the kit' >> \"\$GENESIS_ROOT/$file\"\n",
	});
	return $file;
}

subtest 'a kit hook that writes into the repository aborts at finish' => sub {
	plan tests => 7;

	my $h    = seeded_harness();
	my $file = writes_into_the_repository($h);
	stand_on($h, $h->control);

	mkfile_or_fail($h->a.'/scratch.txt', "notes to self\n");
	my $w = snapshot_w($h);

	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '-y', 'a reason');

	is($exit, Genesis::Exit::SOFTWARE, 'it exits SOFTWARE')
		or diag("what the deploy said:\n$err");
	like($out.$err, qr/deployed/i, 'and reports the deploy as succeeded');
	like(unfolded($err), qr{\Q$file\E}, 'the abort names the modified file');

	my ($status) = run({dir => $h->a}, 'git', 'status', '--porcelain', '--', $file);
	is($status // '', '', 'and the modification was discarded');

	ok(-e $h->a.'/scratch.txt', 'the untracked scratch file survives');
	is(slurp($h->a.'/scratch.txt'), "notes to self\n", 'untouched');

	assert_w_restored($w, 'the branch came back');
};

subtest 'the exodus record stands and the child is withheld' => sub {
	plan tests => 3;

	my $h = seeded_harness();
	writes_into_the_repository($h);
	stand_on($h, $h->control);

	# Nothing is left anywhere else, so this run lets run_genesis assert the
	# restoration and that is the third row of the plan.
	my (undef, $err, undef) = run_genesis($h, 'qa', 'deploy', '-y', 'a reason');

	ok(newest_record($h, $h->env_path('qa').'/deployments'),
		'the record was written before finish ran')
		or diag("what the deploy said:\n$err");
	unlike($err // '', qr/Propagating from/,
		'and the propagate child was withheld')
		or diag("what the deploy said:\n$err");
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
