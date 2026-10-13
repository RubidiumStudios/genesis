#!/usr/bin/env perl
# Proves T361: a writing run with no GITHUB_AUTH_TOKEN and an environment that
# delivers into a pull request refuses as a whole at CONFIG before anything is
# written, naming the variable and the environment, moving nothing, writing no
# record and calling no API; a run with no such environment needs no token;
# and a preview with no token still runs and says a real run would refuse
# (D55, noted 2026-10-13).
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit qw/CONFIG/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# Every local branch and tracking ref in copy A, and every branch on R, so a
# row can say a refusal moved none of them.
sub refs_everywhere {
	my ($h) = @_;
	my ($local) = run({dir => $h->a}, 'git', 'for-each-ref',
		'--format=%(refname) %(objectname)', 'refs/heads', 'refs/remotes');
	my ($remote) = run({dir => $h->r}, 'git', 'for-each-ref',
		'--format=%(refname) %(objectname)', 'refs/heads');
	return "$local\n--\n$remote";
}

subtest 'a pull request environment with no token is refused before anything is written' => sub {
	my $h = ready(kit => 'omega-v2.7.0');
	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	my $before = refs_everywhere($h);

	my ($out, $err, $exit) = run_genesis($h, {no_token => 1}, 'propagate', '-y');
	my $said = unfolded($out, $err);

	is($exit, CONFIG, 'the run is refused at CONFIG') or diag($said);
	like($said, qr/GITHUB_AUTH_TOKEN/, 'naming the variable');
	like($said, qr/\bprod\b/, 'and the environment that delivers into a pull request');
	is(refs_everywhere($h), $before, 'no branch moved in L, T or R');
	is(record_at($h, $h->env_path('prod').'/proposed'), undef, 'no record was written');
	is(scalar(gh_calls($h->{gh})), 0, 'and no call was made to the API');
};

subtest 'a run with no pull request environment needs no token' => sub {
	my $h = make_harness(envs => ['lab', 'qa'], github => 1,
		kit => 'omega-v2.7.0');
	$h->ready_envs;
	due_commit($h, $_, params => {instances => 2},
		message => 'Raise the cf instance count') for qw/lab qa/;

	my ($out, $err, $exit) = run_genesis($h, {no_token => 1}, 'propagate', '-y');
	is($exit, 0, 'the run proceeds') or diag(unfolded($out, $err));
	like($err, qr/^\s*qa: propagated\b/m, 'and delivers');
};

subtest 'a preview with no token runs, and says a real run would refuse' => sub {
	my $h = ready(kit => 'omega-v2.7.0');
	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');

	my ($out, $err, $exit) = run_genesis($h, {no_token => 1}, 'propagate', '--dry-run');
	my $said = unfolded($out, $err);

	is($exit, 0, 'the preview runs to the end') or diag($said);
	like($said, qr/a real run would refuse/i, 'and says a real run would refuse');
	unlike($said, qr/would still write and publish/,
		'never that a real run would write and publish the branches');
};

done_testing;
