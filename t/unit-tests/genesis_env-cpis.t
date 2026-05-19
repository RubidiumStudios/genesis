#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;

use Genesis;
$Genesis::VERSION = '999.999.999';
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");
use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Minimal env fixture; we stub manifest_lookup per-test to control
# the merged-manifest view directly.
sub make_env {
	my ($name) = @_;
	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');
	put_file($top->path("$name.yml"), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: $name
EOF
	return $top->load_env($name);
}

# ======================================================================
# instance_group_azs
# ======================================================================

subtest 'instance_group_azs - empty when no instance_groups' => sub {
	plan tests => 1;
	my $env = make_env('ig-none');

	no warnings qw(redefine once);
	local *Genesis::Env::manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return $default if $key eq 'instance_groups';
		return $default;
	};

	is_deeply [$env->instance_group_azs], [],
		'no instance_groups yields empty list';
};

subtest 'instance_group_azs - single group, one az' => sub {
	plan tests => 1;
	my $env = make_env('ig-single');

	no warnings qw(redefine once);
	local *Genesis::Env::manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return [{ name => 'api', azs => ['z1'] }]
			if $key eq 'instance_groups';
		return $default;
	};

	is_deeply [$env->instance_group_azs], ['z1'],
		'single az returned as a one-element list';
};

subtest 'instance_group_azs - overlapping azs across groups are deduped' => sub {
	plan tests => 1;
	my $env = make_env('ig-overlap');

	no warnings qw(redefine once);
	local *Genesis::Env::manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return [
			{ name => 'api',    azs => ['z1', 'z2'] },
			{ name => 'worker', azs => ['z2', 'z3'] },
			{ name => 'cache',  azs => ['z1'] },
		] if $key eq 'instance_groups';
		return $default;
	};

	is_deeply [$env->instance_group_azs], [qw(z1 z2 z3)],
		'overlapping azs are deduped and sorted';
};

subtest 'instance_group_azs - group with missing azs key is skipped' => sub {
	plan tests => 1;
	my $env = make_env('ig-noazs');

	no warnings qw(redefine once);
	local *Genesis::Env::manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return [
			{ name => 'errand' },                       # no azs at all
			{ name => 'api',    azs => ['z1', 'z2'] },
			{ name => 'empty',  azs => [] },            # empty array
		] if $key eq 'instance_groups';
		return $default;
	};

	is_deeply [$env->instance_group_azs], [qw(z1 z2)],
		'groups without azs contribute nothing; empty arrays also skipped';
};

subtest 'instance_group_azs - non-hash entries are tolerated' => sub {
	plan tests => 1;
	my $env = make_env('ig-junk');

	no warnings qw(redefine once);
	local *Genesis::Env::manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return [
			'literal-string',                       # bad entry
			{ name => 'api', azs => ['z1'] },
			undef,                                  # bad entry
		] if $key eq 'instance_groups';
		return $default;
	};

	is_deeply [$env->instance_group_azs], ['z1'],
		'non-hash entries are filtered out without erroring';
};

# ======================================================================
# needed_cpis
# ======================================================================

subtest 'needed_cpis - empty when no instance_groups' => sub {
	plan tests => 1;
	my $env = make_env('cc-none');

	no warnings qw(redefine once);
	local *Genesis::Env::manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return $default;
	};

	is_deeply [$env->needed_cpis], [],
		'no instance_groups yields empty needed_cpis';
};

subtest 'needed_cpis - maps used azs through cloud-config cpi field' => sub {
	plan tests => 1;
	my $env = make_env('cc-multi');

	no warnings qw(redefine once);
	local *Genesis::Env::manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return [
			{ name => 'api',    azs => ['z1', 'z2'] },
			{ name => 'worker', azs => ['z3'] },
		] if $key eq 'instance_groups';
		return [
			{ name => 'z1', cpi => 'vsphere-east' },
			{ name => 'z2', cpi => 'vsphere-east' },
			{ name => 'z3', cpi => 'aws-staging'  },
		] if $key eq 'azs';
		return $default;
	};

	is_deeply [$env->needed_cpis],
		[qw(aws-staging vsphere-east)],
		'needed_cpis are deduped and sorted CPI names from used azs';
};

subtest 'needed_cpis - az without cpi field maps to <default>' => sub {
	plan tests => 1;
	my $env = make_env('cc-default');

	no warnings qw(redefine once);
	local *Genesis::Env::manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return [{ name => 'api', azs => ['z1', 'z2'] }]
			if $key eq 'instance_groups';
		return [
			{ name => 'z1', cpi => 'aws-east' },
			{ name => 'z2' },   # no cpi -> falls back to director default
		] if $key eq 'azs';
		return $default;
	};

	is_deeply [$env->needed_cpis], ['<default>', 'aws-east'],
		'mixed env emits <default> sentinel for unpinned azs alongside named cpis';
};

subtest 'needed_cpis - az referenced but not in cloud-config is filtered out' => sub {
	plan tests => 1;
	my $env = make_env('cc-orphan');

	no warnings qw(redefine once);
	local *Genesis::Env::manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return [{ name => 'api', azs => ['z1', 'z9'] }]
			if $key eq 'instance_groups';
		return [{ name => 'z1', cpi => 'aws-east' }]
			if $key eq 'azs';
		return $default;
	};

	is_deeply [$env->needed_cpis], ['aws-east'],
		'azs not present in cloud-config yield no cpi entry';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
