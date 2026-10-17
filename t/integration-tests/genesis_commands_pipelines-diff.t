#!perl
# Proves T376: pipeline-diff is a preview like the others (D112, noted
# 2026-10-16).  It compares through spruce diff, so a live pipeline that
# differs from the compiled one only in key order reports no differences and
# one that differs in a value names that value's path, and --from compiles a
# ref's tree under its banner.  Its branch class is pinned in genesis-cli.t.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/load_yaml to_yaml slurp mkfile_or_fail mkdir_or_fail workdir/;
provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# The harness names its Concourse https://ci.harness.example, team main, and
# a stub fly answers get-pipeline with whatever live.yml holds.
my $live = "$ENV{HOME}/live.yml";
mkdir_or_fail("$ENV{HOME}/bin");
mkfile_or_fail("$ENV{HOME}/bin/fly", 0755, join("\n",
	'#!/bin/sh',
	'case "$*" in',
	'  *--version*) echo 7.11.0;;',
	"  *get-pipeline*) cat '$live';;",
	'esac', ''));
$ENV{GENESIS_FLY_BIN} = "$ENV{HOME}/bin/fly";
mkfile_or_fail("$ENV{HOME}/.flyrc",
	"targets:\n  harness:\n    api: https://ci.harness.example\n    team: main\n");

my $h   = make_harness(envs => ['lab', 'qa'], fanned => 'lab', provider => 'concourse');
my $out = workdir('compiled');
my (undef, $cerr, $cexit) = run_genesis($h, 'pipeline-apply', '--dry-run',
	'--skip-vault', '--output-dir', $out);
my $compiled = load_yaml(slurp("$out/pipeline.yml"));

subtest 'key order alone is no difference' => sub {
	# Two rows, and the run's own restoration assertion.
	plan tests => 3;

	mkfile_or_fail($live, to_yaml($compiled));
	my ($said, $err, $exit) = run_genesis($h, 'pipeline-diff');
	$said = unfolded($said, $err);
	is($exit, 0, 'pipeline-diff succeeds') or diag($err);
	like($said, qr/No differences/, 'and finds none in a reordered copy');
};

subtest 'a value that differs is named by its path' => sub {
	# Two rows, and the run's own restoration assertion.
	plan tests => 3;

	# The live pipeline's one group lists a job the compiled one does not.
	my $changed = load_yaml(to_yaml($compiled));
	push @{$changed->{groups}[0]{jobs}}, 'live-only-job';
	mkfile_or_fail($live, to_yaml($changed));
	my ($said, $err, $exit) = run_genesis($h, 'pipeline-diff');
	is($exit, 0, 'pipeline-diff succeeds') or diag($err);
	like($said, qr/^groups\.bosh\.jobs$/m, "naming the path spruce diff found");
};

subtest '--from compiles a ref under its banner' => sub {
	# Two rows, and the run's own restoration assertion.
	plan tests => 3;

	my $t = 'origin/' . $h->control;
	my (undef, $err, $exit) = run_genesis($h, 'pipeline-diff', '--from', $t);
	is($exit, 0, "pipeline-diff --from $t succeeds") or diag($err);
	like(unfolded($err), qr{shape from \Q$t\E at [0-9a-f]{7}, not from control},
		'under the banner naming the ref');
};

done_testing;
