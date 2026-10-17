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

# A fly that logs its arguments, and answers --version with $version.
sub stub_fly {
	my ($version) = @_;
	unlink $log;
	mkfile_or_fail("$ENV{HOME}/bin/fly", 0755, join("\n",
		'#!/bin/sh',
		"echo \"\$*\" >> '$log'",
		"case \"\$*\" in *--version*) echo $version; exit 0;; esac",
		'exit 0', ''));
}

sub fly_calls { -f $log ? grep {!/--version/} split /\n/, slurp($log) : () }

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
	my @verbs = map {/(pause-pipeline|set-pipeline|unpause-pipeline|expose-pipeline|hide-pipeline)/ ? $1 : ()} @calls;
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

done_testing;
