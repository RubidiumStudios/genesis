#!perl
# Proves T370 through the commands an operator types: the fly target is
# found where fly is needed, the apply asks for it before it writes anything,
# pipeline-describe says how it was found, and no task in the emitted
# pipeline runs fly (D86, noted 2026-10-15).
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

use Genesis qw/mkfile_or_fail mkdir_or_fail slurp/;
use Genesis::Exit qw/CONFIG/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# The harness names its Concourse https://ci.harness.example, team main.  A
# fly that logs its arguments stands in for the real one, so a command that
# would reach Concourse reaches nothing.
my $log = "$ENV{HOME}/fly.log";
mkdir_or_fail("$ENV{HOME}/bin");
mkfile_or_fail("$ENV{HOME}/bin/fly", 0755,
	"#!/bin/sh\necho \"\$*\" >> '$log'\ncase \"\$*\" in *--version*) echo 7.11.0;; esac\n");
$ENV{GENESIS_FLY_BIN} = "$ENV{HOME}/bin/fly";

sub flyrc {
	my (%targets) = @_;
	mkfile_or_fail("$ENV{HOME}/.flyrc", "targets:\n" . join('', map {
		"  $_:\n    api: $targets{$_}{api}\n    team: $targets{$_}{team}\n"
	} sort keys %targets));
}

my $elsewhere = {api => 'https://other.example.com', team => 'main'};
my $harness   = {api => 'https://ci.harness.example', team => 'main'};

subtest 'the apply asks for the target before it writes anything' => sub {
	# Three explicit rows and one for the run's restoration assertion.
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	flyrc(other => $elsewhere);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '-y');
	my $said = unfolded($out, $err);
	is($exit, CONFIG, 'the apply is refused at CONFIG') or diag($said);
	like($said, qr/fly login -t \S+ -c https:\/\/ci\.harness\.example -n main/,
		'with the login that makes a target');
	is(ref_in($h->r, $h->slug('qa')), undef, 'before any deployment branch is cut');
};

subtest 'pipeline-describe says how the target was found' => sub {
	# Two explicit rows and one for the run's restoration assertion.
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	flyrc(other => $elsewhere, 'harness-main' => $harness);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-describe');
	my $said = unfolded($out, $err);
	like($said, qr/harness-main/, 'naming the target') or diag($said);
	like($said, qr/\bmatched\b/, 'and that it was matched in ~/.flyrc');
};

subtest 'a pause with no target to find is refused, not given the pipeline name' => sub {
	# Three explicit rows and one for the run's restoration assertion.
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	flyrc(other => $elsewhere);
	unlink $log;

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-pause');
	my $said = unfolded($out, $err);
	is($exit, CONFIG, 'the pause is refused at CONFIG') or diag($said);
	like($said, qr/fly login -t \S+ -c https:\/\/ci\.harness\.example -n main/,
		'with the login that makes a target');
	my $calls = -f $log ? slurp($log) : '';
	unlike($calls, qr/pause-pipeline/, 'and fly was never asked to pause anything');
};

subtest 'no task in the emitted pipeline runs fly' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], provider => 'concourse', vault => 0);
	my $top = load_with($h, automated_config('concourse',
		'url: https://ci.example.com', 'team: main'));
	require Genesis::CI::Compiler;
	my $result = Genesis::CI::Compiler->new(top => $top)->compile(provider => 'concourse');
	my $emitted = join("\n", map {$_ // ''} values %{$result->{output} || {}});

	ok(length $emitted, 'the pipeline compiled') or diag(explain([keys %{$result->{output} || {}}]));
	unlike($emitted, qr/(?:^|[\s"'])fly\s+(?:-t|login|set-pipeline|pause|unpause|trigger|execute)\b/m,
		'and nothing in it runs fly, so no job needs a target');
};

done_testing;
