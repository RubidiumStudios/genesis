#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;
use Test::Exception;

use_ok 'Service::Vault';
use_ok 'Service::Vault::Remote';
use_ok 'Service::BOSH::Director';
use Genesis;

# ===========================================================================
# The network claims lock against a real vault
#
# The test vault mounts secret/ as kv v1, which is what Vault did before
# 1.1 and what many long-lived Genesis vaults still have, so a kv v2 mount
# is added beside it.  On kv v2 the vault's own check-and-set decides the
# race; on kv v1 the lock falls back to reading itself back.
# ===========================================================================

my $target = vault_ok('genesis-ci-network-lock');
system("SAFE_TARGET=$target safe set /secret/handshake knock=knock >/dev/null 2>&1");
is($? >> 8, 0, 'wrote the handshake secret');
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
	sub kv_read { my $self = shift; $self->{vault}->kv_read(@_) }
	sub kv_write {
		my $self = shift;
		my $hook = delete $self->{hook};
		$hook->() if $hook;
		$self->{vault}->kv_write(@_);
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
		exodus_vault => $v,
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

subtest 'kv_mount tells the two mounts apart' => sub {
	is($vault->kv_mount('secret/exodus/lock-it/bosh/network-claim-lock')->{version}, 1, 'secret/ is kv v1');
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
	my $path = 'secret/test/unversioned';
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

subtest 'kv v2: two acquirers that both read a free lock before either writes' => sub {
	my $exodus = 'kv2/exodus/lock-it/bosh';
	my $hooked = HookedVault->new($vault);
	my ($first, $second) = (director($exodus, $hooked), director($exodus, $vault));

	my $second_result;
	$hooked->before_next_write(sub {
		$second_result = as_other_process(sub { try_acquire($second) });
	});
	my $first_result = try_acquire($first);

	is(scalar(grep { $_ eq 'won' } $first_result, $second_result), 1,
		'exactly one takes the lock')
		or diag "first: $first_result\nsecond: $second_result";
	is($second_result, 'won', 'the one whose write reached the vault first');
	like($first_result, qr/^refused: .*between this process's check/s,
		'the other is refused, and told it lost the race')
		or diag $first_result;
	ok(as_other_process(sub { $second->network_locked_by_me }), 'the winner holds the lock');
	ok(!$first->network_locked_by_me, 'the loser does not');

	ok(as_other_process(sub { $second->clear_network_lock }), 'the winner releases it');
	is($first->check_network_lock->{status}, 'unlocked', 'and the director is unlocked');
	is(try_acquire($first), 'won', 'so the other can take it now');
	ok($first->clear_network_lock, 'and release it');
};

subtest 'kv v1: the lock is taken, confirmed, and released' => sub {
	no warnings 'once';
	local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;
	my $bosh = director('secret/exodus/lock-it/bosh', $vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');
	ok($bosh->network_locked_by_me, 'and read back as this process\'s own');
	like(try_acquire(director('secret/exodus/lock-it/bosh', $vault)), qr/^refused: .*held by/s,
		'a second take is refused');
	ok($bosh->clear_network_lock, 'the holder releases it');
	is($bosh->check_network_lock->{status}, 'unlocked', 'and the director is unlocked');
};

END { teardown_vault() }
done_testing;
