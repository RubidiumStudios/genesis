#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;

use_ok "Service::BOSH::Director";
use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Build a Service::BOSH::Director without spawning a real bosh or
# touching the user's safe target — caller stubs the methods we
# exercise (exodus / configs / get_config) per test.
sub make_director {
	# Override the constructor's default exodus_vault fallback so we
	# don't hit `safe target --json` against the user's real saferc.
	require Service::Vault::Local;
	my $stub_vault = bless { _name => 'stub' }, 'Service::Vault::Local';
	Service::BOSH::Director->new(
		'cpis-test',
		url          => 'https://127.0.0.1',
		ca_cert      => 'ca',
		client       => 'admin',
		secret       => 'pw',
		exodus_path  => 'secret/exodus/cpis-test/bosh',
		exodus_vault => $stub_vault,
	);
}

# ======================================================================
# cpis - always live-queries the director, memoizes per-instance
# ======================================================================

subtest 'cpis - extracts names from cpi-config YAML' => sub {
	plan tests => 1;
	my $d = make_director();

	no warnings qw(redefine once);
	local *Service::BOSH::Director::configs = sub {
		{ cpi => { default => { current => 1, entries => { 1 => {} } } } };
	};
	local *Service::BOSH::Director::get_config = sub {
		my ($self, $type, $name) = @_;
		return <<'YAML' if $type eq 'cpi' && $name eq 'default';
---
cpis:
- name: vsphere-prod
  type: vsphere
  properties: {}
- name: aws-prod
  type: aws
  properties: {}
YAML
		return undef;
	};

	is_deeply [$d->cpis],
		[qw(aws-prod vsphere-prod)],
		'live query extracts cpi names from cpi-config YAML content';
};

subtest 'cpis - memoizes across calls, refresh=>1 invalidates' => sub {
	plan tests => 3;
	my $d = make_director();
	my $configs_calls = 0;

	# First fixture
	no warnings qw(redefine once);
	local *Service::BOSH::Director::configs = sub {
		$configs_calls++;
		{ cpi => { default => {} } };
	};
	local *Service::BOSH::Director::get_config = sub { "cpis: [{name: alpha, type: vsphere, properties: {}}]" };

	is_deeply [$d->cpis], ['alpha'], 'first call returns alpha';
	is_deeply [$d->cpis], ['alpha'], 'second call returns alpha (memoized)';
	is $configs_calls, 1, 'configs() invoked only once across two cpis() calls';
};

subtest 'cpis - refresh=>1 forces re-query after upload changes' => sub {
	plan tests => 3;
	my $d = make_director();

	# Two-phase fixture: first call returns alpha; later calls return alpha+beta.
	my $configs_calls = 0;
	my @phases = (
		sub { { cpi => { default => {} } } },
		sub { { cpi => { default => {}, secondary => {} } } },
	);
	no warnings qw(redefine once);
	local *Service::BOSH::Director::configs = sub {
		$configs_calls++;
		($phases[$configs_calls - 1] // $phases[-1])->();
	};
	local *Service::BOSH::Director::get_config = sub {
		my ($self, $type, $name) = @_;
		return "cpis: [{name: alpha, type: vsphere, properties: {}}]" if $name eq 'default';
		return "cpis: [{name: beta,  type: aws,     properties: {}}]" if $name eq 'secondary';
		undef;
	};

	is_deeply [$d->cpis], ['alpha'], 'first call: only alpha';
	is_deeply [$d->cpis], ['alpha'], 'memoized: still alpha despite director state changing';
	is_deeply [$d->cpis(refresh => 1)], [qw(alpha beta)],
		'refresh=>1 invalidates and re-queries — both cpis appear';
};

subtest 'cpis - live query aggregates across multiple cpi-config slots' => sub {
	plan tests => 1;
	my $d = make_director();
	no warnings qw(redefine once);
	local *Service::BOSH::Director::exodus  = sub { {} };
	local *Service::BOSH::Director::configs = sub {
		{ cpi => { default => {}, secondary => {} } };
	};
	local *Service::BOSH::Director::get_config = sub {
		my ($self, $type, $name) = @_;
		return <<'YAML' if $name eq 'default';
---
cpis:
- {name: vsphere-prod, type: vsphere, properties: {}}
YAML
		return <<'YAML' if $name eq 'secondary';
---
cpis:
- {name: aws-prod, type: aws, properties: {}}
YAML
		return undef;
	};

	is_deeply [$d->cpis],
		[qw(aws-prod vsphere-prod)],
		'cpi names from all cpi-typed configs are aggregated';
};

subtest 'cpis - malformed cpi-config YAML is tolerated' => sub {
	plan tests => 1;
	my $d = make_director();
	no warnings qw(redefine once);
	local *Service::BOSH::Director::exodus  = sub { {} };
	local *Service::BOSH::Director::configs = sub {
		{ cpi => { default => {}, broken => {} } };
	};
	local *Service::BOSH::Director::get_config = sub {
		my ($self, $type, $name) = @_;
		return <<'YAML' if $name eq 'default';
---
cpis:
- {name: vsphere-prod, type: vsphere, properties: {}}
YAML
		return "this is not yaml >>><<<" if $name eq 'broken';
		return undef;
	};

	is_deeply [$d->cpis],
		[qw(vsphere-prod)],
		'broken config is skipped without erroring the whole call';
};

subtest 'cpis - empty director (no cpi configs at all) returns empty list' => sub {
	plan tests => 1;
	my $d = make_director();
	no warnings qw(redefine once);
	local *Service::BOSH::Director::exodus  = sub { {} };
	local *Service::BOSH::Director::configs = sub { {} };

	is_deeply [$d->cpis], [],
		'no cpi-configs on the director -> empty list';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
