#!/usr/bin/env perl
# Proves T472 (D142): pipeline-apply checks every ((name.key)) reference in the
# pipeline it compiled against the store Concourse resolves them from, where
# Concourse would look, before anything is set.  A reference found is reported
# with where it was found and never its value; one found nowhere refuses the
# apply naming the paths Concourse reads, unless --missing-secrets-ok; a dry
# run reports and never refuses; and with no vault to read every reference is
# unverified and the apply goes on.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/mkfile_or_fail mkdir_or_fail slurp run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $REF  = 'secret/ci/git.private_key';
my $LOG  = "$ENV{HOME}/fly.log";

# A fly that answers a version and a dry run and logs every call, so a row can
# tell whether set-pipeline was ever reached.
mkdir_or_fail("$ENV{HOME}/bin") unless -d "$ENV{HOME}/bin";
$ENV{GENESIS_FLY_BIN} = "$ENV{HOME}/bin/fly";
mkfile_or_fail("$ENV{HOME}/.flyrc",
	"targets:\n  harness-main:\n    api: https://ci.harness.example\n    team: main\n");
mkfile_or_fail("$ENV{HOME}/bin/fly", 0755, join("\n",
	'#!/bin/sh',
	"echo \"\$*\" >> '$LOG'",
	'case "$*" in *--version*) echo 7.11.0; exit 0;; esac',
	'case "$*" in *--dry-run*) echo "jobs:"; exit 0;; esac',
	'exit 0', ''));

sub apply {
	my ($h, @args) = @_;
	mkfile_or_fail($LOG, '');
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply', @args);
	return ($exit, "$out\n$err", slurp($LOG));
}

subtest 'a secret where Concourse reads it is reported found' => sub {
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	my ($exit, $said, $fly) = apply($h, '-y');
	is($exit, 0, 'the apply succeeds') or return diag($said);
	like($said, qr{found\s+\Q$REF\E.*/concourse/main/secret/ci/git}, 'the reference is found at the team scope');
	unlike($said, qr/harness-clone-key/, 'and its value is never printed');
	like($fly, qr/set-pipeline/, 'and the pipeline is set');
};

subtest 'a secret found nowhere refuses the apply' => sub {
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	$h->forget_pipeline_secrets;
	my ($exit, $said, $fly) = apply($h, '-y');
	is($exit, 78, 'the apply refuses at CONFIG') or diag($said);
	like($said, qr/missing\s+\Q$REF\E/, 'naming the reference');
	like($said, qr{/concourse/main/[^/\s]+/secret/ci/git}, 'and the pipeline scope Concourse reads first');
	like($said, qr{/concourse/main/secret/ci/git}, 'and the team scope after it');
	like($said, qr/--missing-secrets-ok/, 'and the way past');
	unlike($fly, qr/set-pipeline/, 'before the pipeline is set');
};

subtest '--missing-secrets-ok applies anyway' => sub {
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	$h->forget_pipeline_secrets;
	my ($exit, $said, $fly) = apply($h, '-y', '--missing-secrets-ok');
	is($exit, 0, 'the apply succeeds') or return diag($said);
	like($said, qr/missing\s+\Q$REF\E/, 'still reporting the reference');
	like($fly, qr/set-pipeline/, 'and setting the pipeline');
};

subtest 'a dry run reports and never refuses' => sub {
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	$h->forget_pipeline_secrets;
	my ($exit, $said) = apply($h, '--dry-run');
	is($exit, 0, 'the dry run succeeds') or return diag($said);
	like($said, qr/missing\s+\Q$REF\E/, 'reporting the missing reference');
};

subtest 'with no vault to read every reference is unverified' => sub {
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	$h->forget_pipeline_secrets;
	my ($exit, $said, $fly) = apply($h, '-y', '--skip-vault');
	is($exit, 0, 'the apply goes on') or return diag($said);
	like($said, qr/unverified\s+\Q$REF\E/, 'reporting the reference unverified');
	like($fly, qr/set-pipeline/, 'and setting the pipeline');
};

# T478 (D148): the director's published credentials are checked like any
# other reference.  Missing first, since the vault outlives the subtest.
my @BOSH = map {"bosh/mgmt.$_"} qw/url ca_cert client client_secret/;

sub tracking_mgmt {
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	write_env_file($h, 'qa', genesis => {bosh_env => 'mgmt'},
		pipeline => {track_bosh_configs => ['cloud']});
	# Published, since the apply refuses an unpublished control.
	run({dir => $h->a, onfailure => 'Failed to push control'},
		'git', 'push', '-q', 'origin', 'control');
	return $h;
}

subtest "a director's credentials found nowhere refuse the apply" => sub {
	my $h = tracking_mgmt();
	my ($exit, $said, $fly) = apply($h, '-y');
	is($exit, 78, 'the apply refuses at CONFIG') or diag($said);
	like($said, qr/missing\s+\Q$_\E/, "naming $_") for @BOSH;
	like($said, qr{/concourse/main/bosh/mgmt}, 'and the team scope Concourse reads');
	unlike($fly, qr/set-pipeline/, 'before the pipeline is set');
};

subtest "a director's credentials published at the team scope are found" => sub {
	my $h = tracking_mgmt();
	$h->_write_record('concourse/main/bosh/mgmt', url => 'https://10.0.0.6:25555',
		ca_cert => 'harness-ca', client => 'reader', client_secret => 'harness-director-secret');
	my ($exit, $said, $fly) = apply($h, '-y');
	is($exit, 0, 'the apply succeeds') or return diag($said);
	like($said, qr{found\s+\Q$_\E.*/concourse/main/bosh/mgmt}, "finding $_") for @BOSH;
	unlike($said, qr/harness-director-secret/, 'and never printing a value');
	like($fly, qr/set-pipeline/, 'and the pipeline is set');
};

done_testing;
