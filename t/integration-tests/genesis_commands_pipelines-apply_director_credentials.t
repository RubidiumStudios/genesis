#!/usr/bin/env perl
# Proves T479 (D149): pipeline-apply copies each tracked director's
# credentials from its exodus record into the secrets store, at the pipeline
# scope, as url, ca_cert, client and client_secret.  It writes only on a
# difference, never prints a value, writes the pipeline-scope copy even where
# one is published at the team scope, says what it would copy on a dry run,
# and reports a director with no record as not copied, which the secret
# check then refuses.  An environment tracking nothing copies nothing.
#
# The suite's one vault outlives each subtest, so every subtest names a
# director of its own.
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

my $LOG = "$ENV{HOME}/fly.log";

# A fly that answers a version and a dry run and logs every call.
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

my %RECORD = (url => 'https://10.0.0.6:25555', ca_cert => 'harness-director-ca',
	admin_username => 'admin', admin_password => 'harness-director-password',
	kit_name => 'bosh');

sub apply {
	my ($h, @args) = @_;
	mkfile_or_fail($LOG, '');
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply', @args);
	return ($exit, "$out\n$err", slurp($LOG));
}

# An environment on the director, tracking cloud unless told otherwise,
# with the director's exodus record written unless told not to.
sub on_director {
	my ($director, %o) = @_;
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	write_env_file($h, 'qa', genesis => {bosh_env => $director},
		pipeline => {exists $o{track} ? (track_bosh_configs => $o{track}) : (track_bosh_configs => ['cloud'])});
	run({dir => $h->a, onfailure => 'Failed to push control'},
		'git', 'push', '-q', 'origin', 'control');
	$h->_write_record(exodus_path($h, $director), %RECORD) unless $o{no_record};
	return $h;
}

# Where the director's record sits, under the harness's exodus mount.
sub exodus_path {
	my ($h, $director) = @_;
	return ($h->exodus_mount =~ s{^/}{}r)."$director/bosh";
}

sub vault_get {
	my ($h, $path) = @_;
	my ($out, $rc) = run({env => {SAFE_TARGET => $h->fixture_vault}, stderr => 0},
		Harness::Propagation::real_tool('safe'), 'get', $path);
	return {} if $rc;
	my %got = map {/^(\w+):\s*(.*)$/ ? ($1 => $2) : ()} split /\n/, $out // '';
	return \%got;
}

# The pipeline-scope path the apply reports writing to.
sub copied_to {
	my ($said, $director) = @_;
	my ($path) = $said =~ m{(/?concourse/main/[^/\s]+/bosh/\Q$director\E)\b};
	return $path ? ($path =~ s{^/}{}r) : undef;
}

subtest 'a real apply copies the credentials to the pipeline scope' => sub {
	my $h = on_director('mgmt-copy');
	my ($exit, $said, $fly) = apply($h, '-y');
	is($exit, 0, 'the apply succeeds') or return diag($said);
	like($said, qr/copied\s+bosh\/mgmt-copy\b/, 'reporting the copy');
	unlike($said, qr/harness-director-password|harness-director-ca/, 'never printing a value');

	my $path = copied_to($said, 'mgmt-copy');
	ok($path, 'naming the pipeline-scope path') or return diag($said);
	is_deeply(vault_get($h, $path), {url => $RECORD{url}, ca_cert => $RECORD{ca_cert},
		client => 'admin', client_secret => 'harness-director-password'},
		'the four keys under their pipeline names');
	like($said, qr{found\s+bosh/mgmt-copy\.$_ at /?\Q$path\E}, "and the check finds $_ there")
		for qw/url ca_cert client client_secret/;
	like($fly, qr/set-pipeline/, 'and the pipeline is set');
};

subtest 'a second apply writes only on a difference' => sub {
	my $h = on_director('mgmt-again');
	my ($exit, $said) = apply($h, '-y');
	is($exit, 0, 'the first apply succeeds') or return diag($said);
	my $path = copied_to($said, 'mgmt-again');

	($exit, $said) = apply($h, '-y');
	is($exit, 0, 'the second apply succeeds') or return diag($said);
	like($said, qr/in place\s+bosh\/mgmt-again\b/, 'reporting the copy in place');

	$h->_write_record(exodus_path($h, 'mgmt-again'), %RECORD, admin_password => 'rotated-password');
	($exit, $said) = apply($h, '-y');
	is($exit, 0, 'the apply after a rotation succeeds') or return diag($said);
	like($said, qr/updated\s+bosh\/mgmt-again\b/, 'reporting the copy updated');
	is(vault_get($h, $path)->{client_secret}, 'rotated-password', 'with the new secret');
};

subtest 'a copy published at the team scope does not stop the pipeline-scope copy' => sub {
	my $h = on_director('mgmt-team');
	$h->_write_record('concourse/main/bosh/mgmt-team', url => 'https://owner', ca_cert => 'owner-ca',
		client => 'reader', client_secret => 'owner-secret');
	my ($exit, $said) = apply($h, '-y');
	is($exit, 0, 'the apply succeeds') or return diag($said);
	my $path = copied_to($said, 'mgmt-team');
	ok($path, 'the pipeline-scope copy is written') or return diag($said);
	is(vault_get($h, $path)->{client}, 'admin', 'from the exodus record');
	is(vault_get($h, 'concourse/main/bosh/mgmt-team')->{client}, 'reader', 'and the team copy is left alone');
};

subtest 'a dry run says what it would copy and writes nothing' => sub {
	my $h = on_director('mgmt-dry');
	my ($exit, $said) = apply($h, '--dry-run');
	is($exit, 0, 'the dry run succeeds') or return diag($said);
	like($said, qr/would copy\s+bosh\/mgmt-dry\b/, 'saying it would copy');
	like($said, qr/coming\s+bosh\/mgmt-dry\.url/, 'and the check counts it coming');
	my $path = copied_to($said, 'mgmt-dry');
	ok(!$path || !%{vault_get($h, $path)}, 'and nothing is written');
};

subtest 'a director with no exodus record is not copied, and the check refuses' => sub {
	my $h = on_director('mgmt-none', no_record => 1);
	my ($exit, $said, $fly) = apply($h, '-y');
	is($exit, 78, 'the apply refuses at CONFIG') or diag($said);
	my $exodus = exodus_path($h, 'mgmt-none');
	like($said, qr{not copied\s+bosh/mgmt-none.*/?\Q$exodus\E}, 'naming the exodus path');
	like($said, qr/missing\s+bosh\/mgmt-none\.url/, 'and the check finds it missing');
	unlike($fly, qr/set-pipeline/, 'before the pipeline is set');
};

# An HA store confirms every write by reading it back, and a director's CA is
# a PEM, many lines long and longer than one write's batch.
subtest 'a multi-line CA is copied and confirmed on a store that reads writes back' => sub {
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = 1;
	my $pem = join("\n", '-----BEGIN CERTIFICATE-----', ('A' x 64) x 20,
		'-----END CERTIFICATE-----', '');
	my $h = on_director('mgmt-pem', no_record => 1);
	$h->_write_record(exodus_path($h, 'mgmt-pem'), %RECORD, ca_cert => $pem);
	my ($exit, $said) = apply($h, '-y');
	is($exit, 0, 'the apply succeeds') or return diag($said);
	like($said, qr/copied\s+bosh\/mgmt-pem\b/, 'reporting the copy');
	my $path = copied_to($said, 'mgmt-pem');
	is(vault_get($h, $path)->{client}, 'admin', 'and every key is written');
};

subtest 'an environment tracking nothing copies nothing' => sub {
	my $h = on_director('mgmt-off', track => 'false');
	my ($exit, $said) = apply($h, '-y');
	is($exit, 0, 'the apply succeeds') or return diag($said);
	unlike($said, qr/bosh\/mgmt-off/, 'and names no director');
};

done_testing;
