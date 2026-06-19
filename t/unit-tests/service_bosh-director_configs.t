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
		shift if ref($_[0]) eq 'HASH';  # opts (--type/--name live in @cmd)
		my ($type, $name) = ('?', '?');
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

# ======================================================================
# download_configs() - cache-aware bulk fetch + per-call file copy
# ======================================================================
#
# Contract (Step 3): the existing download_configs($path, $type, $name,
# %opts) API stays source-compatible.  Internals are rewired to use
# the cached listing (Step 1) for name resolution and the memoized
# get_config (Step 2) for content.  The assembled output is cached
# in a director-scoped workdir path; subsequent calls for the same
# (type, name) reuse the cache and just copy the file into the
# caller-supplied $path.
#
# Step 3 also introduces `optional => 1`: when no configs of the
# requested type exist, return an empty list instead of bailing.
# Required for cpi-config prefetch on single-iaas envs where no
# named cpi-configs are uploaded.

subtest 'download_configs - repeat call reuses cached content, copies to new path' => sub {
	plan tests => 5;
	my $d = make_director();
	my %execute_calls;  # by first arg of execute()
	# Mutated between the first and second call so we can prove the
	# second result came from the cache, not from a fresh fetch.  A
	# correct cache returns 'body-A' from the second call too; a
	# broken cache (re-fetch) would return 'body-B'.
	my $body = 'body-A';

	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub {
		shift;  # $self
		shift if ref($_[0]) eq 'HASH';  # opts
		my $first_arg = $_[0] // '';
		$execute_calls{$first_arg}++;
		if ($first_arg eq 'configs') {
			return configs_fixture_json();
		}
		return qq({"Tables":[{"Rows":[{"content":"---\\n$body\\n"}]}]});
	};

	my $first_path  = workdir().'/dl-first.yml';
	my $second_path = workdir().'/dl-second.yml';

	my @first = $d->download_configs($first_path,  'cpi', 'aws-bundle');
	# Mutate the source-of-truth.  If the cache is honoured, the
	# second call returns the original body.  If it's broken and
	# re-fetches, the file will contain the new body instead.
	$body = 'body-B';
	my @second = $d->download_configs($second_path, 'cpi', 'aws-bundle');

	ok -s $first_path,  'first call writes the requested file';
	ok -s $second_path, 'second call writes the new requested file';
	is $execute_calls{config}, 1,
		'content fetched once across both calls (memoized via get_config)';
	is_deeply [sort map { $_->{name} } @second], [sort map { $_->{name} } @first],
		'second call returns the same @configs info shape';

	my $c2 = do { local $/; open my $fh, '<', $second_path; <$fh> };
	like $c2, qr/body-A/,
		'second file carries the ORIGINAL body (cache hit), not the post-mutation body';
};

subtest 'download_configs - optional=>1 returns empty list when no configs of $type exist' => sub {
	plan tests => 3;
	my $d = make_director();

	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub {
		shift; shift if ref($_[0]) eq 'HASH';
		# Listing has cloud + runtime but NO cpi configs -- the
		# single-iaas env case for which optional was introduced.
		if (($_[0] // '') eq 'configs') {
			return <<'JSON';
{"Tables":[{"Rows":[
{"id":"1*","type":"cloud","name":"default","team":"","created_at":"2026-05-19T10:00:00Z"},
{"id":"2*","type":"runtime","name":"default","team":"","created_at":"2026-05-19T10:00:00Z"}
]}]}
JSON
		}
		die "content fetch must not be attempted when no configs of \$type exist";
	};

	my $target = workdir().'/optional-cpi.yml';
	my @result = $d->download_configs($target, 'cpi', '*', optional => 1);

	is scalar(@result), 0,
		'optional=>1 + no configs of this type => empty list';
	ok ! -e $target,
		'no file written when there were no configs to download';
	# Belt and suspenders: bail would set $@ via Carp; just confirm
	# we got here without dying.
	ok 1, 'no bail when optional=>1 and zero configs';
};

subtest 'download_configs - refresh=>1 cascades listing and content' => sub {
	plan tests => 5;
	my $d = make_director();
	# Director-side state we mutate between cached and refreshed
	# calls to prove refresh actually goes back to BOSH:
	#   - $listing  -- which names the listing returns
	#   - %bodies   -- the per-name content (each is a valid YAML
	#                  doc with a unique cpis: entry so spruce-merge
	#                  can append-merge them when both are present).
	my $listing = <<'JSON';
{"Tables":[{"Rows":[
{"id":"5*","type":"cpi","name":"aws-bundle","team":"","created_at":"2026-05-19T10:00:00Z"}
]}]}
JSON
	my %bodies = (
		'aws-bundle'   => "---\ncpis:\n- name: aws-east-v1\n  type: aws\n  properties: {}\n",
		'vsphere-prod' => "---\ncpis:\n- name: vsphere-az1\n  type: vsphere\n  properties: {}\n",
	);

	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub {
		shift; shift if ref($_[0]) eq 'HASH';
		if (($_[0] // '') eq 'configs') {
			return $listing;
		}
		# 'config --type=cpi --name=X --json' -- find the --name= arg
		my ($cname) = grep { /^--name=/ } @_;
		$cname =~ s/^--name=// if $cname;
		my $body = $bodies{$cname // ''} // '';
		# JSON-encode body content (escape newlines)
		(my $jbody = $body) =~ s/\n/\\n/g;
		return qq({"Tables":[{"Rows":[{"content":"$jbody"}]}]});
	};

	my $p1 = workdir().'/refresh-1.yml';
	my @first = $d->download_configs($p1, 'cpi', '*');
	is_deeply [map { $_->{name} } @first], ['aws-bundle'],
		'initial call sees only aws-bundle';

	# Director-side: add vsphere-prod AND change aws-bundle's body.
	$listing = <<'JSON';
{"Tables":[{"Rows":[
{"id":"5*","type":"cpi","name":"aws-bundle","team":"","created_at":"2026-05-19T10:00:00Z"},
{"id":"7*","type":"cpi","name":"vsphere-prod","team":"","created_at":"2026-05-19T10:00:00Z"}
]}]}
JSON
	$bodies{'aws-bundle'} = "---\ncpis:\n- name: aws-east-v2\n  type: aws\n  properties: {}\n";

	# Cached call: should NOT pick up either mutation.
	my $p_cached = workdir().'/refresh-cached.yml';
	my @cached = $d->download_configs($p_cached, 'cpi', '*');
	is_deeply [map { $_->{name} } @cached], ['aws-bundle'],
		'cached call still sees only aws-bundle (listing cache held)';
	my $c_cached = do { local $/; open my $fh, '<', $p_cached; <$fh> };
	like $c_cached, qr/aws-east-v1/,
		'cached call file carries original aws-east-v1 content (content cache held)';

	# Refresh: pick up listing AND content cascade.  Two cpi configs
	# now ⇒ spruce-merge appends their cpis: arrays.
	my $p_refreshed = workdir().'/refresh-now.yml';
	my @refreshed = $d->download_configs($p_refreshed, 'cpi', '*', refresh => 1);
	is_deeply [sort map { $_->{name} } @refreshed],
		[qw(aws-bundle vsphere-prod)],
		'refresh=>1 sees both cpi configs (listing cache invalidated)';

	my $c_ref = do { local $/; open my $fh, '<', $p_refreshed; <$fh> };
	like $c_ref, qr/aws-east-v2/,
		'refreshed file carries the NEW aws-east-v2 content (content cache cascaded)';
};

# ======================================================================
# cpi-type assembly: BOSH concatenates cpis[] arrays across active cpi
# configs and bails on duplicate cpi names (see memory:
# reference-bosh-cpi-merge-semantics).  Spruce's default merge-by-name
# would silently dedupe those duplicates.  Genesis takes a manual path
# for type='cpi': concat the cpis[] arrays, detect duplicates locally,
# and bail with a message naming the cpi-name AND the cpi-config-names
# (per memory:reference-bosh-cpi-terminology) where it appears -- more
# useful than waiting for BOSH's terser CpiDuplicateName at deploy.

use Genesis qw(load_yaml_file);

# Builder for the execute() stub: takes a hash of cpi-config-name =>
# YAML body and returns a sub suitable for `local *execute = ...`.
sub cpi_fixture {
	my (%bodies) = @_;
	my @names = sort keys %bodies;
	my $rows = join(",\n", map {
		qq({"id":"1*","type":"cpi","name":"$_","team":"","created_at":"2026-05-19T10:00:00Z"})
	} @names);
	return sub {
		shift; shift if ref($_[0]) eq 'HASH';
		if (($_[0] // '') eq 'configs') {
			return qq({"Tables":[{"Rows":[$rows]}]});
		}
		my ($cname) = grep { /^--name=/ } @_;
		$cname =~ s/^--name=// if $cname;
		my $body = $bodies{$cname // ''} // '';
		(my $jbody = $body) =~ s/\n/\\n/g;
		return qq({"Tables":[{"Rows":[{"content":"$jbody"}]}]});
	};
}

subtest 'download_configs - cpi assembly concatenates cpis[] arrays (no dupes)' => sub {
	plan tests => 3;
	my $d = make_director();

	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = cpi_fixture(
		'bundle-A' => "---\ncpis:\n- name: aws-east\n  type: aws\n  properties:\n    region: us-east-1\n",
		'bundle-B' => "---\ncpis:\n- name: vsphere-prod\n  type: vsphere\n  properties:\n    datacenter: dc-prod\n",
	);

	my $target = workdir().'/cpi-concat-clean.yml';
	my @result = $d->download_configs($target, 'cpi', '*');
	is scalar(@result), 2, 'two cpi configs reported in @result';

	my $assembled = load_yaml_file($target);
	my @cpis = @{$assembled->{cpis} // []};
	is scalar(@cpis), 2,
		'cpis[] array contains BOTH entries -- concat preserves count';
	is_deeply
		[sort map { $_->{name} } @cpis],
		['aws-east', 'vsphere-prod'],
		'both cpi names are present in the assembled output';
};

subtest 'download_configs - cpi assembly bails on duplicate cpi name with file attribution' => sub {
	plan tests => 3;
	my $d = make_director();

	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = cpi_fixture(
		'bundle-A' => "---\ncpis:\n- name: aws-east\n  type: aws\n  properties:\n    region: us-east-1\n",
		'bundle-B' => "---\ncpis:\n- name: aws-east\n  type: aws\n  properties:\n    region: us-east-2\n",
	);

	my $target = workdir().'/cpi-concat-dupe.yml';
	throws_ok {
		$d->download_configs($target, 'cpi', '*');
	} qr/duplicate cpi name/i, 'bails when the same cpi name appears in multiple cpi configs';

	my $err = $@;
	like $err, qr/aws-east/,
		'error names the duplicated cpi name';
	like $err, qr/bundle-A.*bundle-B|bundle-B.*bundle-A/,
		'error names the cpi-config-names where the duplicate appears';
};

# ======================================================================
# cloud-type assembly: keeps using spruce-merge so the established
# merge-by-name semantics for keyed entries (azs, networks, vm_types,
# etc.) continue to work.  This test pins down that the cpi carve-out
# above did not accidentally change the cloud path -- a manual concat
# in the cloud path would leave duplicate entries by name, which would
# be wrong for cloud configs.

# Builder analogous to cpi_fixture but emits cloud-typed listing rows.
sub cloud_fixture {
	my (%bodies) = @_;
	my @names = sort keys %bodies;
	my $rows = join(",\n", map {
		qq({"id":"1*","type":"cloud","name":"$_","team":"","created_at":"2026-05-19T10:00:00Z"})
	} @names);
	return sub {
		shift; shift if ref($_[0]) eq 'HASH';
		if (($_[0] // '') eq 'configs') {
			return qq({"Tables":[{"Rows":[$rows]}]});
		}
		my ($cname) = grep { /^--name=/ } @_;
		$cname =~ s/^--name=// if $cname;
		my $body = $bodies{$cname // ''} // '';
		(my $jbody = $body) =~ s/\n/\\n/g;
		return qq({"Tables":[{"Rows":[{"content":"$jbody"}]}]});
	};
}

subtest 'download_configs - cloud assembly uses spruce-merge (merge-by-name)' => sub {
	plan tests => 3;
	my $d = make_director();

	# Two cloud configs:
	#   - "default" defines az z1 and a network dmz with cloud_properties
	#   - "extra"   adds a NEW network app, AND extends dmz with another
	#               cloud_properties field (same name => merge-by-name)
	# If spruce-merge runs: the assembled output has ONE dmz network
	# (with both fields) and ONE app network.  If we'd accidentally
	# used manual concat, we'd see TWO dmz entries.
	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = cloud_fixture(
		'default' => <<'YAML',
---
networks:
- name: dmz
  type: manual
YAML
		'extra' => <<'YAML',
---
networks:
- name: dmz
  cloud_properties:
    subnet: subnet-dmz
- name: app
  type: manual
YAML
	);

	my $target = workdir().'/cloud-merge.yml';
	my @result = $d->download_configs($target, 'cloud', '*');
	is scalar(@result), 2, 'two cloud configs reported in @result';

	my $assembled = load_yaml_file($target);
	my @networks = @{$assembled->{networks} // []};

	is scalar(@networks), 2,
		'merge-by-name kept ONE dmz entry plus the new app entry (not 3 via concat)';

	# Find the dmz entry and confirm it carries fields from BOTH sources.
	# Top-level network fields are where merge-by-name applies cleanly;
	# nested arrays (subnets) follow --fallback-append semantics that
	# are not the point of this test.
	my ($dmz) = grep { $_->{name} eq 'dmz' } @networks;
	ok defined($dmz) && defined($dmz->{type}) && defined($dmz->{cloud_properties}),
		'dmz network has both `type` (from default) and `cloud_properties` (from extra) -- spruce merged-by-name';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
