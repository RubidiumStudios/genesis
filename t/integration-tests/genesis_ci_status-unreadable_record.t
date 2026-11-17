#!/usr/bin/env perl
# Proves T490's second half: pipeline-status keeps every row when a record
# cannot be read, says "could not read" with the reason on the row it
# belongs to, and exits the code the failed read's cause earns (D160, D163).
#
# A report is read by somebody deciding what to do next, so an environment
# whose records the vault refused is neither left out nor shown with the
# values of one that has nothing stored.  The rows that could be read are
# still worth having, which is why the report is printed and the exit says
# it is incomplete.
#
# Each row has the vault refuse one record of one environment.  The refusals
# are armed on a harness built for the row.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use JSON::PP qw/decode_json/;

use Genesis;
use Genesis::Exit qw/NOPERM/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# lab, then qa following it, both applied, delivered and certified, on a kit
# the environments load with, so a row that fails is failing on the vault.
sub two_stage {
	return ready_harness(envs => ['lab', 'qa'], chained => 1, kit => 'omega-v2.7.0');
}

my @READS = (
	# what,                       environment, path under it, the other row
	['the hold',                  'qa',  '/hold',        'lab'],
	['the pipeline record',       'qa',  '/pipeline',    'lab'],
	['the deployment history',    'lab', '/deployments', 'qa'],
);

for my $read (@READS) {
	my ($what, $env, $under, $other) = @$read;
	subtest "$what of $env cannot be read" => sub {
		# Six rows, and one for the run's own restoration assertion.
		plan tests => 7;

		my $h = two_stage();
		my $path = $h->env_path($env).$under;
		break_vault_reads($h, $path);

		my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
		my ($row)   = grep {/^\s*\Q$env\E\s/}   split /\n/, $out;
		my ($stood) = grep {/^\s*\Q$other\E\s/} split /\n/, $out;

		# The harness's broken read is a refusal, which exits NOPERM (D163).
		is($exit, NOPERM, 'the command exits NOPERM, as on a refusal')
			or diag("stdout:\n$out\nstderr:\n$err");
		ok(defined $row, "the report still has a row for $env") or diag("stdout:\n$out\nstderr:\n$err");
		# A reader that exports names the path without its leading slash.
		like($row // '', qr/Could not read \/?\Q@{[$path =~ s{^\/}{}r]}\E/, 'which says what could not be read');
		like($row // '', qr/permission denied/, 'and what the vault answered');
		like($stood // '', qr/deployed/, "and $other, which could be read, is reported as it stands");
		unlike($row // '', qr/not propagated|never deployed|\bdeployed$/,
			'the unread row shows no reading it did not make');
	};
}

subtest 'the header does not answer for an environment the staleness could not read' => sub {
	# Nine rows, and one for each run's own restoration assertion.
	plan tests => 11;

	my $h = two_stage();
	break_vault_reads($h, $h->env_path('qa').'/pipeline');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	my ($header) = grep {/applied at/} split /\n/, $out;
	like($header // '', qr/\[stale: unverifiable\]\s+could not read qa/,
		'the header says the staleness is unverifiable, and for which environment')
		or diag("stdout:\n$out\nstderr:\n$err");
	unlike($header // '', qr/does not hold that commit/, 'and does not blame a commit this clone holds');

	($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
	my $record = eval {decode_json($out)};
	ok($record, 'the JSON report is still one document on standard output')
		or diag("stdout:\n$out\nstderr:\n$err");
	is($exit, NOPERM, 'and the JSON run exits NOPERM too');
	my %row = map {($_->{env} => $_)} @{($record || {})->{environments} || []};
	is_deeply([sort keys %row], [qw/lab qa/], 'with both environments in it');
	like($row{qa}{error} // '', qr/Could not read .*pipeline.*permission denied/,
		'the unread environment carries the reason');
	is($row{qa}{exit_code}, NOPERM, 'and the code its cause earns, beside it');
	is($row{lab}{exit_code}, undef, 'which the environment that was read does not carry');
	is_deeply(
		[$record->{applied}{stale}, $record->{applied}{stale_unread}],
		[undef, ['qa']],
		'and the staleness is null, with the environment it could not read named');
};

subtest 'a report that read everything exits 0 and names nothing unread' => sub {
	# Three rows, and one for the run's own restoration assertion.
	plan tests => 4;

	my $h = two_stage();
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
	my $record = eval {decode_json($out)};
	is($exit, 0, 'the command exits 0') or diag("stdout:\n$out\nstderr:\n$err");
	is_deeply($record->{applied}{stale_unread}, [], 'no environment is named as unread');
	ok(defined $record->{applied}{stale}, 'and the staleness is answered');
};

done_testing;
