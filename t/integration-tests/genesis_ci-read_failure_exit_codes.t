#!/usr/bin/env perl
# Proves T493 for the commands about the whole pipeline: a read that fails
# exits by the name of its cause (D163).  An outage exits UNAVAILABLE, a
# record its owner judges invalid exits DATAERR, and a propagate run with
# more than one failed environment exits the worst of their causes.
#
# The refusal, which exits NOPERM, is proved beside each command's own rows:
# genesis_ci_walk-durable_state.t for the applied record,
# genesis_ci_walk-unreadable_record.t for one environment of a run, and
# genesis_ci_status-unreadable_record.t for pipeline-status.  These rows
# vary the cause instead.
#
# An outage is the harness's safe answering that the vault is sealed.  An
# invalid record is one written where the record stands, in a shape its
# owner does not write.
#
# Genesis accounts for itself on standard error, which is where info writes,
# so a run's report comes out of the second value run_genesis answers.
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
use Genesis::Exit qw/UNAVAILABLE DATAERR/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# lab, then qa following it, both applied, delivered and certified, on a kit
# the environments load with, so a row that fails is failing on the vault.
sub two_stage {
	return ready_harness(envs => ['lab', 'qa'], chained => 1, kit => 'omega-v2.7.0');
}

sub outage_at { my ($h, $path) = @_; break_vault_reads($h, {as => 'outage'}, $path) }

# ---------------------------------------------------------------------------
# propagate: the applied record, which is a whole-run input
# ---------------------------------------------------------------------------
my @APPLIED = (
	['an outage at the applied record',
		sub { outage_at($_[0], $_[0]->applied_path) },
		UNAVAILABLE, qr/Vault is sealed/],
	['an applied record that is not one',
		sub { $_[0]->_write_record($_[0]->applied_path, control_commit => 'not-a-commit') },
		DATAERR, qr/is not a valid applied record/],
);

for my $row (@APPLIED) {
	my ($what, $arm, $code, $says) = @$row;
	subtest "propagate: $what" => sub {
		my $h = two_stage();
		my $before = ref_in($h->r, 'refs/heads/'.$h->slug('qa'));
		$arm->($h);

		my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
		my $said = unfolded($err);

		is($exit, $code, 'the run refuses with the code the cause earns') or diag($err);
		like($said, qr/\Q@{[$h->applied_path]}\E/, 'naming the applied record');
		like($said, $says, 'and what the reader or the owner said') or diag($err);
		is(ref_in($h->r, 'refs/heads/'.$h->slug('qa')), $before, 'and nothing was delivered');
	};
}

# ---------------------------------------------------------------------------
# propagate: two environments failed on different causes
# ---------------------------------------------------------------------------
# T493's own row.  lab and qa stand beside each other, neither following the
# other, so each fails on its own record and neither is held behind the
# other.  The run exits the worst of the two causes, and an invalid record
# outranks an outage.
subtest 'propagate: one environment failed on an outage and another on an invalid record' => sub {
	my $h = ready_harness(
		envs    => ['lab', 'qa'],
		kit     => 'omega-v2.7.0',
		tracked => ['ops/shared.yml'],
	);
	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: 2\n"},
		message => 'Bump shared ops',
		push    => 1,
	);
	outage_at($h, $h->env_path('lab').'/hold');
	$h->_write_record($h->env_path('qa').'/proposed', number => 7);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($err);

	is($exit, DATAERR, 'the run exits DATAERR, the worst of the two causes') or diag($err);
	like($err, qr/^\s*lab: failed/m, 'lab, whose hold the vault did not answer for, ends failed')
		or diag($err);
	like($said, qr/Vault is sealed/, 'with what the vault said');
	like($err, qr/^\s*qa: failed/m, 'qa, whose proposed record is not one, ends failed')
		or diag($err);
	like($said, qr/proposed record for qa.*is not one Genesis writes/, 'with what its owner said');
};

# ---------------------------------------------------------------------------
# pipeline-status
# ---------------------------------------------------------------------------
# The report is printed whole, each row that could not be read carries the
# code its cause earns, and the command exits the worst of them.
my @STATUS = (
	# what, how it is armed, the environment whose row it is, the code, what the row says
	['an outage at the hold of qa',
		sub { outage_at($_[0], $_[0]->env_path('qa').'/hold') },
		'qa', UNAVAILABLE, qr/Could not read .*hold.*Vault is sealed/],
	["an entry of lab's history that is not a deployment",
		sub { $_[0]->_write_record($_[0]->env_path('lab').'/deployments', note => 'left by hand') },
		'lab', DATAERR, qr/holds an entry that is not a deployment record/],
);

for my $row (@STATUS) {
	my ($what, $arm, $env, $code, $says) = @$row;
	subtest "pipeline-status: $what" => sub {
		my $h = two_stage();
		$arm->($h);

		my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
		my $record = eval {decode_json($out)};
		ok($record, 'the report is still one JSON document on standard output')
			or diag("stdout:\n$out\nstderr:\n$err");
		is($exit, $code, 'and the command exits the code the cause earns')
			or diag("stdout:\n$out\nstderr:\n$err");
		my %row = map {($_->{env} => $_)} @{($record || {})->{environments} || []};
		is_deeply([sort keys %row], [qw/lab qa/], 'with both environments in it');
		like($row{$env}{error} // '', $says, "the row for $env carries the reason");
		is($row{$env}{exit_code}, $code, 'and the code, beside it');
	};
}

done_testing;
