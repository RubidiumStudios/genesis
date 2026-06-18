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
use Digest::SHA qw/sha1_hex/;

use Genesis;
use_ok 'Genesis::Env::Secrets::Entombment',
	qw/credhub_var_name put_secret entomb_one_secret prime_credhub_cache
	   make_local_vault shutdown_local_vault populate_local_vault/;

# Preload so subsequent `local *Service::Vault::Local::create = sub {...}`
# stubs aren't clobbered by an in-method `require Service::Vault::Local`.
use_ok 'Service::Vault::Local';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# ======================================================================
# credhub_var_name - pure naming
# ======================================================================

subtest 'credhub_var_name - deterministic from (path, key, value, prefix)' => sub {
	plan tests => 2;

	my $name = credhub_var_name('secret/foo', 'password', 's3cret', 'p/');
	my $sha = substr(sha1_hex('secret/foo--password--s3cret'), 0, 8);

	is $name, "p/secret/foo--password--${sha}",
		'composes prefix + path + key + 8-char sha1';

	# Same inputs → same output (stable)
	is credhub_var_name('secret/foo', 'password', 's3cret', 'p/'),
	   $name,
	   'naming is deterministic across calls';
};

subtest 'credhub_var_name - different values produce different shas' => sub {
	plan tests => 1;

	my $a = credhub_var_name('p', 'k', 'value-a', 'P/');
	my $b = credhub_var_name('p', 'k', 'value-b', 'P/');

	isnt $a, $b, 'changing the value changes the sha';
};

subtest 'credhub_var_name - default prefix when omitted' => sub {
	plan tests => 1;

	like credhub_var_name('p', 'k', 'v'),
		qr{^genesis-entombed/p--k--[0-9a-f]{8}$},
		'default prefix is genesis-entombed/';
};

# ======================================================================
# put_secret - idempotent put returning 'new'/'exists'/'altered'/'failed'
# ======================================================================
#
# Mock credhub captures set() calls and returns scripted values from
# get() so we can drive every action path.

sub mock_credhub {
	my %opts = @_;
	my %store = %{ $opts{initial} // {} };
	my @calls;
	my $set_should_succeed = $opts{set_succeeds} // 1;
	my $self = bless {
		_store => \%store,
		_calls => \@calls,
	}, 'Test::Mock::Credhub';
	{
		no strict 'refs';
		no warnings 'redefine';
		*{'Test::Mock::Credhub::get'} = sub {
			my ($s, $name) = @_;
			push @{$s->{_calls}}, [ 'get', $name ];
			return $s->{_store}{$name};
		};
		*{'Test::Mock::Credhub::set'} = sub {
			my ($s, $name, $value) = @_;
			push @{$s->{_calls}}, [ 'set', $name, $value ];
			$s->{_store}{$name} = $value if $set_should_succeed;
		};
	}
	return $self;
}

subtest 'put_secret - new value: new action' => sub {
	plan tests => 2;
	my $ch = mock_credhub();
	is put_secret($ch, 'p/x', 'value'), 'new',
		'returns "new" for first-time put';
	is $ch->{_store}{'p/x'}, 'value', 'value is stored';
};

subtest 'put_secret - same value: exists action, no set' => sub {
	plan tests => 2;
	my $ch = mock_credhub(initial => { 'p/x' => 'value' });
	is put_secret($ch, 'p/x', 'value'), 'exists',
		'returns "exists" when value already matches';
	my @sets = grep { $_->[0] eq 'set' } @{$ch->{_calls}};
	is scalar @sets, 0, 'no set call made for matching value';
};

subtest 'put_secret - changed value: altered action' => sub {
	plan tests => 2;
	my $ch = mock_credhub(initial => { 'p/x' => 'old' });
	is put_secret($ch, 'p/x', 'new-value'), 'altered',
		'returns "altered" when value differs';
	is $ch->{_store}{'p/x'}, 'new-value', 'new value is stored';
};

subtest 'put_secret - set silently failed: failed action' => sub {
	plan tests => 1;
	my $ch = mock_credhub(set_succeeds => 0);
	is put_secret($ch, 'p/x', 'value'), 'failed',
		'returns "failed" when verify-after-set does not match';
};

# ======================================================================
# entomb_one_secret - composition of credhub_var_name + put_secret
# ======================================================================

subtest 'entomb_one_secret - returns (var, action) tuple' => sub {
	plan tests => 3;

	my $ch = mock_credhub();
	my ($var, $action) = entomb_one_secret($ch, 'secret/db', 'password', 'hunter2', '/cpi/');

	my $sha = substr(sha1_hex('secret/db--password--hunter2'), 0, 8);
	my $expected_name = "/cpi/secret/db--password--${sha}";
	is $var, "((${expected_name}))",
		'var is parenthesized credhub_var_name';
	is $action, 'new', 'action reflects put outcome';

	is $ch->{_store}{$expected_name},
		'hunter2',
		'value is committed under the deterministic var name';
};

# ======================================================================
# prime_credhub_cache - idempotent preload
# ======================================================================

sub mock_credhub_with_preload {
	my $ch = mock_credhub(@_);
	{
		no strict 'refs';
		no warnings 'redefine';
		*{'Test::Mock::Credhub::is_preloaded'} = sub { $_[0]->{_preloaded} };
		*{'Test::Mock::Credhub::preload'} = sub {
			my $s = shift;
			push @{$s->{_calls}}, [ 'preload' ];
			$s->{_preloaded} = 1;
			return $s;
		};
	}
	$ch;
}

subtest 'prime_credhub_cache - preloads when not preloaded' => sub {
	plan tests => 2;
	my $ch = mock_credhub_with_preload();
	prime_credhub_cache($ch);
	my @preloads = grep { $_->[0] eq 'preload' } @{$ch->{_calls}};
	is scalar @preloads, 1, 'preload called once on first invocation';
	ok $ch->{_preloaded}, 'credhub is now marked preloaded';
};

subtest 'prime_credhub_cache - no-op when already preloaded' => sub {
	plan tests => 1;
	my $ch = mock_credhub_with_preload();
	$ch->{_preloaded} = 1;
	prime_credhub_cache($ch);
	my @preloads = grep { $_->[0] eq 'preload' } @{$ch->{_calls}};
	is scalar @preloads, 0, 'preload not called when already preloaded';
};

# ======================================================================
# make_local_vault / shutdown_local_vault - lifecycle helpers
# ======================================================================
#
# Service::Vault::Local::create spawns an in-memory vault process.
# We stub that here so tests don't actually spin up a vault.

sub install_local_vault_stubs {
	my (%opts) = @_;
	my @created;
	my @shutdowns;
	{
		no strict 'refs';
		no warnings 'redefine';
		*{'Service::Vault::Local::create'} = sub {
			my ($class, $name) = @_;
			push @created, $name;
			return bless { _name => $name, _shutdowns => \@shutdowns }, 'Service::Vault::Local';
		};
		*{'Service::Vault::Local::shutdown'} = sub {
			my $self = shift;
			push @{$self->{_shutdowns}}, $self->{_name};
		};
	}
	return (\@created, \@shutdowns);
}

subtest 'make_local_vault - creates a Service::Vault::Local with env-based name' => sub {
	plan tests => 2;

	my ($created, $shutdowns) = install_local_vault_stubs();

	# Stand-in env: only need ->name
	my $env = bless { name => 'demo-env' }, 'Test::Mock::Env';
	{ no strict 'refs'; *{'Test::Mock::Env::name'} = sub { $_[0]->{name} } }

	my $lv = make_local_vault(env => $env);

	isa_ok $lv, 'Service::Vault::Local', 'returns a Local vault';
	like $created->[0], qr/^demo-env-entomb/,
		'created with env-name-derived name';
};

subtest 'make_local_vault - honours explicit name override' => sub {
	plan tests => 1;
	my ($created, $shutdowns) = install_local_vault_stubs();
	make_local_vault(name => 'my-scratch');
	is $created->[0], 'my-scratch', 'name opt overrides env-derived default';
};

subtest 'shutdown_local_vault - calls shutdown when given a vault' => sub {
	plan tests => 1;
	my ($created, $shutdowns) = install_local_vault_stubs();
	my $lv = bless { _name => 'a', _shutdowns => $shutdowns }, 'Service::Vault::Local';
	shutdown_local_vault($lv);
	is_deeply $shutdowns, ['a'], 'shutdown was invoked exactly once';
};

subtest 'shutdown_local_vault - idempotent / safe on undef' => sub {
	plan tests => 1;
	lives_ok { shutdown_local_vault(undef) } 'no error on undef vault';
};

# ======================================================================
# populate_local_vault - bulk path -> credhub-var substitution
# ======================================================================
#
# Walks a vaultinfo-shaped paths map, fetches each value via $vault,
# entombs it via $credhub, and registers a ((credhub-var)) entry in
# $local_vault under the original (path, key).

sub mock_vault {
	my %store = @_;
	my $self = bless {
		_store => \%store,
		_calls => [],
	}, 'Test::Mock::Vault';
	{
		no strict 'refs';
		no warnings 'redefine';
		*{'Test::Mock::Vault::get'} = sub {
			my ($s, $path, $key) = @_;
			push @{$s->{_calls}}, [ 'get', $path, $key ];
			my $entry = $s->{_store}{$path};
			return undef unless $entry;
			return $entry->{$key};
		};
	}
	$self;
}

sub mock_local_vault {
	my $self = bless {
		_entries => {},
		_calls   => [],
	}, 'Test::Mock::LocalVault';
	{
		no strict 'refs';
		no warnings 'redefine';
		*{'Test::Mock::LocalVault::set'} = sub {
			my ($s, $path, $key, $value) = @_;
			push @{$s->{_calls}}, [ 'set', $path, $key, $value ];
			$s->{_entries}{$path}{$key} = $value;
		};
	}
	$self;
}

subtest 'populate_local_vault - primes credhub cache, entombs each path:key' => sub {
	plan tests => 4;

	my $vault    = mock_vault(
		'secret/db' => { password => 'hunter2', user => 'admin' },
	);
	my $credhub  = mock_credhub_with_preload();
	my $local    = mock_local_vault();

	populate_local_vault(
		paths       => { 'secret/db:password' => [], 'secret/db:user' => [] },
		vault       => $vault,
		credhub     => $credhub,
		prefix      => '/cpi/',
		local_vault => $local,
	);

	ok $credhub->{_preloaded}, 'credhub was preloaded before the loop';

	# Each path:key was entombed under a deterministic credhub var,
	# and the local vault now substitutes ((credhub-var)) for that
	# path:key during downstream spruce evaluation.
	my $pw_sha   = substr(sha1_hex('secret/db--password--hunter2'), 0, 8);
	my $user_sha = substr(sha1_hex('secret/db--user--admin'),       0, 8);

	is $local->{_entries}{'secret/db'}{password},
		"((/cpi/secret/db--password--${pw_sha}))",
		'password local-vault entry references the credhub-var';
	is $local->{_entries}{'secret/db'}{user},
		"((/cpi/secret/db--user--${user_sha}))",
		'user local-vault entry references the credhub-var';

	is $credhub->{_store}{"/cpi/secret/db--password--${pw_sha}"},
		'hunter2',
		'plaintext is committed to credhub under the deterministic name';
};

subtest 'populate_local_vault - empty paths map is a no-op' => sub {
	plan tests => 1;
	my $vault   = mock_vault();
	my $credhub = mock_credhub_with_preload();
	my $local   = mock_local_vault();
	populate_local_vault(
		paths       => {},
		vault       => $vault,
		credhub     => $credhub,
		prefix      => '/x/',
		local_vault => $local,
	);
	is scalar @{$local->{_calls}}, 0, 'no local-vault writes when paths is empty';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
