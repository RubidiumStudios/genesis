#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;
use Test::Exception;
use Test::Output;
use POSIX qw(strftime);
use JSON::PP ();

use_ok 'Service::Vault';
use_ok 'Service::Vault::Remote';
use_ok 'Service::BOSH::Director';
use Genesis;

# ===========================================================================
# The network claims lock against a real vault
#
# kv v1 is what Vault mounted before 1.1 and what many long-lived Genesis
# vaults still have.  Which version the test vault mounts secret/ as is the
# harness's business, so a mount of each version is added beside it and
# every test names the one it means.  The lock is read, written, and
# removed through safe, the same way on both.
# ===========================================================================

my $target = vault_ok('genesis-ci-network-lock');
system("SAFE_TARGET=$target safe set /secret/handshake knock=knock >/dev/null 2>&1");
is($? >> 8, 0, 'wrote the handshake secret');
system(qq{SAFE_TARGET=$target safe curl POST /sys/mounts/kv1 '{"type":"kv","options":{"version":"1"}}' >/dev/null 2>&1});
is($? >> 8, 0, 'mounted a kv v1 engine at kv1/');
system(qq{SAFE_TARGET=$target safe curl POST /sys/mounts/kv2 '{"type":"kv","options":{"version":"2"}}' >/dev/null 2>&1});
is($? >> 8, 0, 'mounted a kv v2 engine at kv2/');

Service::Vault->clear_all();
my $vault = Service::Vault::Remote->target($target);
local $ENV{GENESIS_BOSH_COMMAND};
fake_bosh('');
Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});

# Lets a test run code just before the first write a director sends.
package HookedVault {
	sub new { my ($class, $vault) = @_; bless {vault => $vault}, $class }
	sub before_next_write { $_[0]{hook} = $_[1] }
	sub url { $_[0]{vault}->url }
	sub read_flattened_secret { my $self = shift; $self->{vault}->read_flattened_secret(@_) }
	sub clear { my $self = shift; $self->{vault}->clear(@_) }
	sub set {
		my $self = shift;
		my $hook = delete $self->{hook};
		$hook->() if $hook;
		$self->{vault}->set(@_);
	}
}

sub director {
	my ($exodus, $v) = @_;
	return Service::BOSH::Director->new(
		'lock-it',
		url          => 'https://127.0.0.1:25555',
		ca_cert      => 'ca_cert',
		client       => 'admin',
		secret       => 'password',
		exodus_path  => $exodus,
		exodus_vault => $v // $vault,
	);
}

sub as_other_process {
	my ($code) = @_;
	no warnings 'once';
	my $pid = $$;
	local $Service::BOSH::Director::NETWORK_LOCK_TOKENS{$pid} = 'other-process-token';
	return $code->();
}

sub try_acquire {
	my ($bosh) = @_;
	return eval { quietly { $bosh->acquire_network_lock() }; 1 } ? 'won' : "refused: $@";
}

sub at { strftime('%Y-%m-%d %H:%M:%S +0000', gmtime(time - $_[0])) }

# What the vault itself holds for a secret, as the JSON it stores, or undef
# where it holds nothing.
sub stored_json {
	my ($mount, $kv_version, $rest) = @_;
	my $uri = $kv_version == 2 ? "/$mount/data/$rest" : "/$mount/$rest";
	my $out = `SAFE_TARGET=$target safe curl --data-only GET $uri 2>/dev/null`;
	my $body = eval { JSON::PP::decode_json($out) } or return undef;
	my $data = $kv_version == 2 ? $body->{data}{data} : $body->{data};
	return ref($data) eq 'HASH' ? $data : undef;
}

# Writes a secret straight to the vault's API, as a writer that does not go
# through safe's string-only set does.
sub store_json {
	my ($mount, $kv_version, $rest, $record) = @_;
	my ($uri, $body) = $kv_version == 2
		? ("/$mount/data/$rest", JSON::PP::encode_json({data => $record}))
		: ("/$mount/$rest", JSON::PP::encode_json($record));
	system('sh', '-c', 'SAFE_TARGET="$1" safe curl POST "$2" "$3" >/dev/null 2>&1', 'sh', $target, $uri, $body);
	return $? >> 8;
}

subtest 'kv_mount tells the two mounts apart' => sub {
	is($vault->kv_mount('kv1/exodus/lock-it/bosh/network-claim-lock')->{version}, 1, 'kv1/ is kv v1');
	is($vault->kv_mount('kv2/exodus/lock-it/bosh/network-claim-lock')->{version}, 2, 'kv2/ is kv v2');
};

subtest 'kv_read and kv_write against kv v2' => sub {
	my $path = 'kv2/test/versioned';
	is_deeply($vault->kv_read($path), {data => undef, version => 0, kv_version => 2},
		'a secret never written is version 0');
	is($vault->kv_write($path, {a => 1}, cas => 0), 1, 'a create-only write makes version 1');
	is($vault->kv_write($path, {a => 2}, cas => 0), 0, 'a second create-only write is refused by the vault');
	is_deeply($vault->kv_read($path), {data => {a => 1}, version => 1, kv_version => 2},
		'and the first write is what is stored');
	is($vault->kv_write($path, {}, cas => 1), 2, 'an empty record can be written at the version read');
	is_deeply($vault->kv_read($path), {data => {}, version => 2, kv_version => 2}, 'and reads back empty');
	system("SAFE_TARGET=$target safe curl DELETE /kv2/data/test/versioned >/dev/null 2>&1");
	is_deeply($vault->kv_read($path), {data => undef, version => 2, kv_version => 2},
		'a deleted latest version reads as no data, keeping its version');
	is($vault->kv_write($path, {a => 3}, cas => 2), 3, 'so the next check-and-set write names it and succeeds');
};

subtest 'kv_read and kv_write against kv v1' => sub {
	my $path = 'kv1/test/unversioned';
	is_deeply($vault->kv_read($path), {data => undef, version => undef, kv_version => 1}, 'a missing secret has no data');
	is($vault->kv_write($path, {a => 1}), 1, 'a plain write succeeds');
	is_deeply($vault->kv_read($path)->{data}, {a => 1}, 'and reads back');
	throws_ok { $vault->kv_write($path, {}) } qr/Could not write.*missing data fields/s,
		'kv v1 refuses a record with no fields, which is why a released lock is deleted there';
	throws_ok { $vault->kv_write($path, {a => 2}, cas => 0) } qr/kv v1 has no check-and-set/,
		'a check-and-set write is refused before anything is sent';
	is($vault->kv_delete($path), 1, 'a delete succeeds');
	is($vault->kv_read($path)->{data}, undef, 'and the secret is gone');
};

for my $kv_version (1, 2) {
	my $mount = "kv$kv_version";
	my $name = "kv v$kv_version";

	subtest "$name: the lock is taken, read, refused to a second taker, and released" => sub {
		my $exodus = "$mount/exodus/lock-it/bosh";
		my $bosh = director($exodus);
		is($bosh->check_network_lock->{status}, 'unlocked', 'a director with no lock is unlocked');
		is(try_acquire($bosh), 'won', 'the lock is taken');

		my $stored = stored_json($mount, $kv_version, 'exodus/lock-it/bosh/network-claim-lock');
		is_deeply([sort keys %{$stored // {}}], [qw(at env hostname pid token user)],
			'the vault holds every field of the lock');
		is_deeply([grep { ref($stored->{$_}) || Service::Vault::_export_value_type($stored->{$_}) } sort keys %$stored], [],
			'each as a JSON string');
		is($stored->{pid}, "$$", 'with this process\'s pid');
		like($stored->{at}, qr/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \+0000$/, 'and the time in UTC, spaces and all');

		my $status = $bosh->check_network_lock;
		is($status->{status}, 'locked', 'the director reads as locked');
		is_deeply($status->{lock}, $stored, 'by the record the vault holds');
		ok($bosh->network_locked_by_me, 'which is this process\'s own');
		ok($bosh->ensure_network_lock_held('write the network claims'), 'so it may write its claims');
		like(as_other_process(sub { try_acquire(director($exodus)) }), qr/^refused: .*held by.*pid: $$/s,
			'a second take is refused, naming the holder');

		ok($bosh->clear_network_lock, 'the holder releases it');
		is($vault->read_flattened_secret("$exodus/network-claim-lock"), undef, 'which leaves nothing to read at the lock path');
		is($bosh->check_network_lock->{status}, 'unlocked', 'and the director is unlocked');
		ok(!$bosh->clear_network_lock, 'a second release removes nothing');
		is(try_acquire($bosh), 'won', 'and the lock can be taken again');
		ok($bosh->clear_network_lock, 'and released again');
	};

	subtest "$name: two acquirers that both read a free lock" => sub {
		my $exodus = "$mount/exodus/race/bosh";
		my $hooked = HookedVault->new($vault);
		my ($later, $earlier) = (director($exodus, $hooked), director($exodus));

		# The earlier process reads and writes between the later one's read
		# and the later one's write.
		my $earlier_result;
		$hooked->before_next_write(sub {
			$earlier_result = as_other_process(sub { try_acquire($earlier) });
		});
		is(try_acquire($later), 'won', 'the later writer takes the lock');
		is($earlier_result, 'won', 'as the earlier one did, a moment before');

		ok($later->network_locked_by_me, 'the later write is the one the vault holds');
		ok(!as_other_process(sub { $earlier->network_locked_by_me }), 'so the earlier writer does not hold the lock');
		throws_ok { as_other_process(sub { $earlier->ensure_network_lock_held('write the network claims') }) }
			qr/Cannot write the network claims.*no longer holds/s,
			'and is stopped before it writes its claims';
		is(as_other_process(sub { quietly { $earlier->release_network_lock } }), 0, 'its release removes nothing');
		ok($later->network_locked_by_me, 'so the holder still holds the lock');
		is(quietly { $later->release_network_lock }, 1, 'until it releases it');
		is($earlier->check_network_lock->{status}, 'unlocked', 'and the director is unlocked');
	};

	subtest "$name: a stale lock is cleared only while it is the lock that was shown" => sub {
		my $exodus = "$mount/exodus/stale/bosh";
		my $path = "$exodus/network-claim-lock";
		my %crashed = (at => at(7200), hostname => 'crashed-host', user => 'crashed-user', pid => '4242', env => 'lab', token => 'crashed');
		my $bosh = director($exodus);

		$vault->set($path, %crashed);
		my $seen = $bosh->check_network_lock;
		is($seen->{status}, 'stale', 'a lock two hours old is stale');
		like($seen->{description}, qr/crashed-user\@crashed-host \(env: lab, pid: 4242\)/, 'and names who left it');

		# Another process takes it over before this one clears it.
		$vault->set($path, %crashed, at => at(10), token => 'taken-since');
		ok(!$bosh->clear_network_lock(stale => $seen), 'a lock that has changed since is not cleared');
		is($bosh->check_network_lock->{lock}{token}, 'taken-since', 'and is still there');

		$vault->set($path, %crashed);
		$seen = $bosh->check_network_lock;
		ok($bosh->clear_network_lock(stale => $seen), 'the lock that was shown is cleared');
		is($bosh->check_network_lock->{status}, 'unlocked', 'and the director is unlocked');

		$vault->set($path, %crashed);
		is(try_acquire($bosh), 'won', 'an acquire takes a stale lock over');
		ok($bosh->network_locked_by_me, 'and holds it');
		ok($bosh->clear_network_lock, 'and releases it');
	};

	subtest "$name: a lock whose pid a writer stored as a number is read like any other" => sub {
		my $rest = 'exodus/typed/bosh/network-claim-lock';
		my $bosh = director("$mount/exodus/typed/bosh");
		is(store_json($mount, $kv_version, $rest, {
			at => at(60), hostname => 'other-host', user => 'jdoe', pid => 4242, env => 'lab', token => 'typed',
		}), 0, 'the record is stored with a JSON number for its pid');
		my $status = $bosh->check_network_lock;
		is($status->{status}, 'locked', 'the lock reads as held');
		is($status->{lock}{pid}, '4242', 'with its pid');
		like(try_acquire($bosh), qr/^refused: .*jdoe\@other-host.*pid: 4242/s, 'and a take is refused, naming the holder');

		is(store_json($mount, $kv_version, $rest, {
			at => at(7200), hostname => 'other-host', user => 'jdoe', pid => 4242, env => 'lab', token => 'typed',
		}), 0, 'once it is two hours old');
		is(try_acquire($bosh), 'won', 'it is taken over');
		my $stored = stored_json($mount, $kv_version, $rest);
		is(Service::Vault::_export_value_type($stored->{pid}), undef, 'and the pid the vault now holds is a JSON string');
		ok($bosh->clear_network_lock, 'and the lock is released');
	};
}

subtest 'kv v2: a lock released by writing an empty record holds nothing' => sub {
	# A build that released the lock with a check-and-set write of a record
	# with no fields left a secret there with no keys.
	my $rest = 'exodus/emptied/bosh/network-claim-lock';
	my $bosh = director('kv2/exodus/emptied/bosh');
	is(store_json('kv2', 2, $rest, {}), 0, 'an empty record is stored');
	is_deeply($vault->read_flattened_secret("kv2/$rest"), {}, 'which reads as a secret with no keys');
	is($bosh->check_network_lock->{status}, 'unlocked', 'so the director is unlocked');
	is(try_acquire($bosh), 'won', 'and the lock is taken');
	ok($bosh->network_locked_by_me, 'and held');
	ok($bosh->clear_network_lock, 'and released');
	is($vault->read_flattened_secret("kv2/$rest"), undef, 'leaving nothing to read');
};

# Last, because nothing can be read once the vault is sealed.
subtest 'a sealed vault: the lock is never read as free' => sub {
	my $exodus = 'kv2/exodus/sealed/bosh';
	my $bosh = director($exodus);
	is(try_acquire($bosh), 'won', 'the lock is taken');
	system("SAFE_TARGET=$target safe curl PUT /sys/seal >/dev/null 2>&1");
	is($? >> 8, 0, 'the vault is sealed');

	throws_ok { $bosh->check_network_lock } qr/Could not read .*\Q$exodus\E\/network-claim-lock/s,
		'the check raises, naming what it could not read';
	throws_ok { $bosh->ensure_network_lock_held('write the network claims') } qr/Could not read/,
		'so does the check made before a write';
	like(as_other_process(sub { try_acquire(director($exodus)) }), qr/^refused: .*could not be checked.*Could not read/s,
		'and an acquire stops at its first read');

	my ($released, $out);
	lives_ok { $out = join('', output_from(sub { $released = $bosh->release_network_lock })) }
		'a release does not die';
	ok(!defined($released), 'and reports that it could not release');
	like($out =~ s/\s+/ /gr, qr/could not be read, so it is not known whether this process holds it/,
		'saying that the lock could not be read');
};

END { teardown_vault() }
done_testing;
