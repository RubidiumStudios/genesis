#!/usr/bin/env perl
# Proves T465: an operator's own pipeline fragment, .genesis/pipeline-overrides-
# concourse.yml, reaches the pipeline pipeline-apply sets.  The override adds a
# job and patches a generated resource by name, spruce merging lists of named
# maps by name; the dry apply prints both, fly would accept the result, and
# the file the real apply hands fly set-pipeline carries both.
#
# What the rows catch: a fragment the compiler merges in its own tests but the
# command that sets the pipeline drops, which no row ran end to end; v2's
# ci.yml carried such content outside its pipeline key, and the override file
# is where it now goes.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Harness::Contract;

use Test::More;

use Genesis qw/mkfile_or_fail mkdir_or_fail slurp/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $OVERRIDE = join("\n",
	'---',
	'resources:',
	'- name: control-branch',
	'  check_every: 30s',
	'jobs:',
	'- name: operator-smoke',
	'  plan:',
	'  - get: control-branch',
	'');

# Beside the root's own .genesis/config, which for the contract harness is a
# subdirectory of the clone.
sub with_override {
	my ($h, $root) = @_;
	my $at = defined $root ? "$root/" : '';
	commit_on_control($h,
		files   => {"$at.genesis/pipeline-overrides-concourse.yml" => $OVERRIDE},
		message => 'Add an operator pipeline fragment',
		push    => 1);
	return $h;
}

subtest 'the dry apply prints the fragment merged in' => sub {
	my $h = with_override(contract_harness(), $Harness::Contract::ROOT);
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	my $res = pipeline_resource($p, 'control-branch') || {};
	is($res->{check_every}, '30s', 'a generated resource patched by name');
	ok($res->{source} && $res->{source}{branch}, 'keeping what the compiler gave it');
	ok(pipeline_job($p, 'operator-smoke'), 'and a job of the operator\'s own added');
	ok(pipeline_job($p, 'propagate'), 'beside the generated jobs');
};

subtest 'the real apply hands fly the merged pipeline' => sub {
	my $log  = "$ENV{HOME}/fly.log";
	my $kept = "$ENV{HOME}/set-pipeline.yml";
	mkdir_or_fail("$ENV{HOME}/bin") unless -d "$ENV{HOME}/bin";
	local $ENV{GENESIS_FLY_BIN} = "$ENV{HOME}/bin/fly";
	mkfile_or_fail("$ENV{HOME}/.flyrc",
		"targets:\n  harness-main:\n    api: https://ci.harness.example\n    team: main\n");
	# Logs its calls, answers a version and a dry run, and keeps the file a
	# real set-pipeline is handed, since the apply removes its own copy.
	mkfile_or_fail("$ENV{HOME}/bin/fly", 0755, join("\n",
		'#!/bin/sh',
		"echo \"\$*\" >> '$log'",
		'case "$*" in *--version*) echo 7.11.0; exit 0;; esac',
		'case "$*" in *--dry-run*) echo "jobs:"; echo "  job operator-smoke has been added:"; exit 0;; esac',
		'case "$*" in *set-pipeline*)',
		'  while [ $# -gt 0 ]; do [ "$1" = "-c" ] && cp "$2" '."'$kept'".'; shift; done;;',
		'esac',
		'exit 0', ''));

	my $h = with_override(make_harness(envs => ['qa'], provider => 'concourse'));
	my (undef, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply', '-y');
	is($exit, 0, 'the apply succeeds') or diag($err);
	ok(-f $kept, 'fly set-pipeline was handed a file') or return;
	my $set = slurp($kept);
	like($set, qr/check_every:\s*30s/, 'carrying the patched resource');
	like($set, qr/name:\s*operator-smoke/, 'and the operator\'s job');
};

done_testing;
