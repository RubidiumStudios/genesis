#!/usr/bin/env perl
# Proves T485: a deploy stops on a pre-flight read it cannot make (D156).
#
# Before it deploys, a deploy reads five records: the applied record, the
# hold standing on the environment, its predecessor's deployment history, its
# proposed record and its pipeline record.  Each row has the vault refuse one
# of them and reads the same things off the run: the deploy stops, names the
# path and what the vault said, says nothing was deployed, and BOSH was never
# asked to deploy.
#
# A deploy needs the vault for the rest of its run, and one that carried on
# past an unreadable applied record skipped the confirmation of the commits
# due to the branch, so none of these is a warning.
#
# The last row is the other half: the same record absent.  A predecessor with
# no history has never deployed, which is an answer, and the deploy goes on.
#
# Every run calls fixture_bosh, so a deploy that did go on would reach the
# director and be seen to.  Every run passes --no-propagate, for the reason
# the stale-pipeline file next door gives.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# lab, then qa following it, both applied, delivered and certified, so the
# deploy of qa has a predecessor whose history it reads.
sub two_stage {
	my $h = ready_harness(envs => ['lab', 'qa'], chained => 1);
	fixture_bosh($h);
	return $h;
}

my @READS = (
	['the applied record',        sub { $_[0]->applied_path }],
	['the hold',                  sub { $_[0]->env_path('qa').'/hold' }],
	["the predecessor's history", sub { $_[0]->env_path('lab').'/deployments' }],
	['the proposed record',       sub { $_[0]->env_path('qa').'/proposed' }],
	['the pipeline record',       sub { $_[0]->env_path('qa').'/pipeline' }],
);

for my $read (@READS) {
	my ($what, $path_of) = @$read;
	subtest "$what cannot be read" => sub {
		# Five rows, and one for the run's own restoration assertion.
		plan tests => 6;

		my $h = two_stage();
		my $path = $path_of->($h);
		break_vault_reads($h, $path);

		my (undef, $err, $exit) = run_genesis($h,
			'qa', 'deploy', '--no-propagate', '-y', 'r');
		my $said = unfolded($err);

		# The harness's broken read is a refusal, which exits NOPERM (D163).
		is($exit, Genesis::Exit::NOPERM, 'the deploy stops, as on a refusal')
			or diag("what the deploy said:\n$err");
		# A reader that exports names the path without its leading slash.
		like($said, qr/\Q@{[$path =~ s{^\/}{}r]}\E/, 'naming the path it could not read');
		like($said, qr/permission denied/, 'and what the vault answered');
		like($said, qr/Nothing was deployed/, 'and says nothing was deployed')
			or diag("what the deploy said:\n$err");
		is(scalar(bosh_runs($h, command => 'deploy')), 0, 'and BOSH was never asked to deploy');
	};
}

subtest 'a predecessor with no history has never deployed, and the deploy goes on' => sub {
	# Two rows, and one for the run's own restoration assertion.
	plan tests => 3;

	my $h = two_stage();
	# lab's records are taken away, which a reader sees as nothing stored.
	break_vault($h, envs => ['lab']);

	my (undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, 0, 'the deploy proceeds') or diag("what the deploy said:\n$err");
	is(scalar(bosh_runs($h, command => 'deploy')), 1, 'and BOSH is asked to deploy');
};

done_testing;
