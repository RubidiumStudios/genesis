#!/usr/bin/env perl
# A vault or director URL can carry a username and password, as in
# https://user:password@vault.example:8200.  Genesis keeps the URL whole
# for the commands it runs, but no log shows what is before the @: every
# log line has a URL's userinfo replaced as it is written, and the places
# that report a target say only its scheme, host, and port.
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
use Service::Vault::Remote;

my $secret = fake_secret('userinfo');
my $url = "https://admin:$secret\@vault.example:8200";

subtest 'a log line never shows the userinfo of a URL' => sub {
	my ($log, $stderr) = capture_trace {
		trace("connecting to %s", $url);
		debug("connecting to %s/v1/sys/health", $url);
		warning("connecting to %s", "postgres://$secret\@db.example/x");
	};
	unlike($log.$stderr, qr/\Q$secret\E/, 'the password is in no log or warning');
	like($log, qr{https://<redacted:url-userinfo>\@vault\.example:8200}, 'and the host is still shown');
};

subtest 'rebinding to a vault does not quote its URL' => sub {
	local $ENV{GENESIS_TARGET_VAULT} = $url;
	no warnings 'redefine';
	local *Service::Vault::find = sub {()};
	use warnings 'redefine';
	my $error;
	my ($log, $stderr) = capture_trace { eval { Service::Vault->rebind }; $error = $@ };
	like($error, qr{vault\.example:8200}, 'the error names the host');
	unlike($error.$log.$stderr, qr/\Q$secret\E/, 'and not the password');
	unlike($error, qr/<redacted:url-userinfo>/, 'which it never had to scrub');
};

subtest 'creating a target does not trace its URL or quote what safe said' => sub {
	my @run;
	no warnings 'redefine';
	local *Service::Vault::default = sub {undef};
	local *Service::Vault::Remote::run = sub {
		my ($opts, @args) = ref($_[0]) eq 'HASH' ? @_ : ({}, @_);
		push @run, [@args];
		return ('', 1, "Error: could not reach $url: connection refused");
	};
	use warnings 'redefine';
	my $error;
	my ($log, $stderr) = capture_trace { eval { Service::Vault::Remote->create($url, 'ops') }; $error = $@ };
	my @args = @{$run[0] // []};
	is(ref($args[2]) && $args[2]{redact}, $url, 'safe is handed the whole URL');
	is(Genesis::traced_arg($args[2]), 'https://vault.example:8200', 'and the trace shows only where it points');
	like($error, qr{vault\.example:8200.*connection failed}s, 'the error names the host and the kind of failure');
	unlike($error.$log.$stderr, qr/\Q$secret\E/, 'and not the password');
	unlike($error, qr/<redacted:url-userinfo>/, 'which it never had to scrub');
};

done_testing;
