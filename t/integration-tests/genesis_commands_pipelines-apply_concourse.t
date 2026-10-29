#!/usr/bin/env perl
# Proves T384: a real pipeline-apply under Concourse sets the pipeline, at the
# operator's own target, and refuses what it can before it writes anything
# (D86 noted 2026-10-15, D115).  A stub fly logs every call; the harness names
# its Concourse https://ci.harness.example, team main, and ~/.flyrc holds the
# one target that matches.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/mkfile_or_fail mkdir_or_fail slurp run/;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $log = "$ENV{HOME}/fly.log";
mkdir_or_fail("$ENV{HOME}/bin");
$ENV{GENESIS_FLY_BIN} = "$ENV{HOME}/bin/fly";
mkfile_or_fail("$ENV{HOME}/.flyrc",
	"targets:\n  harness-main:\n    api: https://ci.harness.example\n    team: main\n");

# A fly that logs its arguments, answers --version with $version, and answers
# set-pipeline --dry-run with $dry, a change to the pipeline unless a row
# says otherwise (T440).
sub stub_fly {
	my ($version, $dry) = @_;
	$dry //= "jobs:\n  job deploy-qa has changed:\n  + serial: true\n";
	unlink $log;
	my $answer = "$ENV{HOME}/bin/fly-dry-run.txt";
	mkfile_or_fail($answer, $dry);
	mkfile_or_fail("$ENV{HOME}/bin/fly", 0755, join("\n",
		'#!/bin/sh',
		"echo \"\$*\" >> '$log'",
		"case \"\$*\" in *--version*) echo $version; exit 0;; esac",
		"case \"\$*\" in *--dry-run*) cat '$answer'; exit 0;; esac",
		'exit 0', ''));
}

sub fly_calls { -f $log ? grep {!/--version/} split /\n/, slurp($log) : () }

# The calls that change the pipeline, which a dry run and a validation do not.
sub fly_writes {
	map {/(pause-pipeline|set-pipeline|unpause-pipeline|expose-pipeline|hide-pipeline)/ ? $1 : ()}
		grep {!/--dry-run|validate-pipeline/} fly_calls();
}

sub remote_refs {
	my ($h) = @_;
	my ($out) = run({dir => $h->a}, 'git', 'ls-remote', $h->r);
	return $out;
}

subtest 'the apply sets the pipeline at the target ~/.flyrc names' => sub {
	# Six rows; the apply writes, so no restoration row.
	plan tests => 6;

	stub_fly('7.11.0');
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	my (undef, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply', '-y');
	my $said = unfolded($err);
	is($exit, 0, 'the apply succeeds') or diag($err);

	my @calls = fly_calls();
	my @verbs = fly_writes();
	is_deeply([@verbs[0..2]], [qw/pause-pipeline set-pipeline unpause-pipeline/],
		'pausing, setting, then unpausing the pipeline')
		or diag(join("\n", @calls));
	like($verbs[3] // '', qr/^(?:expose|hide)-pipeline$/, 'and exposing or hiding it');
	ok(@calls && !grep({!/-t harness-main\b/} @calls), 'every call at the matched target')
		or diag(join("\n", @calls));
	ok(grep({/set-pipeline -n --team main -p bosh -c /} @calls), 'setting it by name, for the team');

	my ($compiled) = $said =~ /(Generating concourse pipeline)/ ? $-[0] : -1;
	my $created    = $said =~ /created qa\/bosh/ ? $-[0] : -1;
	ok($compiled >= 0 && $created >= 0 && $compiled < $created,
		'the compile runs before any branch is cut');
};

subtest 'a fly the apply cannot use refuses before anything is written' => sub {
	# Three rows; the remote and the vault are the proof nothing was written.
	plan tests => 3;

	# No fly at all, which the prerequisites check refuses on every apply.
	local $ENV{GENESIS_FLY_BIN} = "$ENV{HOME}/bin/no-such-fly";
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	my $before = remote_refs($h);
	my (undef, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply', '-y');
	isnt($exit, 0, 'the apply refuses') or diag($err);
	is(remote_refs($h), $before, 'no deployment branch was created on the remote');
	no_secret($h->applied_path, 'and no applied record was written');
};

# Proves T440: the apply asks its own question, so a set nobody confirmed is
# never reported as made.  A spawned run has no terminal, which is the shape
# the escape was found in.
subtest 'with nobody to confirm it, the pipeline is not set' => sub {
	# Four rows; the apply writes branches and records, so no restoration row.
	plan tests => 4;

	stub_fly('7.11.0');
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	my (undef, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply');
	my $said = unfolded($err);
	isnt($exit, 0, 'the apply does not succeed') or diag($err);
	like($said, qr/job deploy-qa has changed/, 'it shows what it would set');
	like($said, qr/[Nn]othing was set.*-y/, 'says nothing was set, naming -y');
	is_deeply([fly_writes()], [], 'and neither pauses, sets nor unpauses the pipeline')
		or diag(join("\n", fly_calls()));
};

subtest 'a pipeline already set is left as it is' => sub {
	# Three rows; the apply writes branches and records, so no restoration row.
	plan tests => 3;

	stub_fly('7.11.0', "no changes to apply\n");
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	my (undef, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply', '-y');
	is($exit, 0, 'the apply succeeds') or diag($err);
	like(unfolded($err), qr/already set/, 'saying the pipeline is already set');
	ok(!grep({$_ eq 'set-pipeline'} fly_writes()), 'and it is not set again')
		or diag(join("\n", fly_calls()));
};

done_testing;
