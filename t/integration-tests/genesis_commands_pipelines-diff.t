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
# a stub fly answers get-pipeline with whatever live.yml holds.  It validates
# a pipeline unless invalid.txt holds Concourse's errors, and answers
# set-pipeline --dry-run with dry-run.txt, or, where there is none, as a fly
# too old to know the flag, which is the spruce fallback (T376, T439).
my $live    = "$ENV{HOME}/live.yml";
my $dry     = "$ENV{HOME}/dry-run.txt";
my $invalid = "$ENV{HOME}/invalid.txt";
mkdir_or_fail("$ENV{HOME}/bin");
mkfile_or_fail("$ENV{HOME}/bin/fly", 0755, join("\n",
	'#!/bin/sh',
	'case "$*" in',
	'  *--version*) echo 7.11.0;;',
	"  *validate-pipeline*) if [ -f '$invalid' ]; then cat '$invalid'; echo 'error: configuration invalid'; exit 1; fi; echo 'looks good';;",
	"  *set-pipeline*) if [ -f '$dry' ]; then cat '$dry'; else echo \"error: unknown flag \\`dry-run'\" >&2; exit 1; fi;;",
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

subtest 'the comparison is Concourse\'s own' => sub {
	# Four rows, and one more for each of the two runs' restoration
	# assertions.
	plan tests => 6;

	mkfile_or_fail($live, to_yaml($compiled));
	mkfile_or_fail($dry, "no changes to apply\n");
	my ($said, $err, $exit) = run_genesis($h, 'pipeline-diff');
	$said = unfolded($said, $err);
	is($exit, 0, 'pipeline-diff succeeds') or diag($err);
	like($said, qr/No differences/, "fly's no changes reads as no differences");

	mkfile_or_fail($dry, "jobs:\n  job deploy-qa has changed:\n  + trigger: true\n".
		"pipeline name: bosh\n\nDry-run mode was set, exiting.\n");
	($said, $err, $exit) = run_genesis($h, 'pipeline-diff');
	$said = join("\n", $said // '', $err // '');
	like($said, qr/job deploy-qa has changed:\s+\+ trigger: true/, "and fly's diff is printed");
	unlike($said, qr/Dry-run mode was set/, "without fly's closing lines");
	unlink $dry;
};

subtest 'a pipeline Concourse would refuse is reported, not compared' => sub {
	# Three rows, and the run's own restoration assertion.
	plan tests => 4;

	mkfile_or_fail($invalid, "jobs.redeploy-qa.plan.do[0].on_error.get(run_qa-bosh): repeated name\n");
	mkfile_or_fail($dry, "no changes to apply\n");
	my ($said, $err, $exit) = run_genesis($h, 'pipeline-diff');
	$said = unfolded($said, $err);
	isnt($exit, 0, 'pipeline-diff fails');
	like($said, qr/repeated name/, "naming Concourse's error");
	unlike($said, qr/No differences/, 'and compares nothing');
	unlink $invalid, $dry;
};

subtest 'key order alone is no difference' => sub {
	# Three rows, and the run's own restoration assertion.
	plan tests => 4;

	mkfile_or_fail($live, to_yaml($compiled));
	my ($said, $err, $exit) = run_genesis($h, 'pipeline-diff');
	$said = unfolded($said, $err);
	is($exit, 0, 'pipeline-diff succeeds') or diag($err);
	like($said, qr/No differences/, 'and finds none in a reordered copy');
	like($said, qr/spruce/, 'a fly with no --dry-run is compared through spruce, saying so');
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
