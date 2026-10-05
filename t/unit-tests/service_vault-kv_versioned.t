#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;
use Test::Exception;
use JSON::PP qw/decode_json encode_json/;

use_ok 'Service::Vault';
use Genesis;

# ===========================================================================
# Service::Vault::kv_mount, kv_read, and kv_write
#
# Whole-secret reads and writes through `safe curl`, which is what a
# check-and-set write on a kv v2 mount needs: safe set merges into what it
# reads and names no version, so it cannot refuse a write that lost a race.
#
# The replies below are the ones Vault 1.0.2 and OpenBao 2 give through
# `safe curl --data-only`: the body on stdout, and for a refused request a
# non-zero exit with "!! METHOD /uri: NNN Status" on stderr.
# ===========================================================================

sub make_vault {
	return Service::Vault->new(
		'https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/'
	);
}

# Answers each "METHOD /uri" from a table, and records every call.
sub stub_curl {
	my ($v, %replies) = @_;
	$v->{__calls} = [];
	$v->{__test_query} = sub {
		my (@args) = @_;
		shift @args if $args[0] eq 'safe';
		die "expected a safe curl call, got: @args\n" unless $args[0] eq 'curl';
		my (undef, undef, $method, $uri, $body) = @args;
		push @{$v->{__calls}}, {method => $method, uri => $uri, body => $body};
		my $reply = $replies{"$method $uri"};
		$reply = $reply->() if ref($reply) eq 'CODE';
		return ('', 1, "!! no stub for $method $uri") unless $reply;
		return @$reply;
	};
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

local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';

my $V2_MOUNT = [encode_json({data => {path => 'secret/', type => 'kv', options => {version => '2'}}}), 0, ''];
my $V1_MOUNT = [encode_json({data => {path => 'secret/', type => 'kv', options => {version => '1'}}}), 0, ''];
my $NOT_FOUND = sub { [encode_json({errors => []}), 1, "!! GET $_[0]: 404 Not Found"] };
my $UI = 'GET /sys/internal/ui/mounts/secret/exodus/lab/bosh/network-claim-lock';
my $PATH = 'secret/exodus/lab/bosh/network-claim-lock';

subtest 'kv_mount reads the mount and its version, and remembers it' => sub {
	my $v = make_vault();
	stub_curl($v, $UI => $V2_MOUNT);
	is_deeply($v->kv_mount($PATH), {path => 'secret/', type => 'kv', version => 2},
		'a kv v2 mount is reported as version 2');
	is_deeply($v->kv_mount("/$PATH/"), {path => 'secret/', type => 'kv', version => 2},
		'leading and trailing slashes name the same secret');
	is(scalar(@{$v->{__calls}}), 1, 'and the mount is asked about only once');

	my $v1 = make_vault();
	stub_curl($v1, $UI => $V1_MOUNT);
	is($v1->kv_mount($PATH)->{version}, 1, 'a kv v1 mount is reported as version 1');

	my $generic = make_vault();
	stub_curl($generic, $UI => [encode_json({data => {path => 'secret/', type => 'generic', options => undef}}), 0, '']);
	is($generic->kv_mount($PATH)->{version}, 1, 'a generic mount, which is kv v1 by another name, is version 1');

	my $old = make_vault();
	stub_curl($old, $UI => $NOT_FOUND->('/sys/internal/ui/mounts/x'));
	is($old->kv_mount($PATH)->{version}, 1, 'a vault without the endpoint predates kv v2, so its mount is version 1');
};

subtest 'kv_mount refuses a path it cannot place' => sub {
	my $v = make_vault();
	stub_curl($v, $UI => [encode_json({errors => ["1 error occurred:\n\t* permission denied\n\n"]}), 1, "!! GET /x: 403 Forbidden"]);
	throws_ok { $v->kv_mount($PATH) } qr/Could not tell which kv mount.*permission denied.*Likely causes/s,
		'a refusal says what failed, why, and what to check';

	my $cubby = make_vault();
	stub_curl($cubby, $UI => [encode_json({data => {path => 'cubbyhole/', type => 'cubbyhole'}}), 0, '']);
	throws_ok { $cubby->kv_mount($PATH) } qr/cubbyhole.*only a kv secrets engine/s,
		'a path on another kind of engine is refused';

	throws_ok { $v->kv_mount("$PATH:key") } qr/names a whole secret, not a key/,
		'a path:key is refused as a programming error';
};

subtest 'kv_read on a kv v2 mount' => sub {
	my $v = make_vault();
	my $data_uri = "GET /secret/data/exodus/lab/bosh/network-claim-lock";
	my $reply;
	stub_curl($v, $UI => $V2_MOUNT, $data_uri => sub { $reply });

	$reply = $NOT_FOUND->('/secret/data/x');
	is_deeply($v->kv_read($PATH), {data => undef, version => 0, kv_version => 2},
		'a secret never written has no data and is version 0');

	$reply = [encode_json({data => {data => {at => 'now'}, metadata => {version => 4, deletion_time => '', destroyed => JSON::PP::false}}}), 0, ''];
	is_deeply($v->kv_read($PATH), {data => {at => 'now'}, version => 4, kv_version => 2},
		'a written secret has its data and its version');

	$reply = [encode_json({data => {data => {}, metadata => {version => 5}}}), 0, ''];
	is_deeply($v->kv_read($PATH), {data => {}, version => 5, kv_version => 2},
		'a secret written empty has empty data');

	$reply = [encode_json({data => {data => undef, metadata => {version => 6, deletion_time => '2026-10-05T15:03:41Z'}}}), 1, "!! GET /x: 404 Not Found"];
	is_deeply($v->kv_read($PATH), {data => undef, version => 6, kv_version => 2},
		'a deleted latest version has no data, but keeps its version for the next check-and-set');

	$reply = [encode_json({errors => ['Vault is sealed']}), 1, "!! GET /x: 503 Service Unavailable"];
	throws_ok { $v->kv_read($PATH) } qr/Could not read.*Vault is sealed.*Likely causes/s,
		'a sealed vault is a failure, not an absent secret';

	$reply = ['', 1, "!! Get \"https://vault.example.com:8200/v1/x\": dial tcp: connection refused"];
	throws_ok { $v->kv_read($PATH) } qr/Could not read.*connection refused/s,
		'an unreachable vault is a failure, not an absent secret';
};

subtest 'kv_read on a kv v1 mount' => sub {
	my $v = make_vault();
	my $reply;
	stub_curl($v, $UI => $V1_MOUNT, "GET /$PATH" => sub { $reply });

	$reply = $NOT_FOUND->("/$PATH");
	is_deeply($v->kv_read($PATH), {data => undef, version => undef, kv_version => 1},
		'a missing secret has no data and no version');
	$reply = [encode_json({data => {at => 'now'}}), 0, ''];
	is_deeply($v->kv_read($PATH), {data => {at => 'now'}, version => undef, kv_version => 1},
		'a written secret has its data, and kv v1 keeps no version');
};

subtest 'kv_write on a kv v2 mount' => sub {
	my $v = make_vault();
	my $post = "POST /secret/data/exodus/lab/bosh/network-claim-lock";
	my $reply;
	stub_curl($v, $UI => $V2_MOUNT, $post => sub { $reply });

	$reply = [encode_json({data => {version => 1, created_time => 'now'}}), 0, ''];
	is($v->kv_write($PATH, {at => 'now'}, cas => 0), 1, 'a check-and-set write returns the version it made');
	is_deeply(decode_json($v->{__calls}[-1]{body}), {data => {at => 'now'}, options => {cas => 0}},
		'and names the version it expects in the request');

	$reply = [encode_json({errors => ['check-and-set parameter did not match the current version']}), 1, "!! POST /x: 400 Bad Request"];
	is($v->kv_write($PATH, {at => 'later'}, cas => 0), 0, 'a write that lost the race returns 0 rather than dying');

	$reply = [encode_json({data => {version => 3}}), 0, ''];
	is($v->kv_write($PATH, {at => 'now'}), 3, 'a write without check-and-set returns the version too');
	ok(!exists(decode_json($v->{__calls}[-1]{body})->{options}), 'and sends no options');

	$reply = [encode_json({errors => ["1 error occurred:\n\t* permission denied\n\n"]}), 1, "!! POST /x: 403 Forbidden"];
	throws_ok { $v->kv_write($PATH, {at => 'now'}, cas => 3) }
		qr/Could not write.*permission denied.*secret\/data\/exodus\/lab\/bosh\/network-claim-lock/s,
		'a refused write dies, naming the data path a policy has to grant';

	$reply = [encode_json({errors => ['invalid request']}), 1, "!! POST /x: 400 Bad Request"];
	throws_ok { $v->kv_write($PATH, {at => 'now'}, cas => 3) } qr/Could not write.*invalid request/s,
		'a 400 that is not a check-and-set mismatch is still a failure';

	throws_ok { $v->kv_write($PATH, {at => 'now'}, cas => 'x') } qr/not a whole number/,
		'a check-and-set version must be a number';
};

subtest 'kv_write on a kv v1 mount' => sub {
	my $v = make_vault();
	stub_curl($v, $UI => $V1_MOUNT, "POST /$PATH" => ['', 0, '']);
	is($v->kv_write($PATH, {at => 'now'}), 1, 'a plain write succeeds');
	is_deeply(decode_json($v->{__calls}[-1]{body}), {at => 'now'}, 'and sends the data as it is');
	throws_ok { $v->kv_write($PATH, {at => 'now'}, cas => 0) } qr/kv v1 has no check-and-set/,
		'a check-and-set write is refused as a programming error';
};

subtest 'kv_write waits for a lagging read on an HA vault' => sub {
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '1';
	local $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT} = '0.5';
	my $v = make_vault();
	my @versions = (1, 1, 2);
	stub_curl($v,
		$UI => $V2_MOUNT,
		"POST /secret/data/exodus/lab/bosh/network-claim-lock" => [encode_json({data => {version => 2}}), 0, ''],
		"GET /secret/data/exodus/lab/bosh/network-claim-lock" => sub {
			[encode_json({data => {data => {}, metadata => {version => shift(@versions) // 1}}}), 0, '']
		},
	);
	is($v->kv_write($PATH, {at => 'now'}, cas => 1), 2, 'the write returns once a read shows its version');
	is(scalar(grep { $_->{method} eq 'GET' && $_->{uri} =~ m{/data/} } @{$v->{__calls}}), 3,
		'after reading until the version caught up');

	@versions = ();
	throws_ok { $v->kv_write($PATH, {at => 'now'}, cas => 1) } qr/reads still returned version 1.*standby/s,
		'a read that never catches up is a failure naming the likely cause';
};

done_testing;
