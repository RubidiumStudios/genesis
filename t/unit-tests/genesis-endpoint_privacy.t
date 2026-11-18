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

subtest 'the scrubber parses the whole authority of a URL' => sub {
	# RFC 3986 lets userinfo hold sub-delims, percent escapes, and colons,
	# and a hand-written URL can hold an unescaped @ or quote too.  The
	# userinfo runs to the last @ before the path, query, or fragment.
	my @passwords = (
		"pa'ss-$secret",
		"q\"uote-$secret",
		"!\$&()*+,;=-$secret",
		"%2Fescaped:$secret",
		"user\@corp:$secret",
		"<angle>$secret",
	);
	for my $password (@passwords) {
		my ($log, $stderr) = capture_trace {
			debug("could not reach 'https://admin:$password\@vault.example:8200/v1/sys/health'");
			trace("target #M{http://admin:$password\@10.0.0.6}");
		};
		unlike($log.$stderr, qr/\Q$secret\E/, "the password in <$password> is in no log");
		like($log, qr{https://<redacted:url-userinfo>\@vault\.example:8200/v1/sys/health'}, '... and the host and path are still shown');
	}
	my ($log) = capture_trace {
		debug("mail ops\@example.com about https://vault.example:8200/ui");
	};
	like($log, qr{ops\@example\.com about https://vault\.example:8200/ui}, 'text with no userinfo is left alone');
};

subtest 'the scrubber drops the query and fragment of a URL' => sub {
	# A signed URL carries its credential in the query, and a token can
	# ride in a fragment, so neither reaches a log.  The host and path stay.
	my $sig = fake_secret('query');
	my $frag = fake_secret('fragment');
	my ($log, $stderr) = capture_trace {
		debug("proxy is https://proxy.example:3128/v1/sys?X-Signature=$sig&ok=1 now");
		trace("open #C{https://vault.example/ui/#token=$frag} to look");
		warning("fetch from s3://bucket/key?X-Amz-Signature=$sig#$frag");
		debug("mail ops\@example.com about https://vault.example:8200/ui?from=a\@b");
	};
	unlike($log.$stderr, qr/\Q$sig\E|\Q$frag\E/, 'neither the query nor the fragment is in any log');
	like($log, qr{https://proxy\.example:3128/v1/sys\?<redacted:url-query> now}, 'the host and path stay, and the query is marked');
	like($log, qr{https://vault\.example/ui/\#<redacted:url-fragment> to look}, 'a fragment is marked, and the markup around it survives');
	like($log, qr{ops\@example\.com about https://vault\.example:8200/ui\?<redacted:url-query>}, 'an at sign in a query is no userinfo');
};

subtest 'a rejected vault target is named by its endpoint' => sub {
	my $token = fake_secret('signed');
	my $error;
	my ($log, $stderr) = capture_trace {
		eval { Service::Vault::Remote->attach(url => "https://vault.example:8200/v1?token=$token") };
		$error = $@;
	};
	like($error, qr{https://vault\.example:8200}, 'the error names the vault');
	unlike($error.$log.$stderr, qr/\Q$token\E/, 'and not the query that carries the credential');
	unlike($error, qr/<redacted:url-query>/, 'which it never had to scrub');
};

subtest 'a failed vault read names the vault by its endpoint' => sub {
	my $vault = Service::Vault::Remote->new("https://admin:pa'ss-$secret\@vault.example:8200", 'ops', 1);
	no warnings 'redefine';
	local *Service::Vault::query = sub {('', 2, "Error: could not reach the vault")};
	use warnings 'redefine';
	my $error;
	my ($log, $stderr) = capture_trace { eval {$vault->read_flattened_secret('secret/x')}; $error = $@ };
	like($error, qr{https://vault\.example:8200}, 'the error names the vault');
	unlike($error.$log.$stderr, qr/\Q$secret\E|<redacted:url-userinfo>/, 'without its userinfo, which it never had to scrub');
};

done_testing;
