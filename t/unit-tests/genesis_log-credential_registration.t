#!/usr/bin/env perl
# Each credential Genesis loads is registered with the logger at the point
# it is loaded, so the logger's scrub catches it on any path to a trace.
# Every test builds the object with a made-up value, logs that value, and
# checks it never reaches the log file.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use JSON::PP qw/encode_json/;

use Genesis;
use Genesis::Log;
use Genesis::Env;
use Service::Vault;
use Service::Vault::Admin;
use Service::BOSH::Director;
use Service::Credhub;

sub assert_scrubbed {
	my ($what, $setup, @secrets) = @_;
	my $log = capture_trace {
		$setup->();
		trace("logging %s", $_) for @secrets;
	};
	unlike($log, qr/\Q$_\E/, "$what is scrubbed") for @secrets;
	like($log, qr/<redacted:/, "$what leaves a redaction marker");
}

subtest 'a BOSH director client secret' => sub {
	my $secret = fake_secret('director');
	assert_scrubbed('the director client secret', sub {
		Service::BOSH::Director->new('fake-alias',
			url => 'https://10.0.0.6:25555', client => 'admin', secret => $secret,
			exodus_vault => 'none');
	}, $secret);
};

subtest 'exodus credentials when operator BOSH credentials win' => sub {
	my ($admin_pw, $credhub_pw, $operator_pw) = map {fake_secret($_)} qw/admin credhub operator/;
	local $ENV{BOSH_USER} = 'operator';
	local $ENV{BOSH_PASSWORD} = $operator_pw;
	no warnings 'redefine';
	local *Genesis::Env::user_provided_bosh_creds_policy = sub {'allow'};
	local *Genesis::Env::bosh_env = sub {{}};
	my $env = bless({}, 'Genesis::Env');
	assert_scrubbed('the exodus admin and CredHub passwords', sub {
		Service::BOSH::Director->from_exodus('fake-alias', $env,
			exodus_path  => 'secret/exodus/fake-alias/bosh',
			exodus_vault => 'none',
			exodus_data  => {
				url => 'https://10.0.0.6:25555', admin_username => 'admin',
				admin_password => $admin_pw, credhub_password => $credhub_pw,
				ca_cert => 'fake-ca', kit_name => 'bosh',
			});
	}, $admin_pw, $credhub_pw, $operator_pw);
};

subtest 'a CredHub password' => sub {
	my $secret = fake_secret('credhub');
	assert_scrubbed('the CredHub password', sub {
		Service::Credhub->new('fake', '/', 'https://10.0.0.6:8844', 'credhub-admin', $secret, 'fake-ca');
	}, $secret);
};

subtest 'the CredHub password credhub_connection_env reads from exodus' => sub {
	my $secret = fake_secret('credhub-env');
	no warnings 'redefine';
	local *FakeEnvForCredhub::lookup        = sub { return ('fake-alias', 'genesis.env') };
	local *FakeEnvForCredhub::exodus_lookup = sub { return {credhub_url => 'https://10.0.0.6:8844', credhub_username => 'credhub-admin', credhub_password => $secret} };
	local *FakeEnvForCredhub::name          = sub { 'fake-env' };
	local *FakeEnvForCredhub::type          = sub { 'fake-kit' };
	assert_scrubbed('the CredHub password from exodus', sub {
		my %env = Genesis::Env::credhub_connection_env(bless({}, 'FakeEnvForCredhub'));
	}, $secret);
};

subtest 'a vault token read from safe' => sub {
	my $token = fake_secret('vault-token');
	no warnings 'redefine';
	local *Service::Vault::run = sub {
		return (encode_json({VAULT_ADDR => 'https://10.0.0.5', VAULT_TOKEN => $token}), 0, '');
	};
	assert_scrubbed('the vault token', sub {
		bless({url => 'https://10.0.0.5', name => 'fake'}, 'Service::Vault')->env;
	}, $token);
};

subtest 'vault unseal keys' => sub {
	my @keys = map {fake_secret("unseal$_")} 1..3;
	no warnings 'redefine';
	local *FakeEnvForUnseal::secrets_mount = sub { 'secret/' };
	local *Service::Vault::get = sub {return {map {("key$_" => $keys[$_-1])} 1..3}};
	assert_scrubbed('the unseal keys', sub {
		bless({url => 'https://10.0.0.5'}, 'Service::Vault')->fetch_unseal_keys(bless({}, 'FakeEnvForUnseal'));
	}, @keys);
};

subtest 'an AppRole secret-id' => sub {
	my ($role_id, $secret_id) = map {fake_secret($_)} qw/role-id secret-id/;
	no warnings 'redefine';
	local *FakeVaultForAppRole::query = sub {
		my ($self, @args) = @_;
		shift @args if ref($args[0]) eq 'HASH';
		return (($args[1] eq '-field=role_id' ? $role_id : $secret_id), 0);
	};
	local *FakeAppRoles::exists = sub { 1 };
	local *Service::Vault::Admin::approles = sub {bless({}, 'FakeAppRoles')};
	my $admin = bless({vault => bless({}, 'FakeVaultForAppRole')}, 'Service::Vault::Admin');
	local *Service::Vault::Admin::vault = sub {$_[0]->{vault}};
	assert_scrubbed('the AppRole secret-id', sub {
		$admin->get_approle_credentials('fake-role');
	}, $secret_id);
};

done_testing;
