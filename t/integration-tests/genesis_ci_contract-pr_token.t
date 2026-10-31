#!/usr/bin/env perl
# Proves T460 (contract f8; D27's note of 2026-10-18; D55, D57): where an
# environment in scope delivers by pull request, the propagate task carries
# GITHUB_AUTH_TOKEN, from pipeline.source_control.api_token where it is set,
# else from the https clone credential's password; an ssh clone credential
# with no api_token is refused at compile, naming the key; and a pipeline with
# no such environment carries no token at all.
#
# What the rows catch: the lmelt PoC's pull request test meeting a propagate
# task that cannot open a pull request, which every pipeline compiled before
# this row did, and a token handed to a task that has no use for it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Harness::Contract;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub propagate_params {
	my ($p) = @_;
	my $job  = pipeline_job($p, 'propagate') || {};
	my $task = (grep {$_->{task}} plan_steps($job->{plan}))[0] || {};
	return $task->{config}{params} || {};
}

subtest 'f8: the api_token, where a pull request environment is in scope' => sub {
	my $h = contract_harness(pipeline => {require_pr => 'true'},
		config => {'pipeline.source_control.api_token' => 'ci/github:token'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	is(propagate_params($p)->{GITHUB_AUTH_TOKEN}, '((ci/github.token))',
		'propagate carries the token, as a Concourse reference');
};

subtest 'f8: no token where no environment delivers by pull request' => sub {
	my $h = contract_harness(
		config => {'pipeline.source_control.api_token' => 'ci/github:token'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	ok(!exists propagate_params($p)->{GITHUB_AUTH_TOKEN}, 'propagate carries none');
};

subtest 'f8: an ssh clone with no api_token is refused' => sub {
	my $h = contract_harness(pipeline => {require_pr => 'true'});
	my ($p, $why) = dry_pipeline($h);
	ok(!$p, 'the dry apply refuses') or return;
	like($why, qr/^exit 78\b/, 'at CONFIG');
	like($why, qr/pipeline\.source_control\.api_token/, 'naming the key to set');
	like($why, qr/\bqa\b/, 'and the environment that delivers by pull request');
};

done_testing;
