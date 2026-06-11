#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use lib 'lib';
use helper;
use Test::More;
use Test::Deep;

use_ok 'Service::Vault';
use Genesis;

# ===========================================================================
# Service::Vault::max_json_string_value_length
#
# Returns the size, in bytes, of the largest single JSON string value
# Vault will accept on a write request.  Sources, in priority order:
#   1. GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH env var (positive int)
#   2. Vault server query: /sys/config/state/sanitized listener config
#   3. Vault's compiled-in default: 1 MiB (1024 * 1024 = 1,048,576)
#
# The Vault listener option max_json_string_value_length was introduced
# in Vault 1.21.0 (October 2025).  Earlier Vault releases enforce no
# per-string limit; the default still applies as a conservative cap
# for our chunking purposes.
# ===========================================================================

my $DEFAULT_LIMIT = 1024 * 1024;   # 1 MiB

sub make_vault {
	my (%args) = @_;
	return Service::Vault->new(
		$args{url}       // 'https://vault.example.com:8200',
		$args{name}      // 'test-vault',
		$args{verify}    // 1,
		$args{namespace} // '',
		$args{strongbox},
		$args{mount}     // '/secret/',
	);
}

# Stub query() on a specific vault instance so we control what
# `safe curl ...` returns.  Install the stub once via a class-level
# redefinition that consults the per-instance hook.
sub stub_query {
	my ($v, $out, $rc, $err) = @_;
	$rc  //= 0;
	$err //= '';
	$v->{__test_query} = sub { return ($out, $rc, $err) };
}

{
	no warnings 'redefine', 'once';
	*Service::Vault::query = sub {
		my $self = shift;
		shift if ref($_[0]) eq 'HASH';   # opts
		return $self->{__test_query}->(@_) if $self->{__test_query};
		return ('', 1, 'no stub installed');
	};
}

# ---------- default ----------

subtest 'no env var + no vault query response => Vault default of 1 MiB' => sub {
	plan tests => 1;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH};
	my $v = make_vault();
	# No stub installed => query path returns failure => default
	is $v->max_json_string_value_length, $DEFAULT_LIMIT,
		"default 1 MiB ($DEFAULT_LIMIT) when env unset + vault unreachable";
};

# ---------- env var override ----------

subtest 'GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH env var wins' => sub {
	plan tests => 2;
	local %ENV = (%ENV);

	$ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH} = 524288;
	is make_vault->max_json_string_value_length, 524288,
		'512 KiB env var value returned directly';

	$ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH} = 2097152;
	is make_vault->max_json_string_value_length, 2097152,
		'2 MiB env var value returned directly';
};

subtest 'invalid env var ignored => falls through' => sub {
	plan tests => 3;
	local %ENV = (%ENV);

	for my $bad ('not-a-number', '0', '-100') {
		$ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH} = $bad;
		is make_vault->max_json_string_value_length, $DEFAULT_LIMIT,
			"invalid env var '$bad' => default";
	}
};

# ---------- vault server query ----------

subtest 'vault query returns listener max_json_string_value_length' => sub {
	plan tests => 1;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH};
	my $v = make_vault();
	# Real-world Vault response shape under `safe curl --data-only`:
	# safe strips its own wrapping; Vault's response envelope
	# (request_id, data, ...) is preserved.  The actual content lives
	# at $decoded->{data}->...
	my $config_json = '{
		"request_id": "abc-123",
		"data": {
			"listeners": [
				{"config": {"max_json_string_value_length": 2097152}}
			]
		}
	}';
	stub_query($v, $config_json, 0, '');
	is $v->max_json_string_value_length, 2097152,
		'server-reported max_json_string_value_length returned (2 MiB)';
};

subtest 'vault query fails => default' => sub {
	plan tests => 1;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH};
	my $v = make_vault();
	stub_query($v, '', 1, 'permission denied');
	is $v->max_json_string_value_length, $DEFAULT_LIMIT,
		'query failure => default 1 MiB';
};

subtest 'vault query returns no listener field => default' => sub {
	plan tests => 1;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH};
	my $v = make_vault();
	# Listener configured but without max_json_string_value_length set
	# (common - operators rarely tune it; Vault uses compiled-in
	# default in that case).
	stub_query(
		$v,
		'{"request_id":"x","data":{"listeners":[{"config":{"tls_disable":1}}]}}',
		0,
		'',
	);
	is $v->max_json_string_value_length, $DEFAULT_LIMIT,
		'listener without the field => default';
};

subtest 'vault query returns invalid JSON => default' => sub {
	plan tests => 1;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH};
	my $v = make_vault();
	stub_query($v, 'not json at all', 0, '');
	is $v->max_json_string_value_length, $DEFAULT_LIMIT,
		'invalid JSON => default';
};

# ---------- caching on the instance ----------

subtest 'result cached on the instance after first lookup' => sub {
	plan tests => 1;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH};
	my $v = make_vault();
	my $call_count = 0;
	$v->{__test_query} = sub {
		$call_count++;
		return (
			'{"request_id":"x","data":{"listeners":[{"config":{"max_json_string_value_length":1048576}}]}}',
			0,
			'',
		);
	};
	$v->max_json_string_value_length;
	$v->max_json_string_value_length;
	$v->max_json_string_value_length;
	is $call_count, 1,
		'vault query invoked once even on repeated calls';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
