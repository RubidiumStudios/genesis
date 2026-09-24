#!/usr/bin/env perl
# The suite's vault runs whichever installed secrets engine
# GENESIS_TEST_SECRETS_ENGINE names, vault 1.14.4 unless told otherwise, and a
# run that asks for one not installed stops and names the command that
# installs it rather than downloading anything.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use JSON::PP qw/decode_json/;

# What the running server says it is.
sub server_version {
	my ($target) = @_;
	my $json = `curl -sf $helper::VAULT_URL{$target}/v1/sys/health`;
	return eval {decode_json($json)->{version}} // '';
}

subtest 'the default engine is vault 1.14.4' => sub {
	plan tests => 2;

	delete local $ENV{GENESIS_TEST_SECRETS_ENGINE};
	my $target = vault_start('helper-engine-default');
	is(server_version($target), '1.14.4', 'the server is vault 1.14.4');

	my $url = $helper::VAULT_URL{$target};
	teardown_vault($target);
	my $deadline = time + 10;
	sleep 1 while system("curl -sf $url/v1/sys/health >/dev/null 2>&1") == 0 && time < $deadline;
	isnt(system("curl -sf $url/v1/sys/health >/dev/null 2>&1"), 0,
		'and tearing it down stops the server, not just the command that started it');
};

subtest 'an engine not installed is named, not fetched' => sub {
	plan tests => 2;

	local $ENV{GENESIS_TEST_SECRETS_ENGINE} = 'vault@0.0.0';
	eval {vault_start('helper-engine-missing')};
	like($@, qr/make install-secrets-engine ENGINE=vault VERSION=0\.0\.0/,
		'the start refuses and names the command that installs it');
	ok(!-e "$helper::TOPDIR/t/engines/vault/0.0.0", 'and nothing was downloaded');
};

subtest 'OpenBao runs when asked for' => sub {
	my ($installed) = map {m{/([^/]+)$}} reverse sort glob "$helper::TOPDIR/t/engines/bao/*";
	plan skip_all => 'no OpenBao installed; make install-secrets-engine ENGINE=bao VERSION=<v>'
		unless $installed;
	plan tests => 1;

	local $ENV{GENESIS_TEST_SECRETS_ENGINE} = "bao\@$installed";
	my $target = vault_start('helper-engine-bao');
	like(server_version($target), qr/^\Q$installed\E\b/, "the server is OpenBao $installed");
	teardown_vault($target);
};

done_testing;
