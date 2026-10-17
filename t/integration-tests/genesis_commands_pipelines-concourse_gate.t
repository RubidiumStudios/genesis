#!/usr/bin/env perl
# Proves T386: the commands that work a live Concourse pipeline refuse what is
# not one before they compile.  pipeline-diff, pipeline-jobs, pipeline-pause
# and pipeline-resume compiled for Concourse whatever the configuration said,
# which put a manual, disabled or cyclic pipeline in front of the compiler's
# own refusals.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my @LIVE = (['pipeline-jobs'], ['pipeline-pause'], ['pipeline-resume']);

sub refused_before_compile {
	my ($h, $argv, $why, $label) = @_;
	my (undef, $err, $exit) = run_genesis($h, @$argv);
	my $said = unfolded($err);
	is($exit, Genesis::Exit::CONFIG, "`genesis @$argv` refuses at CONFIG, $label") or diag($err);
	like($said, $why, 'saying why');
	unlike($said, qr/Parsing pipeline configuration/, 'before it compiles');
}

subtest 'a manual pipeline is not a Concourse one' => sub {
	# Three rows per command, and one restoration assertion for each run.
	plan tests => 16;
	my $h = make_harness(envs => ['qa'], provider => 'manual', vault => 0);
	refused_before_compile($h, $_, qr/provider is manual/i, 'under the manual provider')
		for ['pipeline-diff'], @LIVE;
};

subtest 'a disabled pipeline has nothing live to work' => sub {
	# Three rows per command, and one restoration assertion for each run.
	plan tests => 12;
	my $h = make_harness(envs => ['qa'], provider => 'concourse', pipeline => 0, vault => 0);
	refused_before_compile($h, $_, qr/not enabled/i, 'with the pipeline off')
		for @LIVE;
};

subtest 'a prior_env cycle is refused by name' => sub {
	# Three rows, and the run's own restoration assertion.
	plan tests => 4;
	my $h = make_harness(envs => ['lab', 'qa'], provider => 'concourse', vault => 0);
	write_env_file($h, 'lab', pipeline => {prior_env => 'qa'}, commit => 0);
	write_env_file($h, 'qa',  pipeline => {prior_env => 'lab'}, commit => 0);
	refused_before_compile($h, ['pipeline-diff'], qr/prior_env forms a cycle/, 'over a cycle');
};

done_testing;
