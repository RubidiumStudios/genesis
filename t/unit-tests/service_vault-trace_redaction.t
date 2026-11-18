#!/usr/bin/env perl
# Vault and CredHub commands whose output is a credential keep that output
# out of the trace.  `safe env --json` returns the vault token, `vault
# token lookup` returns it again as the token's id, an AppRole's secret-id
# is read straight off stdout, and `credhub curl` returns whatever the API
# answered.  The logger only learns a value after the command returns, so
# these are tested with values it has never seen: each one must be kept
# out by the call itself.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Service::Vault;
use Service::Vault::Admin;
use Service::Credhub;

my $dir = tempdir(CLEANUP => 1);
put_file("$dir/safe", 0755, <<'SH');
#!/bin/bash
case "$*" in
	"env --json")                     echo "{\"VAULT_ADDR\":\"https://10.0.0.5\",\"VAULT_TOKEN\":\"$FAKE_VALUE\"}" ;;
	"vault token lookup -format=json") echo "{\"data\":{\"id\":\"$FAKE_VALUE\",\"display_name\":\"fake\"}}" ;;
	"vault read -field=role_id "*)    echo "$FAKE_ROLE_ID" ;;
	"vault write -field=secret_id "*) echo "$FAKE_VALUE" ;;
	*) echo "unexpected safe call: $*" >&2; exit 1 ;;
esac
SH
put_file("$dir/credhub", 0755, <<'SH');
#!/bin/bash
echo "{\"value\":\"$FAKE_VALUE\"}"
SH
$ENV{PATH} = "$dir:$ENV{PATH}";

sub vault { bless({url => 'https://10.0.0.5', name => 'fake'}, 'Service::Vault') }

subtest 'safe env --json' => sub {
	local $ENV{FAKE_VALUE} = fake_secret('vault-env-token');
	my ($log, $env);
	$log = capture_trace { $env = vault->env };
	is($env->{VAULT_TOKEN}, $ENV{FAKE_VALUE}, 'the caller still gets the token');
	unlike($log, qr/\Q$ENV{FAKE_VALUE}\E/, 'the token is absent from the trace');
	like($log, qr/\[\d+b of redacted data omitted from debug\]/, 'a byte count is kept');
};

subtest 'vault token lookup' => sub {
	local $ENV{FAKE_VALUE} = fake_secret('vault-lookup-token');
	my ($log, $info);
	$log = capture_trace { $info = vault->token_info };
	is($info->{data}{display_name}, 'fake', 'the caller still gets the token information');
	unlike($log, qr/\Q$ENV{FAKE_VALUE}\E/, 'the token id is absent from the trace');
};

subtest 'AppRole credentials' => sub {
	local $ENV{FAKE_VALUE}   = fake_secret('approle-secret-id');
	local $ENV{FAKE_ROLE_ID} = fake_secret('approle-role-id');
	no warnings 'redefine';
	local *FakeAppRoles::exists = sub { 1 };
	local *Service::Vault::Admin::approles = sub { bless({}, 'FakeAppRoles') };
	local *Service::Vault::Admin::vault = sub { $_[0]->{vault} };
	my $admin = bless({vault => vault()}, 'Service::Vault::Admin');
	my ($log, @creds);
	$log = capture_trace { @creds = $admin->get_approle_credentials('fake-role') };
	is_deeply(\@creds, [$ENV{FAKE_ROLE_ID}, $ENV{FAKE_VALUE}], 'the caller still gets both');
	unlike($log, qr/\Q$ENV{FAKE_VALUE}\E/, 'the secret-id is absent from the trace');
	unlike($log, qr/\Q$ENV{FAKE_ROLE_ID}\E/, 'the role-id is absent from the trace');
};

subtest 'credhub curl' => sub {
	local $ENV{FAKE_VALUE} = fake_secret('credhub-curl-value');
	my $credhub = bless({
		name => 'fake', base => '/', url => 'https://10.0.0.6:8844',
		username => 'credhub-admin', password => 'not-under-test', ca_cert => 'ca',
	}, 'Service::Credhub');
	my ($log, $reply);
	$log = capture_trace { $reply = $credhub->query('/api/v1/data?name=/x') };
	is($reply->{value}, $ENV{FAKE_VALUE}, 'the caller still gets the reply');
	unlike($log, qr/\Q$ENV{FAKE_VALUE}\E/, 'the reply is absent from the trace');
};

done_testing;
