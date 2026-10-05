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
# Service::Vault::kv_mount, kv_read, kv_write, and kv_delete
#
# Whole-secret reads and writes through `safe curl`, which is what a
# check-and-set write on a kv v2 mount needs: safe set merges into what it
# reads and names no version, so it cannot refuse a write that lost a race.
#
# The stub below prints what safe itself prints.  Without --data-only, every
# safe Genesis accepts prints the whole response, status line first.  With
# it, only the body is printed.  From safe 1.20 a refused request also exits
# 1 and names the status on stderr; before 1.20 safe exits 0 whatever the
# vault answered, so on those versions the status line is the only place a
# refusal shows.  Each subtest runs against both.
# ===========================================================================

our $SAFE = '1.24';
my %REASON = (
	200 => 'OK', 204 => 'No Content', 400 => 'Bad Request', 403 => 'Forbidden',
	404 => 'Not Found', 500 => 'Internal Server Error', 503 => 'Service Unavailable',
);

sub make_vault {
	return Service::Vault->new(
		'https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/'
	);
}

# What `safe curl [--data-only] METHOD URI [BODY]` prints for a reply of
# [status, body, %opts], or for {fail => message}, a request that never
# reached the vault.  opts may ask for a chunked body, or a protocol.
sub safe_prints {
	my ($data_only, $method, $uri, $reply) = @_;
	return ('', 1, "!! $reply->{fail}") if ref($reply) eq 'HASH';

	my ($status, $body, %opts) = @$reply;
	$body = defined($body) ? (ref($body) ? encode_json($body) : $body) : '';
	my $reason = $REASON{$status} // 'Unknown';
	my $out;
	if ($data_only) {
		$out = "$body\n";
	} else {
		my $proto = $opts{proto} // 'HTTP/1.1';
		my @headers = ("$proto $status $reason", 'Content-Type: application/json');
		my $wire = $body;
		if ($opts{chunked}) {
			# How Go's DumpResponse writes a chunked response: re-chunked
			push @headers, 'Transfer-Encoding: chunked';
			my $half = int(length($body) / 2);
			$wire = join('', map {sprintf("%x\r\n%s\r\n", length($_), $_)} grep {length} substr($body, 0, $half), substr($body, $half))
				. "0\r\n\r\n";
		} else {
			push @headers, 'Content-Length: '.length($body);
		}
		$out = join("\r\n", @headers)."\r\n\r\n$wire\n";
	}
	return ($out, 1, "!! $method $uri: $status $reason")
		if $status >= 400 && $SAFE ne '1.19';
	return ($out, 0, '');
}

# Answers each "METHOD /uri" from a table, and records every call.
sub stub_curl {
	my ($v, %replies) = @_;
	$v->{__calls} = [];
	$v->{__test_query} = sub {
		my (@args) = @_;
		shift @args if $args[0] eq 'safe';
		die "expected a safe curl call, got: @args\n" unless shift(@args) eq 'curl';
		my $data_only = $args[0] eq '--data-only' ? shift(@args) : 0;
		my ($method, $uri, $body) = @args;
		push @{$v->{__calls}}, {method => $method, uri => $uri, body => $body, data_only => $data_only};
		my $reply = $replies{"$method $uri"};
		$reply = $reply->() if ref($reply) eq 'CODE';
		return ('', 1, "!! no stub for $method $uri") unless $reply;
		return safe_prints($data_only, $method, $uri, $reply);
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

my $V2_MOUNT = [200, {data => {path => 'secret/', type => 'kv', options => {version => '2'}}}];
my $V1_MOUNT = [200, {data => {path => 'secret/', type => 'kv', options => {version => '1'}}}];
my $NOT_FOUND = [404, {errors => []}];
my $UI = 'GET /sys/internal/ui/mounts/secret/exodus/lab/bosh/network-claim-lock';
my $PATH = 'secret/exodus/lab/bosh/network-claim-lock';
my $V2_DATA = '/secret/data/exodus/lab/bosh/network-claim-lock';

for my $safe ('1.24', '1.19') {
	local $SAFE = $safe;

	subtest "safe $safe: kv_mount reads the mount and its version, and remembers it" => sub {
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
		stub_curl($generic, $UI => [200, {data => {path => 'secret/', type => 'generic', options => undef}}]);
		is($generic->kv_mount($PATH)->{version}, 1, 'a generic mount, which is kv v1 by another name, is version 1');

		my $old = make_vault();
		stub_curl($old, $UI => $NOT_FOUND);
		is($old->kv_mount($PATH)->{version}, 1, 'a vault without the endpoint predates kv v2, so its mount is version 1');
	};

	subtest "safe $safe: kv_mount refuses a path it cannot place" => sub {
		my $v = make_vault();
		stub_curl($v, $UI => [403, {errors => ["1 error occurred:\n\t* permission denied\n\n"]}]);
		throws_ok { $v->kv_mount($PATH) } qr/Could not tell which kv mount.*permission denied.*Likely causes/s,
			'a refusal says what failed, why, and what to check';

		my $cubby = make_vault();
		stub_curl($cubby, $UI => [200, {data => {path => 'cubbyhole/', type => 'cubbyhole'}}]);
		throws_ok { $cubby->kv_mount($PATH) } qr/cubbyhole.*only a kv secrets engine/s,
			'a path on another kind of engine is refused';

		throws_ok { $v->kv_mount("$PATH:key") } qr/names a whole secret, not a key/,
			'a path:key is refused as a programming error';
	};

	subtest "safe $safe: kv_read on a kv v2 mount" => sub {
		my $v = make_vault();
		my $reply;
		stub_curl($v, $UI => $V2_MOUNT, "GET $V2_DATA" => sub { $reply });

		$reply = $NOT_FOUND;
		is_deeply($v->kv_read($PATH), {data => undef, version => 0, kv_version => 2},
			'a secret never written has no data and is version 0');

		$reply = [200, {data => {data => {at => 'now'}, metadata => {version => 4, deletion_time => '', destroyed => JSON::PP::false}}}];
		is_deeply($v->kv_read($PATH), {data => {at => 'now'}, version => 4, kv_version => 2},
			'a written secret has its data and its version');

		$reply = [200, {data => {data => {}, metadata => {version => 5}}}];
		is_deeply($v->kv_read($PATH), {data => {}, version => 5, kv_version => 2},
			'a secret written empty has empty data');

		$reply = [404, {data => {data => undef, metadata => {version => 6, deletion_time => '2026-10-05T15:03:41Z'}}}];
		is_deeply($v->kv_read($PATH), {data => undef, version => 6, kv_version => 2},
			'a deleted latest version has no data, but keeps its version for the next check-and-set');

		$reply = [503, {errors => ['Vault is sealed']}];
		throws_ok { $v->kv_read($PATH) } qr/Could not read.*Vault is sealed.*Likely causes/s,
			'a sealed vault is a failure, not an absent secret';

		$reply = [403, {errors => ["1 error occurred:\n\t* permission denied\n\n"]}];
		throws_ok { $v->kv_read($PATH) } qr/Could not read.*permission denied/s,
			'a refused read is a failure, not an absent secret';

		$reply = {fail => "Get \"https://vault.example.com:8200/v1/x\": dial tcp: connection refused"};
		throws_ok { $v->kv_read($PATH) } qr/Could not read.*connection refused/s,
			'an unreachable vault is a failure, not an absent secret';
	};

	subtest "safe $safe: kv_read on a kv v1 mount" => sub {
		my $v = make_vault();
		my $reply;
		stub_curl($v, $UI => $V1_MOUNT, "GET /$PATH" => sub { $reply });

		$reply = $NOT_FOUND;
		is_deeply($v->kv_read($PATH), {data => undef, version => undef, kv_version => 1},
			'a missing secret has no data and no version');
		$reply = [200, {data => {at => 'now'}}];
		is_deeply($v->kv_read($PATH), {data => {at => 'now'}, version => undef, kv_version => 1},
			'a written secret has its data, and kv v1 keeps no version');

		$reply = [403, {errors => ['permission denied']}];
		throws_ok { $v->kv_read($PATH) } qr/Could not read.*permission denied/s,
			'a refused read is a failure, not a missing secret';
		$reply = [503, {errors => ['Vault is sealed']}];
		throws_ok { $v->kv_read($PATH) } qr/Could not read.*Vault is sealed/s,
			'and so is a sealed vault';
	};

	subtest "safe $safe: kv_write on a kv v2 mount" => sub {
		my $v = make_vault();
		my $reply;
		stub_curl($v, $UI => $V2_MOUNT, "POST $V2_DATA" => sub { $reply });

		$reply = [200, {data => {version => 1, created_time => 'now'}}];
		is($v->kv_write($PATH, {at => 'now'}, cas => 0), 1, 'a check-and-set write returns the version it made');
		is_deeply(decode_json($v->{__calls}[-1]{body}), {data => {at => 'now'}, options => {cas => 0}},
			'and names the version it expects in the request');

		$reply = [400, {errors => ['check-and-set parameter did not match the current version']}];
		is($v->kv_write($PATH, {at => 'later'}, cas => 0), 0, 'a write that lost the race returns 0 rather than dying');

		$reply = [200, {data => {version => 3}}];
		is($v->kv_write($PATH, {at => 'now'}), 3, 'a write without check-and-set returns the version too');
		ok(!exists(decode_json($v->{__calls}[-1]{body})->{options}), 'and sends no options');

		$reply = [403, {errors => ["1 error occurred:\n\t* permission denied\n\n"]}];
		throws_ok { $v->kv_write($PATH, {at => 'now'}, cas => 3) }
			qr/Could not write.*permission denied.*secret\/data\/exodus\/lab\/bosh\/network-claim-lock/s,
			'a refused write dies, naming the data path a policy has to grant';

		$reply = [400, {errors => ['invalid request']}];
		throws_ok { $v->kv_write($PATH, {at => 'now'}, cas => 3) } qr/Could not write.*invalid request/s,
			'a 400 that is not a check-and-set mismatch is still a failure';

		throws_ok { $v->kv_write($PATH, {at => 'now'}, cas => 'x') } qr/not a whole number/,
			'a check-and-set version must be a number';
	};

	subtest "safe $safe: kv_write on a kv v1 mount" => sub {
		my $v = make_vault();
		my $reply = [204, undef];
		stub_curl($v, $UI => $V1_MOUNT, "POST /$PATH" => sub { $reply });
		is($v->kv_write($PATH, {at => 'now'}), 1, 'a plain write succeeds');
		is_deeply(decode_json($v->{__calls}[-1]{body}), {at => 'now'}, 'and sends the data as it is');
		throws_ok { $v->kv_write($PATH, {at => 'now'}, cas => 0) } qr/kv v1 has no check-and-set/,
			'a check-and-set write is refused as a programming error';

		$reply = [403, {errors => ['permission denied']}];
		throws_ok { $v->kv_write($PATH, {at => 'now'}) } qr/Could not write.*permission denied/s,
			'a refused write is a failure';
	};

	subtest "safe $safe: kv_delete" => sub {
		my $v = make_vault();
		my $reply = [204, undef];
		stub_curl($v, $UI => $V1_MOUNT, "DELETE /$PATH" => sub { $reply });
		is($v->kv_delete($PATH), 1, 'a delete the vault accepts returns 1');
		is($v->{__calls}[-1]{method}, 'DELETE', 'and was sent as a DELETE');

		$reply = [403, {errors => ['permission denied']}];
		throws_ok { $v->kv_delete($PATH) } qr/Could not delete.*permission denied.*Likely causes/s,
			'a refused delete is a failure naming the reason';

		$reply = {fail => 'dial tcp: connection refused'};
		throws_ok { $v->kv_delete($PATH) } qr/Could not delete.*connection refused/s,
			'and so is an unreachable vault';

		my $v2 = make_vault();
		stub_curl($v2, $UI => $V2_MOUNT, "DELETE $V2_DATA" => [204, undef]);
		is($v2->kv_delete($PATH), 1, 'on kv v2 the latest version of the data path is deleted');
	};
}

subtest 'every request reads the status line, so safe before 1.20 is covered too' => sub {
	my $v = make_vault();
	stub_curl($v, $UI => $V2_MOUNT, "GET $V2_DATA" => $NOT_FOUND);
	$v->kv_read($PATH);
	ok(!grep({$_->{data_only}} @{$v->{__calls}}), 'no request asks safe for the body alone');
};

subtest 'a chunked response, as Go prints one, is read' => sub {
	my $v = make_vault();
	stub_curl($v,
		$UI => [200, {data => {path => 'secret/', type => 'kv', options => {version => '2'}}}, chunked => 1],
		"GET $V2_DATA" => [200, {data => {data => {at => 'now', user => 'ops'}, metadata => {version => 7}}}, chunked => 1],
	);
	is_deeply($v->kv_read($PATH), {data => {at => 'now', user => 'ops'}, version => 7, kv_version => 2},
		'the chunks are joined back into the body');
};

subtest 'an HTTP/2 response is read' => sub {
	my $v = make_vault();
	stub_curl($v,
		$UI => [@$V2_MOUNT, proto => 'HTTP/2.0'],
		"GET $V2_DATA" => [404, {errors => []}, proto => 'HTTP/2.0'],
	);
	is_deeply($v->kv_read($PATH), {data => undef, version => 0, kv_version => 2}, 'the status line is read');
};

subtest 'kv_write waits for a lagging read on an HA vault' => sub {
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '1';
	local $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT} = '0.5';
	my $v = make_vault();
	my @versions = (1, 1, 2);
	stub_curl($v,
		$UI => $V2_MOUNT,
		"POST $V2_DATA" => [200, {data => {version => 2}}],
		"GET $V2_DATA" => sub {
			[200, {data => {data => {}, metadata => {version => shift(@versions) // 1}}}]
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
