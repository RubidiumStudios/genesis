#!/usr/bin/env perl
# Credentials handed to a command as arguments stay out of the trace.
# run() writes every argument to the trace, so a secret passed as one must
# be wrapped as {redact => $value}; a `key=value` pair can keep its key in
# view with {redact => $pair, prefix => 'key='}.  A caller that passes the
# `redact` option has every argument, its output, its stderr, and its
# environment kept out.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Env;
use Genesis::Kit;
use Service::BOSH;
use Service::Vault;
use Service::Vault::Remote;
use Service::Credhub;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
# Each fake appends the arguments it receives, one per line, to
# $dir/argv-<name>, and `safe auth` also appends what it reads on stdin,
# so a test can check the child got the value the trace leaves out.  The
# fakes print nothing a test does not ask for.
for my $name (qw/safe curl credhub bosh/) {
	put_file("$dir/bin/$name", 0755, join("\n",
		'#!/bin/bash',
		qq(for a in "\$@"; do printf '%s\\n' "\$a"; done >> "$dir/argv-$name"),
		($name eq 'safe'    ? (qq([[ \$1 == auth ]] && cat >> "$dir/argv-$name")) : ()),
		($name eq 'credhub' ? ("echo '{}'") : ()),
		'exit 0', ''));
}
$ENV{PATH} = "$dir/bin:$ENV{PATH}";

# received - the arguments a fake has received since the last call
sub received {
	my ($name) = @_;
	my $file = "$dir/argv-$name";
	my $got = -f $file ? Genesis::slurp($file) : '';
	unlink $file;
	return $got;
}

subtest 'a wrapped argument reaches the command but not the trace' => sub {
	my $value = fake_secret('wrapped');
	# The command writes what it got to a file, since its output would
	# carry the value into the trace on its own.
	my $log = capture_trace {
		run('echo "$2|$3" > "$1"', "$dir/args", {redact => "password=$value", prefix => 'password='}, {redact => $value})
	};
	is(Genesis::slurp("$dir/args"), "password=$value|$value\n", 'the command gets both values');
	unlike($log, qr/\Q$value\E/, 'the value is absent from the trace');
	like($log, qr/password=<redacted:\d+ bytes>/, 'the key of a pair stays in view');
};

subtest 'redact => 1 keeps everything about the command out of the trace' => sub {
	my $value = fake_secret('redact-all');
	my ($log, $out);
	$log = capture_trace {
		$out = run({redact => 1, env => {GENESIS_ENVIRONMENT => $value}}, 'echo "$1"; echo "$1" >&2', $value)
	};
	like($out, qr/\Q$value\E/, 'the command still runs with the value');
	unlike($log, qr/\Q$value\E/, 'the value is absent from the trace');
};

subtest 'vault writes keep their values out of the trace' => sub {
	my $value = fake_secret('vault-set');
	no warnings 'redefine';
	local *Service::Vault::_confirm_written = sub { 1 };
	my $vault = bless({url => 'https://10.0.0.5', name => 'fake'}, 'Service::Vault');
	received('safe');
	my $log = capture_trace { $vault->set('secret/fake/path', admin_password => $value, other => 'shown-nowhere') };
	like(received('safe'), qr/^admin_password=\Q$value\E$/m, 'safe receives the pair whole');
	unlike($log, qr/\Q$value\E/, 'the value is absent from the trace');
	like($log, qr/admin_password=<redacted:\d+ bytes>/, 'the key stays in view');
	unlike($log, qr/shown-nowhere/, 'every value is redacted, not just ones that look secret');

	my $chained = fake_secret('vault-set-chained');
	$log = capture_trace { $vault->query('rm', 'secret/fake/path', '-f', '--', 'set', 'secret/fake/path', "token=$chained") };
	like(received('safe'), qr/^token=\Q$chained\E$/m, 'safe receives the chained pair whole');
	unlike($log, qr/\Q$chained\E/, 'a set chained after another command is redacted too');
	like($log, qr/token=<redacted:\d+ bytes>/, 'with its key in view');
};

subtest 'exodus writes keep their values out of the trace' => sub {
	my $value = fake_secret('exodus-admin-password');
	no warnings qw/redefine once/;
	my $vault = bless({url => 'https://10.0.0.5', name => 'fake'}, 'Service::Vault');
	local *Service::Vault::authenticate = sub { 1 };
	local *Service::Vault::authenticated = sub { 1 };
	local *Service::Vault::read_flattened_secret = sub { {} };
	local *Service::Vault::set = sub { 1 };
	local *Genesis::Env::vault = sub { $vault };
	local *Genesis::Env::exodus_base = sub { 'secret/exodus/fake-env/fake' };
	local *Genesis::Env::extract_manifest_exodus = sub { {admin_password => $value} };
	local *Genesis::Env::manifest_store = sub { 'exodus' };
	local *Genesis::Env::deployments = sub { bless({}, 'FakeDeployments') };
	local *FakeDeployments::next_sequence_number = sub { 1 };
	local *Genesis::Env::_create_deployment_audit_log = sub { 1 };
	my $env = bless({name => 'fake-env'}, 'Genesis::Env');
	my $log = capture_trace { $env->update_deployment_exodus('deploy', 'success', quiet => 1) };
	unlike($log, qr/\Q$value\E/, 'the value is absent from the trace');
	like($log, qr/admin_password=<redacted:\d+ bytes>/, 'the key stays in view');
};

subtest 'safe auth keeps its credentials out of the trace' => sub {
	# The logger registers VAULT_SECRET_ID from the environment, but not
	# VAULT_ROLE_ID, so the role-id shows whether the argument is wrapped.
	my $value = fake_secret('vault-role-id');
	no warnings 'redefine';
	my $authed = 0;
	local *Service::Vault::Remote::authenticated = sub { $authed++ > 0 };
	local *Service::Vault::Remote::_on_auth_success = sub { 1 };
	local *Service::Vault::Remote::ref = sub { 'fake' };
	local $ENV{VAULT_ROLE_ID} = $value;
	local $ENV{VAULT_SECRET_ID} = fake_secret('vault-secret-id');
	my $vault = bless({url => 'https://10.0.0.5', name => 'fake'}, 'Service::Vault::Remote');
	received('safe');
	my $log = capture_trace { $vault->authenticate };
	like(received('safe'), qr/^\Q$value\E$/m, 'safe auth reads the credential');
	like($log, qr/safe auth/, 'the auth command is traced');
	unlike($log, qr/\Q$value\E/, 'the credential is absent from the trace');
};

subtest 'CredHub writes keep their values out of the trace' => sub {
	my $credhub = bless({
		name => 'fake', base => '/', url => 'https://10.0.0.6:8844',
		username => 'credhub-admin', password => 'not-under-test', ca_cert => 'ca',
	}, 'Service::Credhub');
	for my $case (
		[password    => {password => fake_secret('credhub-password')}],
		[user        => {username => 'admin', password => fake_secret('credhub-user-password')}],
		[rsa         => {public_key => 'pub', private_key => fake_secret('credhub-rsa-key')}],
		[ssh         => {public_key => 'pub', private_key => fake_secret('credhub-ssh-key')}],
		[certificate => {certificate => 'cert', private_key => fake_secret('credhub-cert-key'), root_path => '/ca'}],
	) {
		my ($type, $value) = @$case;
		my ($secret) = grep {/^fake-/} values %$value;
		received('credhub');
		my $log = capture_trace { my @r = $credhub->set('fake/path', $value, $type) };
		like(received('credhub'), qr/^\Q$secret\E$/m, "$type: credhub receives the value");
		unlike($log, qr/\Q$secret\E/, "$type: the value is absent from the trace");
	}
	my $data = fake_secret('credhub-curl-data');
	my $log = capture_trace { $credhub->query('/api/v1/data', _method => 'put', _data => qq({"value":"$data"})) };
	like(received('credhub'), qr/^\Q{"value":"$data"}\E$/m, 'credhub curl receives the request body');
	unlike($log, qr/\Q$data\E/, 'credhub curl: the request body is absent from the trace');
};

subtest 'curl keeps credentials and headers out of the trace' => sub {
	my $token = fake_secret('curl-bearer');
	my $basic = fake_secret('curl-basic');
	my $header = fake_secret('curl-header');
	for my $creds ("Bearer $token", "user:$basic") {
		received('curl');
		my $log = capture_trace {
			my @r = Genesis::curl('GET', 'https://example.invalid/x', {'X-Api-Key' => $header}, undef, 0, $creds)
		};
		my $got = received('curl');
		like($got, qr/^X-Api-Key: \Q$header\E$/m, 'curl receives the header');
		like($got, qr/\Q$token\E|\Q$basic\E/, 'curl receives the credentials');
		unlike($log, qr/\Q$token\E|\Q$basic\E/, 'the credentials are absent from the trace');
		unlike($log, qr/\Q$header\E/, 'a header value is absent from the trace');
		like($log, qr/X-Api-Key: <redacted:\d+ bytes>/, 'the header name stays in view');
	}
};

subtest 'the bosh command dump shows wrapped arguments redacted' => sub {
	my $value = fake_secret('bosh-arg');
	Service::BOSH->set_command("$dir/bin/bosh");
	received('bosh');
	my $log = capture_trace { bless({}, 'Service::BOSH')->execute('update-config', '--type=cloud', {redact => $value}) };
	is(received('bosh'), "update-config\n--type=cloud\n$value\n", 'bosh receives the exact arguments');
	unlike($log, qr/\Q$value\E/, 'the value is absent from the trace');
};

subtest 'hook extra_vars are traced like run() environment values' => sub {
	my $value = fake_secret('extra-var');
	my $old   = fake_secret('extra-var-old');
	no warnings qw/redefine once/;
	local $ENV{FAKE_KIT_TOKEN} = $old;
	local *Genesis::Kit::has_hook = sub { 1 };
	local *Genesis::Kit::id = sub { "fake/1.0.0" };
	local *Genesis::Kit::name = sub { "fake" };
	local *Genesis::Kit::version = sub { "1.0.0" };
	local *Genesis::Kit::path = sub { "/nonexistent" };
	my $kit = bless({}, 'Genesis::Kit');
	local *Genesis::Kit::known_hooks = sub { ('info') };
	local *FakeEnv::get_environment_variables = sub { () };
	my $log = capture_trace {
		eval { $kit->run_hook('info', env => bless({}, 'FakeEnv'), extra_vars => {FAKE_KIT_TOKEN => $value}) }
	};
	unlike($log, qr/\Q$value\E|\Q$old\E/, 'neither value is in the trace');
	like($log, qr/Overwriting env var FAKE_KIT_TOKEN/, 'the variable is still named');
};

done_testing;
