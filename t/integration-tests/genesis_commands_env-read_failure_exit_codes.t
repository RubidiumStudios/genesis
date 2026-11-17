#!/usr/bin/env perl
# Proves T493 for the commands about one environment: a read that fails
# exits by the name of its cause (D163).  An outage exits UNAVAILABLE and a
# record its owner judges invalid exits DATAERR.
#
# The refusal, which exits NOPERM, is proved beside each command's own rows:
# genesis_commands_env-deploy_unreadable_record.t,
# genesis_commands_env-read_only_unreadable_record.t and
# genesis_commands_env-secrets_certified.t.  Those rows have the vault refuse
# each record a command reads.  These take one or two records per command
# and vary the cause instead.
#
# An outage is the harness's safe answering that the vault is sealed.  An
# invalid record is one written where the record stands, in a shape its
# owner does not write: a value on a deployment history's own path, which
# reads as an entry that is not a deployment; an applied record whose
# control commit is not a commit; a proposed record with no control commit.
#
# Each cause is armed on a harness built for the row, so no row leaves a
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
use Genesis::Exit qw/UNAVAILABLE DATAERR/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# lab, then qa following it, both applied, delivered and certified, against a
# director that answers, so a command has a deployed environment to read and
# a deploy that went on would be seen to reach the director.
sub two_stage {
	my $h = ready_harness(envs => ['lab', 'qa'], chained => 1);
	fixture_bosh($h);
	return $h;
}

sub outage_at  { my ($h, $path) = @_; break_vault_reads($h, {as => 'outage'}, $path) }
sub history_of { my ($h, $env) = @_; return $h->env_path($env).'/deployments' }

# A value on the history's own path reads as an entry of the history that is
# not a deployment record.
sub stray_entry_in {
	my ($h, $env) = @_;
	$h->_write_record(history_of($h, $env), note => 'left by hand');
}

# The walk keeps the first paragraph of what a reader raised, so the rows
# match the reason and not the advice that follows it.
my $OUTAGE  = qr/Could not read .* from vault at .*Vault is sealed/s;
my $HISTORY = qr/holds an entry that is not a deployment record/;

# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------
# The deploy reads two of its five records itself and three through the
# walk, which records a failed read with its code beside it, so both routes
# have a row for each cause.
my @DEPLOY = (
	["an outage at the predecessor's history, which the deploy reads itself",
		sub { outage_at($_[0], history_of($_[0], 'lab')) }, UNAVAILABLE, $OUTAGE],
	['an outage at the hold, which the walk reads',
		sub { outage_at($_[0], $_[0]->env_path('qa').'/hold') }, UNAVAILABLE, $OUTAGE],
	["an entry of the predecessor's history that is not a deployment",
		sub { stray_entry_in($_[0], 'lab') }, DATAERR, $HISTORY],
	['an applied record that is not one',
		sub { $_[0]->_write_record($_[0]->applied_path, control_commit => 'not-a-commit') },
		DATAERR, qr/is not a valid applied record/],
	['a proposed record that is not one, which the walk reads',
		sub { $_[0]->_write_record($_[0]->env_path('qa').'/proposed', number => 7) },
		DATAERR, qr/proposed record for qa.*is not one Genesis writes/s],
);

for my $row (@DEPLOY) {
	my ($what, $arm, $code, $says) = @$row;
	subtest "deploy: $what" => sub {
		my $h = two_stage();
		$arm->($h);

		my (undef, $err, $exit) = run_genesis($h,
			'qa', 'deploy', '--no-propagate', '-y', 'r');
		my $said = unfolded($err);

		is($exit, $code, 'the deploy stops with the code the cause earns')
			or diag("what the deploy said:\n$err");
		like($said, $says, 'saying what the reader or the owner said')
			or diag("what the deploy said:\n$err");
		is(scalar(() = $err =~ /\[FATAL\]/g), 1, 'once, under one prefix')
			or diag("what the deploy said:\n$err");
		is(scalar(bosh_runs($h, command => 'deploy')), 0, 'and BOSH was never asked to deploy');
	};
}

# ---------------------------------------------------------------------------
# pending-changes
# ---------------------------------------------------------------------------
my @PENDING = (
	["an outage at the environment's history",
		sub { outage_at($_[0], history_of($_[0], 'qa')) }, UNAVAILABLE, $OUTAGE],
	["an entry of the environment's history that is not a deployment",
		sub { stray_entry_in($_[0], 'qa') }, DATAERR, $HISTORY],
);

for my $row (@PENDING) {
	my ($what, $arm, $code, $says) = @$row;
	subtest "pending-changes: $what" => sub {
		my $h = two_stage();
		$arm->($h);

		my ($out, $err, $exit) = run_genesis($h, 'qa', 'pending-changes');
		my $said = unfolded($out.$err);

		is($exit, $code, 'the command fails with the code the cause earns')
			or diag("what it said:\n$out$err");
		like($said, $says, 'saying what the reader or the owner said')
			or diag("what it said:\n$out$err");
		unlike($said, qr/never been deployed|has never deployed|first deploy is pending/,
			'and not that the environment was never deployed');
	};
}

# ---------------------------------------------------------------------------
# rotate-secrets
# ---------------------------------------------------------------------------
# One environment, delivered and certified, as the secrets commands' own
# file builds it: the history is read before the rotation, so the stop comes
# while nothing has been changed.
sub rotation_harness {
	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $control = commit_on_control($h,
		files   => {'ops/base.yml' => "---\nversion: one\n"},
		message => 'the certified content',
		push    => 1,
	);
	init_branch($h, 'qa');
	my $deployed = deliver($h, 'qa', control => $control);
	certify($h, 'qa', commit => $deployed, control_commit => $control);
	refresh($h, 'a');
	fixture_bosh($h, kit => 0);
	stand_on($h, $h->control);
	return $h;
}

my @ROTATE = (
	["an outage at the environment's history",
		sub { outage_at($_[0], history_of($_[0], 'qa')) }, UNAVAILABLE, $OUTAGE],
	["an entry of the environment's history that is not a deployment",
		sub { stray_entry_in($_[0], 'qa') }, DATAERR, $HISTORY],
);

for my $row (@ROTATE) {
	my ($what, $arm, $code, $says) = @$row;
	subtest "rotate-secrets: $what" => sub {
		my $h = rotation_harness();
		# Everything the vault holds, read on the row's own path so the read
		# is not one of the run's.
		my $held = sub {
			my ($all) = Genesis::run({env => {SAFE_TARGET => $h->{vault_target}}, stderr => 0},
				Harness::Propagation::_real_safe(), 'export', 'secret');
			return $all;
		};
		$arm->($h);
		my $before = $held->();

		my ($out, $err, $exit) = run_genesis($h, 'qa', 'rotate-secrets', '-y');
		my $said = unfolded($out.$err);

		is($exit, $code, 'the rotation stops with the code the cause earns')
			or diag("what it said:\n$out$err");
		like($said, $says, 'saying what the reader or the owner said')
			or diag("what it said:\n$out$err");
		is($held->(), $before, 'and no secret was changed');
	};
}

done_testing;
