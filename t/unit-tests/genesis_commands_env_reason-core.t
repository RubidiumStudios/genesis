#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';

use Test::More;

use_ok 'Genesis::Commands::Env';

# Pure-function tests for _format_pipeline_reason.  The callbacks are
# stubs — no git or vault involved.

my $short = sub { substr($_[0], 0, 7) };
my $subjects = {
	'a1b2c3d4e5f6' => 'Refactor bosh envs to hierarchical config',
	'b2c3d4e5f6a1' => 'Move cloud-config into bosh/ and declare as required_files',
	'c3d4e5f6a1b2' => 'Use GENESIS_CALLBACK_BIN for in-script genesis calls',
};
my $subject_of = sub { $subjects->{$_[0]} // '' };

subtest 'no propagation markers returns undef' => sub {
	is(
		Genesis::Commands::Env::_format_pipeline_reason(
			['h1 First commit', 'h2 Second commit'],
			$short, $subject_of,
		),
		undef,
	);
};

subtest 'empty input returns undef' => sub {
	is(
		Genesis::Commands::Env::_format_pipeline_reason([], $short, $subject_of),
		undef,
	);
	is(
		Genesis::Commands::Env::_format_pipeline_reason(undef, $short, $subject_of),
		undef,
	);
};

subtest 'single propagation marker: subject only, no SHA prefix' => sub {
	# git log is newest-first
	my @log = (
		'env_sha1 [pipeline] control@a1b2c3d4e5f6 -> lmelt-vsphere-canwest-1-mgmt',
	);
	my $got = Genesis::Commands::Env::_format_pipeline_reason(\@log, $short, $subject_of);
	is($got, 'Refactor bosh envs to hierarchical config');
};

subtest 'multi-commit: count header + bulleted subjects, oldest-first' => sub {
	# log is newest-first — reason should reverse to oldest-first
	my @log = (
		'env_sha3 [pipeline] control@c3d4e5f6a1b2 -> lmelt-vsphere-canwest-1-mgmt',
		'env_sha2 [pipeline] control@b2c3d4e5f6a1 -> lmelt-vsphere-canwest-1-mgmt',
		'env_sha1 [pipeline] control@a1b2c3d4e5f6 -> lmelt-vsphere-canwest-1-mgmt',
	);
	my $got = Genesis::Commands::Env::_format_pipeline_reason(\@log, $short, $subject_of);
	is($got, join("\n",
		'3 commits:',
		'  - Refactor bosh envs to hierarchical config',
		'  - Move cloud-config into bosh/ and declare as required_files',
		'  - Use GENESIS_CALLBACK_BIN for in-script genesis calls',
	));
};

subtest 'non-marker lines are skipped' => sub {
	my @log = (
		'env_sha2 [pipeline] control@b2c3d4e5f6a1 -> lmelt-vsphere-canwest-1-mgmt',
		'env_sha1b Hotfix on env branch',
		'env_sha1 [pipeline] control@a1b2c3d4e5f6 -> lmelt-vsphere-canwest-1-mgmt',
	);
	my $got = Genesis::Commands::Env::_format_pipeline_reason(\@log, $short, $subject_of);
	is($got, join("\n",
		'2 commits:',
		'  - Refactor bosh envs to hierarchical config',
		'  - Move cloud-config into bosh/ and declare as required_files',
	));
};

done_testing;
