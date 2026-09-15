#!/usr/bin/env perl
# Proves T121: every update the apply makes to a deployment branch on R is
# append-only, so the previous tip is still an ancestor of the new tip after a
# second run, and Genesis refuses to push a tip that would rewrite history.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

subtest 'a second apply leaves the previous tip an ancestor' => sub {
	# Six rows, and one restoration assertion for each of the two runs.
	plan tests => 8;

	my $h = make_harness(envs => ['qa'], github => 1);

	my (undef, undef, $first) = run_genesis($h, 'pipeline-apply');
	is($first, 0, 'the first apply exits 0');
	my $before = ref_in($h->r, 'qa/bosh');
	ok($before, 'and it published the branch');

	# R loses the branch while the clone carries it on, which is the one
	# state that has the apply push a branch it has pushed before.  Without
	# it the second run finds the branch standing on the remote and pushes
	# nothing at all, and an ancestry read taken between two equal shas
	# would say nothing about whether a publish can rewrite anything.
	delete_on_r($h, 'qa/bosh');
	my $carried = local_only_commit($h, 'qa/bosh');
	# The commit checked the deployment branch out, and that branch carries
	# the init file and nothing else, so the copy goes back to control
	# before the next run.  A command run from a tree with no .genesis/config
	# in it is refused for a reason that has nothing to do with this row.
	stand_on($h, $h->control);

	my (undef, undef, $second) = run_genesis($h, 'pipeline-apply');
	is($second, 0, 'the second apply exits 0');
	my $after = ref_in($h->r, 'qa/bosh');

	isnt($after, $before, 'the second apply moved the branch on R');
	is($after, $carried, 'to the tip the clone was carrying');

	my $ok = run({dir => $h->r, passfail => 1},
		'git', 'merge-base', '--is-ancestor', $before, $after);
	ok($ok, 'the previous tip is still an ancestor of the new tip');
};

subtest 'Genesis refuses to push a tip that would rewrite the branch' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	refresh($h, 'a', 'qa/bosh');

	my $git = Service::Git->new($h->a);
	my $standing = ref_in($h->r, 'qa/bosh');

	# Rewrite the branch locally, which is what a recovery used to do.
	my $rewritten = $git->create_orphan_branch('qa/bosh-rewritten',
		files   => {init => "rewritten\n"},
		message => 'rewrite qa/bosh',
	);
	run({dir => $h->a}, 'git', 'update-ref', 'refs/heads/qa/bosh', $rewritten);

	my $err = '';
	eval {
		local $ENV{GENESIS_IGNORE_EVAL} = '';
		$git->push_append_only('qa/bosh');
		1;
	} or $err = $@;
	my $said = unfolded($err);

	like($said, qr/rewrite history/, 'the push is refused as a history rewrite');
	like($said, qr/qa\/bosh/, 'the refusal names the branch');
	is(ref_in($h->r, 'qa/bosh'), $standing, 'R still holds the standing tip');
};

done_testing;
