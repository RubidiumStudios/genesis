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

# Build a director object without spawning a real bosh.  Caller stubs
# execute() per test to count BOSH round-trips and supply fixtures.
sub make_director {
	require Service::Vault::Local;
	my $stub_vault = bless { _name => 'stub' }, 'Service::Vault::Local';
	Service::BOSH::Director->new(
		'configs-test',
		url          => 'https://127.0.0.1',
		ca_cert      => 'ca',
		client       => 'admin',
		secret       => 'pw',
		exodus_path  => 'secret/exodus/configs-test/bosh',
		exodus_vault => $stub_vault,
	);
}

# Compact JSON fixture matching what `bosh configs -r=99999 --json`
# returns (one row per config version).  Two cpi configs (one with a
# previous version), one cloud, one runtime.
sub configs_fixture_json {
	return <<'JSON';
{
  "Tables": [
    {
      "Rows": [
        { "id": "5*",  "type": "cpi",     "name": "aws-bundle",  "created_at": "2026-05-19T10:00:00Z", "team": "" },
        { "id": "3",   "type": "cpi",     "name": "aws-bundle",  "created_at": "2026-05-10T10:00:00Z", "team": "" },
        { "id": "7*",  "type": "cpi",     "name": "vsphere-prod","created_at": "2026-05-19T10:00:00Z", "team": "" },
        { "id": "11*", "type": "cloud",   "name": "default",     "created_at": "2026-05-19T10:00:00Z", "team": "" },
        { "id": "12*", "type": "runtime", "name": "default",     "created_at": "2026-05-19T10:00:00Z", "team": "" }
      ]
    }
  ]
}
JSON
}

# ======================================================================
# configs() memoization
# ======================================================================
#
# Contract: configs() does at most one BOSH round-trip per director
# object across N invocations.  Subsequent callers reuse the cached
# listing.  `refresh => 1` forces a fresh fetch.  This is the
# foundation for the cheap helpers below -- without memoization,
# layering cheap derivations on top is pointless.

subtest 'configs - first call hits BOSH, subsequent calls return cached' => sub {
	plan tests => 3;
	my $d = make_director();
	my $execute_calls = 0;

	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub {
		$execute_calls++;
		return configs_fixture_json();
	};

	my $first  = $d->configs;
	my $second = $d->configs;
	my $third  = $d->configs;

	is $execute_calls, 1,
		'configs() runs `bosh configs` exactly once across 3 calls';
	is_deeply $second, $first,
		'second call returns the same data as the first';
	is_deeply $third,  $first,
		'third call returns the same data as the first';
};

subtest 'configs - refresh=>1 invalidates the cache' => sub {
	plan tests => 1;
	my $d = make_director();
	my $execute_calls = 0;

	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub {
		$execute_calls++;
		return configs_fixture_json();
	};

	$d->configs;
	$d->configs;
	$d->configs(refresh => 1);
	$d->configs;

	is $execute_calls, 2,
		'refresh=>1 forces a re-fetch; subsequent calls reuse the new cache';
};

subtest 'configs - parses the listing shape correctly' => sub {
	plan tests => 4;
	my $d = make_director();
	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub { configs_fixture_json() };

	my $c = $d->configs;
	is $c->{cpi}{'aws-bundle'}{current}, 5,
		'current id for aws-bundle is 5 (the entry marked with *)';
	ok exists($c->{cpi}{'aws-bundle'}{entries}{3}),
		'historical entry id 3 is preserved in entries';
	is $c->{cloud}{default}{current}, 11,
		'current id for cloud/default is 11';
	is $c->{runtime}{default}{current}, 12,
		'current id for runtime/default is 12';
};

# ======================================================================
# has_config_of_type - cheap "do any of these exist?" query
# ======================================================================
#
# Contract: derived purely from the cached configs() listing -- no
# additional BOSH round-trip.  True when at least one config of
# $type has been uploaded.

subtest 'has_config_of_type - true when configs exist, false when not' => sub {
	plan tests => 5;
	my $d = make_director();
	my $execute_calls = 0;
	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub {
		$execute_calls++;
		return configs_fixture_json();
	};

	ok  $d->has_config_of_type('cpi'),     'cpi configs are present';
	ok  $d->has_config_of_type('cloud'),   'cloud config is present';
	ok  $d->has_config_of_type('runtime'), 'runtime config is present';
	ok !$d->has_config_of_type('bogus'),   'unknown type returns false';

	# All four calls above should have used the same cached listing.
	is $execute_calls, 1,
		'4 has_config_of_type calls share 1 underlying BOSH fetch';
};

subtest 'has_config_of_type - undef type returns false safely' => sub {
	plan tests => 1;
	my $d = make_director();
	no warnings qw(redefine once);
	# Should not even consult the cache.
	local *Service::BOSH::Director::execute = sub { die "execute must not be called for undef type" };

	ok !$d->has_config_of_type(undef),
		'undef type returns false without consulting BOSH';
};

# ======================================================================
# config_names_of - sorted list of CONFIG names for a type
# ======================================================================
#
# These are BOSH `--name=` values (cpi config names), not the cpi-
# names appearing inside the cpis[] array of a cpi-config.  See
# memory:reference-bosh-cpi-terminology -- keeping the distinction
# is load-bearing.

subtest 'config_names_of - returns sorted config names from cache' => sub {
	plan tests => 4;
	my $d = make_director();
	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub { configs_fixture_json() };

	is_deeply [$d->config_names_of('cpi')],
		[qw(aws-bundle vsphere-prod)],
		'cpi config names returned sorted';
	is_deeply [$d->config_names_of('cloud')],
		['default'],
		'cloud config name is the literal "default"';
	is_deeply [$d->config_names_of('runtime')],
		['default'],
		'runtime config name is the literal "default"';
	is_deeply [$d->config_names_of('bogus')],
		[],
		'unknown type returns empty list';
};

# ======================================================================
# has_config - specific (type, name) presence check
# ======================================================================
#
# Replaces the old per-call `bosh configs -r=1 --type=X --name=Y`
# round-trip with a hash lookup against the cached listing.

subtest 'has_config - derived from cached listing, no per-call fetch' => sub {
	plan tests => 6;
	my $d = make_director();
	my $execute_calls = 0;
	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub {
		$execute_calls++;
		return configs_fixture_json();
	};

	ok  $d->has_config('cpi',     'aws-bundle'),    'aws-bundle exists';
	ok  $d->has_config('cpi',     'vsphere-prod'),  'vsphere-prod exists';
	ok  $d->has_config('cloud',   'default'),       'cloud/default exists';
	ok !$d->has_config('cpi',     'azure-gov'),     'unknown cpi name returns false';
	ok !$d->has_config('weird',   'default'),       'unknown type returns false';

	is $execute_calls, 1,
		'5 has_config calls share 1 underlying BOSH fetch';
};

subtest 'has_config - requires a current entry, not just historical' => sub {
	plan tests => 2;
	my $d = make_director();
	no warnings qw(redefine once);
	# Fixture: a deleted (no `*`) cpi config -- only historical
	# entries, no current.  Mirrors what BOSH returns when the
	# active version was deleted and only history remains.
	local *Service::BOSH::Director::execute = sub {
		return <<'JSON';
{
  "Tables": [
    {
      "Rows": [
        { "id": "1", "type": "cpi", "name": "stale", "created_at": "2024-01-01T00:00:00Z", "team": "" }
      ]
    }
  ]
}
JSON
	};

	ok !$d->has_config('cpi', 'stale'),
		'config with only historical entries (no current *) is not "has_config"';
	is_deeply [$d->config_names_of('cpi')], ['stale'],
		'config_names_of still reports it -- the row exists, just not currently active';
};

# ======================================================================
# cpis() reuses the cached configs listing
# ======================================================================
#
# After Step 1, Director::cpis() should no longer trigger an extra
# `bosh configs` fetch on top of what configs() already does.  This
# locks in the invariant before Step 2 (get_config memoization).

subtest 'cpis - shares the cached configs listing' => sub {
	plan tests => 2;
	my $d = make_director();
	my $execute_calls = 0;
	my @execute_args;
	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub {
		shift;  # discard $self
		shift if ref($_[0]) eq 'HASH';  # discard opts hashref
		push @execute_args, [@_];
		$execute_calls++;
		# Differentiate listing fetch vs content fetch by the first arg.
		if ($_[0] eq 'configs') {
			return configs_fixture_json();
		}
		# 'config' (single) -- minimal cpi yaml for both cpi configs.
		return <<'JSON';
{
  "Tables": [
    { "Rows": [ { "content": "cpis:\n- name: ${PWD}cpi\n  type: aws\n  properties: {}\n" } ] }
  ]
}
JSON
	};

	$d->configs;     # primes the cache via the configs() listing call
	$d->cpis;        # would have re-listed pre-refactor; now reuses cache

	my @listing_calls = grep { $_->[0] eq 'configs' } @execute_args;
	is scalar(@listing_calls), 1,
		'cpis() does not trigger a second `bosh configs` listing call';
	# Sanity: we did still hit `bosh config` for the contents.
	my @content_calls = grep { $_->[0] eq 'config' } @execute_args;
	cmp_ok scalar(@content_calls), '>=', 1,
		'cpis() does fetch cpi-config contents (one or more `bosh config` calls)';
};

# ======================================================================
# get_config() memoization
# ======================================================================
#
# Contract: get_config($type, $name) caches content per (type, name)
# pair.  A second call for the same pair returns the cached content
# without a second BOSH round-trip.  Distinct pairs are independent
# cache slots.

subtest 'get_config - memoizes per (type, name) pair' => sub {
	plan tests => 4;
	my $d = make_director();
	my %content_calls;  # by "type|name"
	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub {
		shift;  # $self
		shift if ref($_[0]) eq 'HASH';  # opts
		# 'config --type=X --name=Y --json'
		my %args = @_[1..$#_];
		my $type = $args{'--type'} // ($_[0] =~ /--type=(\S+)/ ? $1 : '?');
		my $name = $args{'--name'} // ($_[0] =~ /--name=(\S+)/ ? $1 : '?');
		# Reconstruct from positional arg list: parse the strings
		for my $a (@_) {
			$type = $1 if $a =~ /^--type=(.+)/;
			$name = $1 if $a =~ /^--name=(.+)/;
		}
		$content_calls{"$type|$name"}++;
		return qq({"Tables":[{"Rows":[{"content":"---\\ncontent-of-$type-$name\\n"}]}]});
	};

	my $first  = $d->get_config('cpi', 'aws-bundle');
	my $second = $d->get_config('cpi', 'aws-bundle');
	my $other  = $d->get_config('cpi', 'vsphere-prod');
	$d->get_config('cpi', 'vsphere-prod');

	is $content_calls{'cpi|aws-bundle'}, 1,
		'repeat (cpi, aws-bundle) fetch uses cache (1 execute)';
	is $content_calls{'cpi|vsphere-prod'}, 1,
		'distinct (cpi, vsphere-prod) is an independent cache slot (1 execute)';
	is $second, $first,
		'cached call returns the same content as the first';
	like $other, qr/vsphere-prod/,
		'distinct pair gets its own content';
};

subtest 'get_config - refresh=>1 invalidates the per-pair cache' => sub {
	plan tests => 1;
	my $d = make_director();
	my $execute_calls = 0;
	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub {
		$execute_calls++;
		return qq({"Tables":[{"Rows":[{"content":"---\\nfresh\\n"}]}]});
	};

	$d->get_config('cpi', 'aws-bundle');
	$d->get_config('cpi', 'aws-bundle');
	$d->get_config('cpi', 'aws-bundle', refresh => 1);
	$d->get_config('cpi', 'aws-bundle');

	is $execute_calls, 2,
		'refresh=>1 on get_config forces one re-fetch; subsequent calls reuse';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
