#!/usr/bin/env perl
# Proves T490's first half: a read-only command about one environment never
# shows a default for a record it could not read (D160).
#
# Each row has the vault refuse one record the command reads and reads the
# same things off the run: the command fails, names the path and what the
# vault said, and prints none of what it would have printed for a record
# that is not there.  A refused read and an absent record are different
# answers, and a report that words the first as the second tells an operator
# that an environment was never deployed when nobody could look.
#
# The refusals are armed on a harness built for the row, so no row leaves a
# broken vault behind for another.
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

# lab, then qa following it, both applied, delivered and certified, against a
# director that answers, so each command has a deployed environment to read.
sub two_stage {
	my $h = ready_harness(envs => ['lab', 'qa'], chained => 1);
	fixture_bosh($h);
	return $h;
}

subtest 'pending-changes: the deployment history cannot be read' => sub {
	# Six rows, and one for the run's own restoration assertion.
	plan tests => 7;

	my $h = two_stage();
	my $path = $h->env_path('qa').'/deployments';
	my $summary = workdir('pending-summary').'/summary.txt';
	break_vault_reads($h, $path);

	my ($out, $err, $exit) = run_genesis($h,
		'qa', 'pending-changes', '--summary-file', $summary);
	my $said = unfolded($out.$err);

	# The harness's broken read is a refusal, which exits NOPERM (D163).
	is($exit, Genesis::Exit::NOPERM, 'the command fails, as on a refusal')
		or diag("what it said:\n$out$err");
	# A reader that exports names the path without its leading slash.
	like($said, qr/\Q@{[$path =~ s{^\/}{}r]}\E/, 'naming the path it could not read');
	like($said, qr/permission denied/, 'and what the vault answered');
	unlike($said, qr/never been deployed|has never deployed/,
		'it does not say the environment was never deployed');
	unlike($said, qr/first deploy is pending/, 'or that a first deploy is pending');
	like(unfolded(-f $summary ? get_file($summary) : ''),
		qr/could not be determined.*permission denied/,
		'and the summary file says why there is no summary');
};

# The commands that already stopped, pinned, and the two that did not: a run
# that asks for the deployed commit and a check of the secrets, both of which
# read the deployment history through a reader that took a refusal for no
# record.
my @ROWS = (
	# name, path under qa, arguments, what a record that is not there would have printed
	['info: the deployment history',
		'/deployments', [qw/info/], qr/never been deployed|has not been deployed/],
	['info --as-deployed: the deployment history',
		'/deployments', [qw/info --as-deployed/], qr/No successful deploy recorded/],
	['check-secrets --as-deployed: the deployment history',
		'/deployments', [qw/check-secrets --as-deployed/], qr/No successful deploy recorded/],
	['check-secrets: the deployment history',
		'/deployments', [qw/check-secrets/], qr/validated secrets successfully/],
	['lookup --exodus: the exodus record',
		'', [qw/lookup --exodus dated never-deployed/], qr/never-deployed/],
	['manifest: the exodus record',
		'', [qw/manifest/], qr/^name:/m],
);

for my $row (@ROWS) {
	my ($name, $under, $args, $default) = @$row;
	subtest "$name cannot be read" => sub {
		# Five rows, and one for the run's own restoration assertion.
		plan tests => 6;

		my $h = two_stage();
		my $path = $h->env_path('qa').$under;
		break_vault_reads($h, $path);

		my ($out, $err, $exit) = run_genesis($h, 'qa', @$args);
		my $said = unfolded($out.$err);

		is($exit, Genesis::Exit::NOPERM, 'the command fails, as on a refusal')
			or diag("what it said:\n$out$err");
		like($said, qr/Could not read \/?\Q@{[$path =~ s{^\/}{}r]}\E/, 'naming the path it could not read');
		like($said, qr/permission denied/, 'and what the vault answered');
		unlike($out.$err, $default, 'it prints nothing it would have for a record that is not there');
		is(scalar(() = ($out.$err) =~ /\[FATAL\]/g), 1, 'and says so once, under one prefix')
			or diag("what it said:\n$out$err");
	};
}

done_testing;
