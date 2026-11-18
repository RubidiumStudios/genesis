#!/usr/bin/env perl
# Service::Vault::query runs any safe command, and a command such as
# `safe vault write` or `safe vault login` takes credentials as its
# arguments.  The trace shows the arguments of the safe commands whose
# arguments name paths and keys, and shows every other command's
# arguments by length, keeping its command words, its flags, and the key
# of each key=value in view.
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

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
put_file("$dir/bin/safe", 0755, <<'EOS');
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_SAFE_ARGS"
EOS
$ENV{PATH} = "$dir/bin:$ENV{PATH}";
$ENV{FAKE_SAFE_ARGS} = "$dir/args";

my $vault = bless({url => 'https://10.0.0.5', name => 'fake'}, 'Service::Vault');
my $secret = fake_secret('query');

# The arguments run() traced, joined by spaces, from its numbered list.
sub traced_args {
	my ($log) = @_;
	my ($block) = $log =~ /- with arguments:\n((?:.*\d+: '.*'\n)+)/;
	return join(' ', ($block // '') =~ /\d+: '(.*)'$/mg);
}

for my $case (
	[['vault', 'write', 'auth/approle/login', "role_id=$secret", "secret_id=$secret"],
		qr/vault write <redacted:\d+ bytes> role_id=<redacted:\d+ bytes> secret_id=<redacted:\d+ bytes>/],
	[['vault', 'login', $secret], qr/vault login <redacted:\d+ bytes>/],
	[['vault', 'write', '-format=json', '-field', "-$secret", 'auth/x'], qr/vault write -format=<redacted:\d+ bytes> -field <redacted:\d+ bytes>/],
	[['vault write', "auth/x", "password=$secret"], qr/vault write auth\/x password=<redacted:\d+ bytes>|vault write <redacted:\d+ bytes> password=<redacted:\d+ bytes>/],
	[["vault write auth/x password=$secret"], qr/vault write <redacted:\d+ bytes>/],
	[['target', "https://admin:$secret\@vault.example:8200", 'fake'], qr/target <redacted:\d+ bytes>/],
	[['exists', 'secret/x:y', '--', 'vault', 'write', 'secret/z', "value=$secret"],
		qr/exists secret\/x:y -- vault write <redacted:\d+ bytes> value=<redacted:\d+ bytes>/],
) {
	my ($args, $shown) = @$case;
	subtest "safe @{[join ' ', map {s/\Q$secret\E/<marker>/gr} @$args]} keeps its arguments private" => sub {
		my ($log) = capture_trace { $vault->query(@$args) };
		unlike($log, qr/\Q$secret\E/, 'no argument value is traced');
		like(traced_args($log), $shown, 'the command words and keys stay in view');
		my @got = split /\n/, slurp($ENV{FAKE_SAFE_ARGS});
		like(join(' ', @got), qr/\Q$secret\E/, 'and safe is handed the arguments whole');
	};
}

for my $args (
	['get', 'secret/some/path:key'], ['exists', 'secret/some/path'], ['paths', '--keys', 'secret/some'],
	['rm', '-rf', 'secret/some/path'], ['x509', 'validate', '-A', 'secret/some/ca'], ['export', 'secret/some'],
) {
	subtest "safe @$args keeps its paths in view" => sub {
		my ($log) = capture_trace { $vault->query(@$args) };
		is(traced_args($log), join(' ', @$args), 'the whole command is traced');
	};
}

done_testing;
