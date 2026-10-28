#!/usr/bin/env perl
# Proves T428: a branch named for the environment alone, the per-environment
# naming before D66, collides with the <env>/<type> branch the apply would
# create, since git cannot hold both X and X/<type>.  The dry run and the
# writing run both refuse before anything is written, naming the branch in
# the way and how to rename it or delete it.  The dry run once said "would
# create" for a branch git could not create, and the writing run died on
# git's own "cannot lock ref".
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/run/;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# A qa branch from the per-environment naming, here and on the remote.
sub collided {
	my (%opts) = @_;
	my $h  = make_harness(envs => ['qa'], provider => 'manual', github => 1);
	my $gh = github_double($h, admin => 1);
	push_from($h, 'a', $h->control);
	run({dir => $h->a, onfailure => 'cut the old branch'}, 'git', 'branch', 'qa', $h->control);
	run({dir => $h->a, onfailure => 'push the old branch'}, 'git', 'push', '-q', 'origin', 'qa')
		unless $opts{local_only};
	return ($h, $gh);
}

for my $mode (['the dry run', '--dry-run'], ['the writing run']) {
	my ($label, @flag) = @$mode;
	subtest "$label refuses, naming the branch in the way" => sub {
		# Six rows, and the run's restoration assertion.
		plan tests => 7;

		my ($h, $gh) = collided();
		my (undef, $err, $exit) = run_genesis($h, 'pipeline-apply', @flag);
		my $said = unfolded($err);

		is($exit, Genesis::Exit::CONFIG, 'it refuses at CONFIG');
		like($said, qr{\Qqa/bosh\E.*\bqa\b}s, 'naming the branch it would create and the one in the way');
		# Deleting comes first: a per-environment branch may carry several
		# deployment types' commits, which no <env>/<type> branch should
		# inherit.  Renaming suits only one that carried a single type.
		like($said, qr{git branch -D qa.*git push origin :qa}s, 'how to delete it, here and on the remote');
		like($said, qr{git branch -m qa qa/bosh}, 'how to rename it instead');
		like($said, qr{only ever carried}i, 'and when renaming is right');
		is_deeply(branches_on_r($h), [$h->control, 'qa'], 'and nothing was created');
	};
}

subtest 'a colliding branch held only here is found too' => sub {
	# Two rows, and the run's restoration assertion.
	plan tests => 3;

	my ($h) = collided(local_only => 1);
	my (undef, $err, $exit) = run_genesis($h, 'pipeline-apply', '--dry-run');
	is($exit, Genesis::Exit::CONFIG, 'it refuses at CONFIG');
	like(unfolded($err), qr{\Qqa/bosh\E.*\bqa\b}s, 'naming the local branch in the way');
};

done_testing;
