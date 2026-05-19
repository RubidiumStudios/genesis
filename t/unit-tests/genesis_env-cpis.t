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

subtest 'needed_cpis - bails when az is not present in cloud-config' => sub {
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

	# Unresolvable AZs are a hard configuration error: BOSH can't
	# deploy a VM there, and we can't determine which CPI it would
	# need.  needed_cpis bails so the broken env can't slip past
	# preflight to fail later at deploy time.
	throws_ok { $env->needed_cpis }
		qr/z9.*not present in the cloud-config|cloud-config.*z9/is,
		'needed_cpis bails listing the unresolvable AZ';
};

# ======================================================================
# _check_cpis - validate $env->needed_cpis ⊆ $env->bosh->cpis
# ======================================================================
#
# Returns {state, msg} matching the shape Genesis::Env::check expects
# (parallel to _check_stemcells).  state is 'ok' or 'error'.  The
# '<default>' sentinel is always satisfied by any director.

# Lightweight fake bosh: lets each test specify the list of CPIs the
# (imagined) director has registered, plus an alias for the error
# message.
sub stub_bosh {
	my %opts = @_;
	my $cpis = $opts{cpis} // [];
	my $alias = $opts{alias} // 'mock-bosh';
	my $self = bless { _cpis => $cpis, _alias => $alias }, 'Test::Mock::Bosh';
	{
		no strict 'refs';
		no warnings 'redefine';
		*{'Test::Mock::Bosh::cpis'}  = sub { @{$_[0]->{_cpis}} };
		*{'Test::Mock::Bosh::alias'} = sub { $_[0]->{_alias} };
	}
	$self;
}

subtest '_check_cpis - create-env skips the check' => sub {
	plan tests => 2;
	my $env = make_env('chk-createenv');

	no warnings qw(redefine once);
	local *Genesis::Env::use_create_env = sub { 1 };
	# bosh should never be consulted in this branch
	local *Genesis::Env::bosh           = sub { die "bosh must not be queried for create-env" };

	my $result = $env->_check_cpis;
	is $result->{state}, 'ok', 'create-env skip => ok';
	like $result->{msg}, qr/create-env/i, 'message mentions create-env';
};

subtest '_check_cpis - no instance_groups => ok (nothing to check)' => sub {
	plan tests => 1;
	my $env = make_env('chk-noig');

	no warnings qw(redefine once);
	local *Genesis::Env::use_create_env = sub { 0 };
	local *Genesis::Env::needed_cpis    = sub { () };
	local *Genesis::Env::bosh           = sub { die "bosh must not be queried when needed_cpis is empty" };

	is $env->_check_cpis->{state}, 'ok',
		'no instance_groups => ok, bosh not queried';
};

subtest '_check_cpis - only <default> needed => ok (every director has default)' => sub {
	plan tests => 1;
	my $env = make_env('chk-default-only');

	no warnings qw(redefine once);
	local *Genesis::Env::use_create_env = sub { 0 };
	local *Genesis::Env::needed_cpis    = sub { ('<default>') };
	local *Genesis::Env::bosh           = sub { die "bosh must not be queried when only <default> is needed" };

	is $env->_check_cpis->{state}, 'ok',
		'<default>-only needs are always satisfied';
};

subtest '_check_cpis - all named cpis present => ok' => sub {
	plan tests => 2;
	my $env = make_env('chk-present');

	no warnings qw(redefine once);
	local *Genesis::Env::use_create_env = sub { 0 };
	local *Genesis::Env::needed_cpis    = sub { qw(aws-east vsphere-prod) };
	local *Genesis::Env::bosh           = sub {
		stub_bosh(cpis => [qw(aws-east aws-west vsphere-prod)]);
	};

	my $result = $env->_check_cpis;
	is $result->{state}, 'ok', 'all needed cpis present => ok';
	like $result->{msg}, qr/aws-east.*vsphere-prod|vsphere-prod.*aws-east/,
		'success message names the satisfied cpis';
};

subtest '_check_cpis - missing cpis => error' => sub {
	plan tests => 3;
	my $env = make_env('chk-missing');

	no warnings qw(redefine once);
	local *Genesis::Env::use_create_env = sub { 0 };
	local *Genesis::Env::needed_cpis    = sub { qw(aws-east vsphere-prod azure-gov) };
	local *Genesis::Env::bosh           = sub {
		stub_bosh(cpis => [qw(aws-east)], alias => 'prod-bosh');
	};

	my $result = $env->_check_cpis;
	is $result->{state}, 'error', 'missing cpis => error';
	like $result->{msg}, qr/vsphere-prod/, 'error message lists the missing vsphere-prod';
	like $result->{msg}, qr/azure-gov/,    'error message lists the missing azure-gov';
};

subtest '_check_cpis - mixed default + named: only named are checked' => sub {
	plan tests => 1;
	my $env = make_env('chk-mixed');

	no warnings qw(redefine once);
	local *Genesis::Env::use_create_env = sub { 0 };
	local *Genesis::Env::needed_cpis    = sub { ('<default>', 'aws-east') };
	local *Genesis::Env::bosh           = sub {
		stub_bosh(cpis => [qw(aws-east)]);
	};

	is $env->_check_cpis->{state}, 'ok',
		'named cpi present + <default> sentinel always satisfied => ok';
};

# ======================================================================
# _get_stemcell_status - multi-CPI fan-out
# ======================================================================
#
# Asserts that the loop emits one result per (stemcell, cpi) tuple
# when needed_cpis is multi-element, and a single result per stemcell
# when needed_cpis is empty (legacy fallback).  Inner found/alt
# branching is unchanged and is covered by integration paths.

sub mock_bosh_for_stemcell_status {
	my $self = bless { _stemcells => {}, _cpis => [] }, 'Test::Mock::Bosh2';
	{
		no strict 'refs';
		no warnings 'redefine';
		*{'Test::Mock::Bosh2::stemcells'} = sub { %{$_[0]->{_stemcells}} };
		*{'Test::Mock::Bosh2::cpis'}      = sub { @{$_[0]->{_cpis}} };
	}
	$self;
}

subtest '_get_stemcell_status - fans out per cpi when needed_cpis is multi' => sub {
	plan tests => 3;
	my $env = make_env('sc-fanout');

	no warnings qw(redefine once);
	# Two cpis demanded by the env's instance-group AZs
	local *Genesis::Env::needed_cpis = sub { ('cpi-a', 'cpi-b') };
	local *Genesis::Env::partial_manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return [{ alias => 'sc1', os => 'ubuntu', version => '1.0' }]
			if $key eq 'stemcells';
		return $default;
	};
	local *Genesis::Env::bosh = sub { mock_bosh_for_stemcell_status() };
	local *Genesis::Env::iaas = sub { 'mock-iaas' };
	# Avoid the Stemcell->find subprocess in the no-targets path
	require Service::BOSH::Stemcell;
	local *Service::BOSH::Stemcell::find = sub {
		{ os => 'ubuntu', version => '1.0-alt' };
	};

	my @results = $env->_get_stemcell_status(1);
	is scalar @results, 2,
		'1 stemcell entry x 2 cpis => 2 results';
	is $results[0]{cpi}, 'cpi-a',
		'first result tagged with first cpi';
	is $results[1]{cpi}, 'cpi-b',
		'second result tagged with second cpi';
};

subtest '_get_stemcell_status - falls back to single-cpi when needed_cpis is empty' => sub {
	plan tests => 2;
	my $env = make_env('sc-single');

	no warnings qw(redefine once);
	local *Genesis::Env::needed_cpis = sub { () };
	local *Genesis::Env::cpi_enabled = sub { 0 };
	local *Genesis::Env::partial_manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return [{ alias => 'sc1', os => 'ubuntu', version => '1.0' }]
			if $key eq 'stemcells';
		return $default;
	};
	local *Genesis::Env::bosh = sub { mock_bosh_for_stemcell_status() };
	local *Genesis::Env::iaas = sub { 'mock-iaas' };
	require Service::BOSH::Stemcell;
	local *Service::BOSH::Stemcell::find = sub { { os => 'ubuntu', version => '1.0-alt' } };

	my @results = $env->_get_stemcell_status(1);
	is scalar @results, 1,
		'1 stemcell, empty needed_cpis => 1 result (legacy single-cpi path)';
	is $results[0]{cpi}, '<default>',
		'fallback cpi is <default> when cpi_enabled is false';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
