#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Output;
use POSIX qw(strftime);
use JSON::PP ();
use Sys::Hostname ();

use_ok "Service::BOSH";
use_ok "Service::BOSH::Director";
use Genesis;

# ===========================================================================
# The network claims lock on a BOSH director
#
# Two operators deploying against the same director at the same moment must
# not both take the lock.  Each test below drives two acquirers against one
# lock record, and the race tests force the interleaving that the old
# check-then-set code lost: both acquirers read the record before either of
# them writes it.
#
# The mock vault keeps one versioned record per path and honours a
# check-and-set version the way a kv v2 mount does, or ignores versions the
# way a kv v1 mount does.  It also answers the plain get/set/clear calls,
# so the same tests can be run against code that only knew those.
# ===========================================================================

package MockLockVault {
	sub new {
		my ($class, %opts) = @_;
		return bless {
			kv_version => $opts{kv_version} // 2,
			store      => {},   # path => {version => N, data => {...}}
			plain      => {},   # "path:key" => value
			log        => [],
		}, $class;
	}

	sub url { 'https://vault.example.com:8200' }
	sub build_descriptor { 'mock-vault' }

	# What runs just before the next write lands, and just after it.  Each
	# fires once, so the code it calls writes without re-entering it.
	sub before_next_write { $_[0]{before_write} = $_[1] }
	sub after_next_write  { $_[0]{after_write}  = $_[1] }

	sub _before { my $hook = delete $_[0]{before_write}; $hook->() if $hook }
	sub _after  { my $hook = delete $_[0]{after_write};  $hook->() if $hook }

	sub kv_read {
		my ($self, $path) = @_;
		die $self->{read_error} if $self->{read_error};
		push @{$self->{log}}, ['read', $path];
		my $rec = $self->{store}{$path};
		return {
			data       => $rec ? {%{$rec->{data}}} : undef,
			version    => $self->{kv_version} == 2 ? ($rec ? $rec->{version} : 0) : undef,
			kv_version => $self->{kv_version},
		};
	}

	sub kv_write {
		my ($self, $path, $data, %opts) = @_;
		die "kv_write was given a check-and-set version on a kv v1 mount\n"
			if exists($opts{cas}) && $self->{kv_version} != 2;
		$self->_before;
		my $rec = $self->{store}{$path} //= {version => 0, data => {}};
		if (exists $opts{cas} && $opts{cas} != $rec->{version}) {
			push @{$self->{log}}, ['cas-mismatch', $path];
			return 0;
		}
		$rec->{data} = {%$data};
		$rec->{version}++;
		push @{$self->{log}}, ['write', $path];
		$self->_after;
		# A failure after the vault accepted the write, such as a read that
		# never catches up on an HA vault, or a signal
		if (my $err = delete $self->{die_after_write}) { die $err }
		return $self->{kv_version} == 2 ? $rec->{version} : 1;
	}

	# A refused delete dies, as Service::Vault::kv_delete does.
	sub kv_delete {
		my ($self, $path) = @_;
		die "Could not delete $path from the vault: permission denied\n" if $self->{delete_refused};
		$self->_before;
		delete $self->{store}{$path};
		push @{$self->{log}}, ['write', $path];
		$self->_after;
		return 1;
	}

	# The plain calls, as the check-then-set code used them
	sub get {
		my ($self, $path, $key) = @_;
		push @{$self->{log}}, ['read', "$path:$key"];
		return $self->{plain}{"$path:$key"};
	}
	sub set {
		my ($self, $path, $key, $value) = @_;
		$self->_before;
		$self->{plain}{"$path:$key"} = $value;
		push @{$self->{log}}, ['write', "$path:$key"];
		$self->_after;
		return $value;
	}
	# Service::Vault::clear asks has() first, and a vault that refuses the
	# read answers that nothing is there, so nothing is deleted and no error
	# is raised.
	sub clear {
		my ($self, $full) = @_;
		return if $self->{delete_refused};
		$self->_before;
		delete $self->{plain}{$full};
		delete $self->{store}{$full};
		push @{$self->{log}}, ['write', $full];
		$self->_after;
		return 1;
	}

	# How many reads happened before the first write landed
	sub reads_before_first_write {
		my $self = shift;
		my $n = 0;
		for (@{$self->{log}}) { last if $_->[0] eq 'write'; $n++ if $_->[0] eq 'read' }
		return $n;
	}
}

local $ENV{GENESIS_BOSH_COMMAND};
fake_bosh('');
Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});

my $EXODUS = 'secret/exodus/lock-test/bosh';
my $LOCK_PATH = "$EXODUS/network-claim-lock";

sub director {
	my ($vault) = @_;
	return Service::BOSH::Director->new(
		'lock-test',
		url          => 'https://127.0.0.1:25555',
		ca_cert      => 'ca_cert',
		client       => 'admin',
		secret       => 'password',
		exodus_path  => $EXODUS,
		exodus_vault => $vault,
	);
}

# Runs $code as a second process would: with its own lock owner token.
sub as_other_process {
	my ($code) = @_;
	no warnings 'once';
	# A lexical key: local() does not restore an element keyed by $$ itself.
	my $pid = $$;
	local $Service::BOSH::Director::NETWORK_LOCK_TOKENS{$pid} = 'other-process-token';
	return $code->();
}

sub try_acquire {
	my ($bosh) = @_;
	return eval { quietly { $bosh->acquire_network_lock() }; 1 } ? 'won' : "refused: $@";
}

sub lock_record {
	my (%fields) = @_;
	return {
		at       => strftime('%Y-%m-%d %H:%M:%S +0000', gmtime(time - ($fields{age} // 60))),
		hostname => $fields{hostname} // 'other-host',
		user     => $fields{user}     // 'other-user',
		pid      => $fields{pid}      // 4242,
		env      => $fields{env}      // 'other-env',
		token    => $fields{token}    // 'held-elsewhere',
	};
}

# Seeds the record in whichever form the code under test reads.
sub seed_lock {
	my ($vault, $record) = @_;
	my $rec = $vault->{store}{$LOCK_PATH} //= {version => 0, data => {}};
	$rec->{data} = {%$record};
	$rec->{version}++;
	$vault->{plain}{"$EXODUS:network-claim-lock"} = JSON::PP::encode_json($record);
}

# ---------------------------------------------------------------------------
# The races
# ---------------------------------------------------------------------------

subtest 'two acquirers that both read a free lock before either writes: exactly one wins' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my ($first, $second) = (director($vault), director($vault));

	my $second_result;
	$vault->before_next_write(sub {
		$second_result = as_other_process(sub { try_acquire($second) });
	});
	my $first_result = try_acquire($first);
	my $user = $ENV{USER} // 'unknown';

	is($vault->reads_before_first_write, 2,
		'both acquirers read the lock record before either write landed');
	is(scalar(grep { $_ eq 'won' } $first_result, $second_result), 1,
		'exactly one of the two acquirers takes the lock')
		or diag "first: $first_result\nsecond: $second_result";
	like($first_result, qr/^refused: .*held by \Q$user\E\@.*between this process's check/s,
		'the loser is refused, and told who holds the lock')
		or diag $first_result;
	like($first_result, qr/lock-test/, 'the refusal names the director');
	like($first_result, qr/\Q$LOCK_PATH\E/, 'the refusal names where the lock is stored');
	ok(as_other_process(sub { $second->network_locked_by_me }),
		'the winner holds the lock');
	ok(!$first->network_locked_by_me, 'the loser does not');
};

subtest 'two acquirers that both find the same stale lock: exactly one takes it over' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	seed_lock($vault, lock_record(age => 7200));
	my ($first, $second) = (director($vault), director($vault));

	my $second_result;
	$vault->before_next_write(sub {
		$second_result = as_other_process(sub { try_acquire($second) });
	});
	my $first_result = try_acquire($first);

	is(scalar(grep { $_ eq 'won' } $first_result, $second_result), 1,
		'exactly one of the two acquirers takes over the stale lock')
		or diag "first: $first_result\nsecond: $second_result";
	ok(as_other_process(sub { $second->network_locked_by_me }),
		'the one that wrote first holds it');
	like($first_result, qr/^refused: /, 'the other is refused');
};

subtest 'clearing a stale lock does not remove a lock another process has since taken' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	seed_lock($vault, lock_record(age => 7200));
	my ($first, $second) = (director($vault), director($vault));

	# Both operators are shown the same stale lock and agree to clear it.
	my $seen_by_first  = $first->check_network_lock;
	my $seen_by_second = as_other_process(sub { $second->check_network_lock });
	is($seen_by_first->{status}, 'stale', 'the first operator sees the stale lock');
	is($seen_by_second->{status}, 'stale', 'so does the second');

	ok($first->clear_network_lock(stale => $seen_by_first), 'the first clears it');
	is(try_acquire($first), 'won', 'and takes the lock');

	my $cleared = as_other_process(sub { $second->clear_network_lock(stale => $seen_by_second) });
	ok(!$cleared, 'the second finds the stale lock already gone and clears nothing');
	ok($first->network_locked_by_me, "the first process's lock is still in place");
	my $second_result = as_other_process(sub { try_acquire($second) });
	like($second_result, qr/^refused: /, 'and the second is refused when it tries to take the lock');
};

subtest 'releasing a lock that went stale does not remove the lock that replaced it' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my ($first, $second) = (director($vault), director($vault));

	is(try_acquire($first), 'won', 'the first process takes the lock');
	# It then outlives the lock timeout, and another process takes over.
	$vault->{store}{$LOCK_PATH}{data}{at} =
		strftime('%Y-%m-%d %H:%M:%S +0000', gmtime(time - 7200));
	$vault->{plain}{"$EXODUS:network-claim-lock"} = JSON::PP::encode_json($vault->{store}{$LOCK_PATH}{data})
		if exists $vault->{plain}{"$EXODUS:network-claim-lock"};
	is(as_other_process(sub { try_acquire($second) }), 'won', 'the second takes over the stale lock');

	ok(!$first->network_locked_by_me, 'the first process no longer holds it');
	ok(!$first->clear_network_lock, "so the first process's release removes nothing");
	ok(as_other_process(sub { $second->network_locked_by_me }), "and the second process's lock is still in place");
};

subtest 'kv v1: a write that a competing write overtook is detected and refused' => sub {
	my $vault = MockLockVault->new(kv_version => 1);
	my $first = director($vault);
	no warnings 'once';
	local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;

	# A second process read the lock as free before this write landed, and
	# its own write lands just after it.
	$vault->after_next_write(sub {
		seed_lock($vault, lock_record(age => 0, user => 'racing-user', token => 'racing-token'));
	});
	my $result = try_acquire($first);
	like($result, qr/^refused: .*racing-user\@/s,
		'the overtaken writer is refused and told who holds the lock')
		or diag $result;
	like($result, qr/kv v1/i, 'and told the mount offers no check-and-set');
	ok(!$first->network_locked_by_me, 'and it does not hold the lock');
};

# ---------------------------------------------------------------------------
# The lock's ordinary life
# ---------------------------------------------------------------------------

subtest 'acquire, check, and release on a kv v2 mount' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);

	is($bosh->check_network_lock->{status}, 'unlocked', 'a director with no lock record is unlocked');
	is(try_acquire($bosh), 'won', 'the lock is taken when it is free');
	my $status = $bosh->check_network_lock;
	is($status->{status}, 'locked', 'and then reads as locked');
	is($status->{lock}{user}, $ENV{USER} // 'unknown', 'by this user');
	is($status->{lock}{pid}, $$, 'and this process');
	ok($bosh->network_locked_by_me, 'network_locked_by_me() is true for the holder');

	like(try_acquire(director($vault)), qr/^refused: /,
		'a second take by the same process is refused rather than nested');

	ok($bosh->clear_network_lock, 'the holder releases it');
	is($bosh->check_network_lock->{status}, 'unlocked', 'and the director is unlocked again');
	ok(!$bosh->network_locked_by_me, 'network_locked_by_me() is false after release');
	ok(!$bosh->clear_network_lock, 'releasing again removes nothing');
	is(try_acquire($bosh), 'won', 'and the lock can be taken again after a release');
};

subtest 'acquire and release on a kv v1 mount' => sub {
	my $vault = MockLockVault->new(kv_version => 1);
	my $bosh = director($vault);
	no warnings 'once';
	local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;

	is(try_acquire($bosh), 'won', 'the lock is taken when it is free');
	ok($bosh->network_locked_by_me, 'and is held by this process');
	ok($bosh->clear_network_lock, 'the holder releases it');
	is($bosh->check_network_lock->{status}, 'unlocked', 'and the director is unlocked again');
};

subtest 'a lock held by another process is refused with the specifics' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	seed_lock($vault, lock_record(age => 120, user => 'jdoe', hostname => 'jumpbox', pid => 777, env => 'lab-ocf'));
	my $result = try_acquire(director($vault));
	like($result, qr/^refused: /, 'the lock is not taken');
	like($result, qr/jdoe\@jumpbox/, 'the refusal names the holder');
	like($result, qr/lab-ocf/, 'and the environment it was taken for');
	like($result, qr/pid: 777/, 'and its pid');
	like($result, qr/ago/, 'and how long ago it was taken');
	like($result, qr/lock-test/, 'and the director');
	like($result, qr/\Q$LOCK_PATH\E/, 'and where the lock is stored');
	like($result, qr/usually means/, 'and the likely cause');
};

subtest 'stale locks' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);

	seed_lock($vault, lock_record(age => 7200));
	is($bosh->check_network_lock(max_lock_age => 1800)->{status}, 'stale',
		'a lock older than max_lock_age is stale');
	is(try_acquire($bosh), 'won', 'acquire takes over a stale lock');
	ok($bosh->network_locked_by_me, 'and then holds it');

	# A lock taken on this host by a process that has exited can never be
	# released by its owner, so it is stale however fresh it is.
	my $dead_pid = fork();
	if (defined($dead_pid) && $dead_pid == 0) { exit 0; }
	waitpid($dead_pid, 0) if defined($dead_pid);
	seed_lock($vault, lock_record(age => 60, hostname => Sys::Hostname::hostname(), pid => $dead_pid));
	is($bosh->check_network_lock(max_lock_age => 1800)->{status}, 'stale',
		'a same-host lock whose pid is dead is stale, even when fresh');

	seed_lock($vault, lock_record(age => 60, hostname => Sys::Hostname::hostname(), pid => $$));
	is($bosh->check_network_lock(max_lock_age => 1800)->{status}, 'locked',
		'a same-host lock whose pid is alive is not');
};

subtest 'clearing a stale lock that is still the same record' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);
	seed_lock($vault, lock_record(age => 7200));
	my $seen = $bosh->check_network_lock;
	ok($bosh->clear_network_lock(stale => $seen), 'the stale lock is cleared');
	is($bosh->check_network_lock->{status}, 'unlocked', 'and the director is unlocked');
};

# ---------------------------------------------------------------------------
# Failures around the lock
# ---------------------------------------------------------------------------

subtest 'a lock taken on a host that is not on UTC records the right time' => sub {
	use Time::Piece ();
	my $saved = $ENV{TZ};
	for my $tz ('America/Chicago', 'Asia/Kolkata', 'UTC') {
		local $ENV{TZ} = $tz;
		POSIX::tzset();
		my $vault = MockLockVault->new(kv_version => 2);
		my $bosh = director($vault);
		is(try_acquire($bosh), 'won', "$tz: the lock is taken");
		my $at = $vault->{store}{$LOCK_PATH}{data}{at};
		my $when = Time::Piece->strptime($at, '%Y-%m-%d %H:%M:%S %z');
		cmp_ok(abs($when->epoch - time), '<=', 5, "$tz: the time it records is now, wherever it is read")
			or diag "recorded $at";
		my $status = $bosh->check_network_lock;
		is($status->{status}, 'locked', "$tz: a lock just taken is neither stale nor waiting to be");
		cmp_ok(abs($status->{age}), '<=', 5, "$tz: and is seconds old");
	}
	defined($saved) ? ($ENV{TZ} = $saved) : delete($ENV{TZ});
	POSIX::tzset();
};

subtest 'a process that lost its lock while it waited is stopped before it changes anything' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my ($first, $second) = (director($vault), director($vault));
	is(try_acquire($first), 'won', 'the first process takes the lock');
	ok($first->ensure_network_lock_held('upload the cloud config'), 'and may go on while it holds it');

	# The first waits at a prompt past the stale timeout, and a second
	# process clears the lock and takes it.
	$vault->{store}{$LOCK_PATH}{data}{at} = strftime('%Y-%m-%d %H:%M:%S +0000', gmtime(time - 7200));
	is(as_other_process(sub { try_acquire($second) }), 'won', 'the second takes over the stale lock');

	my $user = $ENV{USER} // 'unknown';
	throws_ok { $first->ensure_network_lock_held('upload the cloud config') }
		qr/Cannot upload the cloud config.*lock-test.*no longer holds.*\Q$user\E\@.*stale.*\Q$LOCK_PATH\E/s,
		'the first is stopped, and told who holds the lock now and why it lost it';

	ok(as_other_process(sub { $second->clear_network_lock }), 'once the second releases it');
	throws_ok { $first->ensure_network_lock_held('write the network claims') }
		qr/Cannot write the network claims.*no longer holds.*nothing holds it now/s,
		'the first is still stopped, and told that nothing holds the lock';
};

subtest 'a write that fails after it may have landed says the lock may be held, and how to clear it' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);
	$vault->{die_after_write} = "Wrote version 1 of $LOCK_PATH, but reads still returned version 0 after 10s.\n";
	my $result = try_acquire($bosh);
	like($result, qr/^refused: .*reads still returned version 0/s, 'the vault\'s failure is kept')
		or diag $result;
	like($result, qr/may now hold the network claims lock/, 'and it says this process may now hold the lock');
	like($result, qr/safe rm \Q$LOCK_PATH\E/, 'and how to clear it');
	ok($bosh->network_locked_by_me, 'which it does, so a release by its caller removes it');
	ok($bosh->clear_network_lock, 'and the release does');

	$vault->{die_after_write} = "Hung up\n";
	my $signal = eval { quietly { $bosh->acquire_network_lock }; 1 } ? '' : $@;
	like($signal, qr/^Hung up\b/, 'a signal during the write passes through as it came');
	unlike($signal, qr/may now hold/, 'with nothing added to it');
};

subtest 'a release that fails is logged with the specifics and never dies' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');

	$vault->{read_error} = "Could not read $LOCK_PATH from the vault: Vault is sealed\n";
	my ($result, $out);
	lives_ok { $out = join('', output_from(sub { $result = $bosh->release_network_lock })) }
		'a release against an unreadable vault does not die';
	ok(!defined($result), 'it reports that the release failed');
	like($out, qr/could not be released.*Vault is sealed/s, 'and logs why');
	like($out, qr/lock-test/, 'naming the director');
	like($out, qr/\Q$LOCK_PATH\E/, 'and where the lock is stored');
	like($out, qr/stale/, 'and when other deploys can take it');

	delete $vault->{read_error};
	is(quietly { $bosh->release_network_lock }, 1, 'a release of this process\'s lock returns 1');
	is($bosh->check_network_lock->{status}, 'unlocked', 'and removes it');
	is(quietly { $bosh->release_network_lock }, 0, 'with nothing of ours to release, it returns 0');
};

subtest 'a release that finds the lock taken by another process reports that it released nothing' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');

	# Another process clears the lock as stale and takes it between the
	# release's ownership check and its clear.
	my $reads = 0;
	my $real_read = \&MockLockVault::kv_read;
	no warnings 'redefine';
	local *MockLockVault::kv_read = sub {
		my $read = $real_read->(@_);
		if (++$reads == 1) {
			my $rec = $vault->{store}{$LOCK_PATH};
			$rec->{data} = {%{$rec->{data}}, token => 'another-process', pid => getppid()};
			$rec->{version}++;
		}
		return $read;
	};
	my $result;
	my $out = join('', output_from(sub { $result = $bosh->release_network_lock }));
	is($result, 0, 'the release reports that nothing was released');
	unlike($out, qr/done/, 'without saying it was done');
	like($out, qr/no longer held by this process/, 'and says the lock was no longer this process\'s');
	is($vault->{store}{$LOCK_PATH}{data}{token}, 'another-process', 'and the other process\'s lock is left alone');
};

subtest 'a kv v1 release the vault refuses is reported, not counted as released' => sub {
	my $vault = MockLockVault->new(kv_version => 1);
	my $bosh = director($vault);
	no warnings 'once';
	local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;
	is(try_acquire($bosh), 'won', 'the lock is taken');
	$vault->{delete_refused} = 1;
	throws_ok { $bosh->clear_network_lock } qr/Could not delete.*permission denied/,
		'the refused delete is a failure';
	ok($bosh->network_locked_by_me, 'and the lock is still there, as the failure says');
};

done_testing;
