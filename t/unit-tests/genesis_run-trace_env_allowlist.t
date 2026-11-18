#!/usr/bin/env perl
# run() traces the environment it sets for a command, and that environment
# routinely carries credentials: every bosh call gets BOSH_CLIENT_SECRET,
# and every manifest merge gets CREDHUB_SECRET.  Only keys on an explicit
# allowlist may show their values; every other key shows its name and a
# byte count, so no credential reaches a trace whatever it is called.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;

use Genesis;
use Genesis::Log;

my $bosh_secret    = fake_secret('bosh');
my $credhub_secret = fake_secret('credhub');
my $novel_secret   = fake_secret('novel');
my $was_secret     = fake_secret('was');

subtest 'credential values are replaced by a byte count' => sub {
	my $log = capture_trace {
		run({env => {
			BOSH_ENVIRONMENT   => 'https://10.0.0.6:25555',
			BOSH_CLIENT_SECRET => $bosh_secret,
			CREDHUB_SECRET     => $credhub_secret,
		}}, 'true');
	};
	unlike($log, qr/\Q$bosh_secret\E/,    'the BOSH client secret is not in the trace');
	unlike($log, qr/\Q$credhub_secret\E/, 'the CredHub secret is not in the trace');
	like($log, qr/BOSH_CLIENT_SECRET='<redacted:@{[length $bosh_secret]} bytes>'/,
		'the BOSH client secret is named with its length');
	like($log, qr/CREDHUB_SECRET='<redacted:@{[length $credhub_secret]} bytes>'/,
		'the CredHub secret is named with its length');
	like($log, qr{BOSH_ENVIRONMENT='https://10\.0\.0\.6:25555'},
		'an allowlisted key still shows its value');
};

subtest 'a key nobody has seen before is redacted too' => sub {
	my $log = capture_trace {
		run({env => {SOMETHING_NEW_AND_SECRET => $novel_secret}}, 'true');
	};
	unlike($log, qr/\Q$novel_secret\E/, 'an unknown key does not leak its value');
	like($log, qr/SOMETHING_NEW_AND_SECRET='<redacted:\d+ bytes>'/,
		'an unknown key is still named');
};

subtest 'an unset key does not show what it was' => sub {
	local $ENV{BOSH_CLIENT_SECRET} = $was_secret;
	local $ENV{BOSH_DEPLOYMENT} = 'my-deployment';
	my $log = capture_trace {
		run({env => {BOSH_CLIENT_SECRET => undef, BOSH_DEPLOYMENT => undef}}, 'true');
	};
	unlike($log, qr/\Q$was_secret\E/, 'the old value of an unset credential is not traced');
	like($log, qr/BOSH_CLIENT_SECRET unset - was '<redacted:\d+ bytes>'/,
		'the unset credential is named with its length');
	like($log, qr/BOSH_DEPLOYMENT unset - was 'my-deployment'/,
		'an allowlisted key still shows what it was');
};

subtest 'redact_env still hides every value' => sub {
	my $log = capture_trace {
		run({redact_env => 1, env => {BOSH_ENVIRONMENT => 'https://10.0.0.6:25555'}}, 'true');
	};
	unlike($log, qr/10\.0\.0\.6/, 'redact_env hides even allowlisted values');
	like($log, qr/BOSH_ENVIRONMENT='<redacted>'/, 'redact_env keeps its existing form');
};

subtest 'the command still receives the real values' => sub {
	my $out;
	capture_trace {
		$out = run({env => {BOSH_CLIENT_SECRET => $bosh_secret}}, 'printf "%s" "$BOSH_CLIENT_SECRET"');
	};
	is($out, $bosh_secret, 'redaction is for the trace only');
};

subtest 'endpoints show only their scheme, host, and port' => sub {
	my %pw = map {$_ => fake_secret("userinfo-$_")} qw/bosh credhub vault safe target exodus/;
	my $log = capture_trace {
		run({env => {
			BOSH_ENVIRONMENT     => "https://admin:$pw{bosh}\@10.0.0.6:25555/info?x=1",
			CREDHUB_SERVER       => "https://user:$pw{credhub}\@10.0.0.6:8844",
			VAULT_ADDR           => "https://$pw{vault}\@10.0.0.5:8200/",
			SAFE_TARGET          => "https://u:$pw{safe}\@10.0.0.5",
			GENESIS_TARGET_VAULT => "https://u:$pw{target}\@10.0.0.5",
			BOSH_EXODUS_VAULT    => "https://u:$pw{exodus}\@10.0.0.5",
		}}, 'true');
	};
	unlike($log, qr/\Q$pw{$_}\E/, "the $_ userinfo is not in the trace") for sort keys %pw;
	like($log, qr{BOSH_ENVIRONMENT='https://10\.0\.0\.6:25555'}, 'the endpoint itself stays in view');
	like($log, qr{VAULT_ADDR='https://10\.0\.0\.5:8200'}, 'with its port');

	$log = capture_trace {
		run({env => {BOSH_ENVIRONMENT => 'fake-alias', VAULT_ADDR => "not a url $pw{vault}"}}, 'true');
	};
	like($log, qr{BOSH_ENVIRONMENT='fake-alias'}, 'a bare name or host is shown');
	unlike($log, qr/\Q$pw{vault}\E/, 'anything else is redacted');
};

subtest 'a vault descriptor is free-form, so its value is redacted' => sub {
	my $descriptor = fake_secret('descriptor');
	my $log = capture_trace {
		run({env => {GENESIS_ENV_VAULT_DESCRIPTOR => "https://u:$descriptor\@10.0.0.5"}}, 'true');
	};
	unlike($log, qr/\Q$descriptor\E/, 'the descriptor is not in the trace');
};

subtest 'the director built from the environment logs its endpoint safely' => sub {
	require Service::BOSH::Director;
	my $pw = fake_secret('director-userinfo');
	no warnings 'redefine';
	local *Service::BOSH::Director::new = sub { bless({}, $_[0]) };
	local $ENV{BOSH_ENVIRONMENT} = "https://admin:$pw\@10.0.0.6:25555";
	local $ENV{BOSH_CLIENT} = 'admin';
	my $log = capture_trace { Service::BOSH::Director->from_environment };
	like($log, qr/BOSH_ENVIRONMENT=https:\/\/10\.0\.0\.6:25555/, 'the endpoint is logged');
	unlike($log, qr/\Q$pw\E/, 'its userinfo is not');
};

done_testing;
