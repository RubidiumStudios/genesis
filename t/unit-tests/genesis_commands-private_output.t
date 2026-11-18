#!/usr/bin/env perl
# Some commands print exactly what an operator asked to see, and that can
# be a credential: `genesis lookup` of an exodus record or of the
# environment, `genesis manifest` of an unredacted manifest, a deployment
# artifact, or a director's configs.  The operator still gets it on
# stdout, but no log file does: a log at any level records only that the
# output was withheld and how long it was.
use strict;
use warnings;

BEGIN { *CORE::GLOBAL::exit = sub { die sprintf("EXIT %d\n", $_[0] // 0) } }

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Commands;
use Genesis::Commands::Info;
use Genesis::Commands::Env;
use Genesis::Commands::Bosh;

my $dir = tempdir(CLEANUP => 1);

# shows_privately - run $code; the value reaches stdout and no log
sub shows_privately {
	my ($what, $value, $code) = @_;
	my ($log, $stderr, $stdout) = capture_trace { eval { $code->(); 1 } or do { die $@ unless $@ =~ /\AEXIT 0\b/ } };
	like($stdout, qr/\Q$value\E/, "$what: the operator still gets the value on stdout");
	unlike($log, qr/\Q$value\E/, "$what: the value is absent from the log");
	unlike($stderr, qr/\Q$value\E/, "$what: and from stderr");
	like($log, qr/<\d+ bytes of output withheld from this log>/, "$what: the log says output was withheld");
}

subtest 'private data output reaches stdout and not the log' => sub {
	my $value = fake_secret('private-output');
	shows_privately('output', $value, sub { Genesis::output({raw => 1, private => 1, data => 1}, $value) });
};

no warnings qw/redefine once/;
local *Genesis::Top::new = sub { bless({}, 'FakeTop') };
local *FakeTop::has_env = sub { $_[1] eq 'fake-env' };
local *FakeTop::load_env = sub { bless({}, 'FakeEnv') };
local *FakeEnv::with_vault = sub { $_[0] };
local *FakeEnv::download_required_configs = sub { $_[0] };

subtest 'genesis lookup --exodus keeps the record out of the log' => sub {
	my $value = fake_secret('exodus-admin-password');
	local *FakeEnv::exodus_lookup = sub { {admin_password => $value} };
	local $Genesis::Commands::COMMAND_OPTIONS = {exodus => 1};
	shows_privately('lookup --exodus', $value, sub { Genesis::Commands::Info::lookup('fake-env', '.') });
};

subtest 'genesis lookup --env keeps the environment out of the log' => sub {
	my $value = fake_secret('credhub-secret');
	local *FakeEnv::get_environment_variables = sub { (CREDHUB_SECRET => $value) };
	local $Genesis::Commands::COMMAND_OPTIONS = {env => 1};
	shows_privately('lookup --env', $value, sub { Genesis::Commands::Info::lookup('fake-env', 'CREDHUB_SECRET') });
};

subtest 'genesis manifest keeps the manifest out of the log' => sub {
	my $value = fake_secret('manifest-password');
	put_file("$dir/manifest.yml", 0644, "---\npassword: $value\n");
	local *FakeEnv::use_create_env = sub { 0 };
	local *FakeEnv::configs = sub { [] };
	local *FakeEnv::manifest_provider = sub { bless({}, 'FakeProvider') };
	local *FakeProvider::known_types = sub { (unredacted => 'x', deployment => 'x') };
	local *FakeProvider::known_subsets = sub { () };
	local *FakeProvider::can = sub { 1 };
	local *FakeProvider::unredacted = sub { bless({}, 'FakeManifest') };
	local *FakeManifest::file = sub { "$dir/manifest.yml" };
	local $Genesis::Commands::COMMAND_OPTIONS = {type => 'unredacted'};
	shows_privately('manifest', $value, sub { Genesis::Commands::Env::manifest('fake-env') });
};

subtest 'bosh-configs keeps a config out of the log' => sub {
	my $value = fake_secret('cpi-api-key');
	shows_privately('bosh-configs', $value, sub {
		Genesis::Commands::Bosh::_bosh_configs_print({type => 'cpi', name => 'default'}, "api_key: $value\n", 'director')
	});
};

done_testing;
