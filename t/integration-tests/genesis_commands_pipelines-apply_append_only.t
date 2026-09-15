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

# _unfolded - what a refusal said, put back on one line
#
# A refusal is wrapped to the terminal's width on its way out, so a phrase
# this file matches word for word can arrive with a newline and an indent
# somewhere in the middle of it.  The rows below read what the operator was
# told rather than where the wrap landed, so the text is collapsed before
# anything is matched against it.
sub _unfolded {
	my $said = join("\n", map {$_ // ''} @_);
	$said =~ s/\s+/ /g;
	return $said;
}

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
	my $said = _unfolded($err);

	like($said, qr/rewrite history/, 'the push is refused as a history rewrite');
	like($said, qr/qa\/bosh/, 'the refusal names the branch');
	is(ref_in($h->r, 'qa/bosh'), $standing, 'R still holds the standing tip');
};

done_testing;
