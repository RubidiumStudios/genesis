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
use Time::Piece ();

use_ok "Service::BOSH";
use_ok "Service::BOSH::Director";
use Service::Vault;
use Genesis;

# ===========================================================================
# The network claims lock on a BOSH director
#
# The lock is a secret of its own beside the director's exodus data, read
# whole through the vault's strict reader, written with a plain set, and
# removed with a plain clear.  Nothing about taking it is atomic: two
# processes that both read it as free both write it, and the later write is
# the one that stays.  What keeps their claims apart is the check each makes
# that it still holds the lock, right before each write the lock is for.
#
# The mock vault answers the three calls the lock makes, as Service::Vault
# does: a read gives the secret's keys, undef where nothing is stored, and
# dies when the read did not finish; a set merges string values into the
# secret; a clear removes it, and dies when the vault refuses.  It has no
# other way to read or write, so a lock that reached for one would fail.
# ===========================================================================

package MockLockVault {
	sub new {
		my ($class) = @_;
		return bless {
			store => {},   # path => {key => string, ...}
			log   => [],   # [read|set|clear, path]
		}, $class;
	}

	sub url { 'https://vault.example.com:8200' }
	sub build_descriptor { 'mock-vault' }

	# What runs just before the next write lands, just after it, and just
	# after the next read.  Each fires once, so the code it calls reads and
	# writes without re-entering it.
	sub before_next_write { $_[0]{before_write} = $_[1] }
	sub after_next_write  { $_[0]{after_write}  = $_[1] }
	sub after_next_read   { $_[0]{after_read}   = $_[1] }

	sub _fire { my $hook = delete $_[0]{$_[1]}; $hook->() if $hook }

	sub read_flattened_secret {
		my ($self, $path) = @_;
		die $self->{read_error} if $self->{read_error};
		die $self->{read_errors}{$path} if $self->{read_errors}{$path};
		push @{$self->{log}}, ['read', $path];
		my $found = $self->{store}{$path} ? {%{$self->{store}{$path}}} : undef;
		$self->_fire('after_read');
		return $found;
	}

	sub set {
		my ($self, $path, %pairs) = @_;
		die "set() was given a value that is not a plain string for '$_'\n"
			for grep { !defined($pairs{$_}) || ref($pairs{$_}) } sort keys %pairs;
		die $self->{set_refused} if $self->{set_refused};
		$self->_fire('before_write');
		$self->{store}{$path} = {%{$self->{store}{$path} // {}}, map {($_ => "$pairs{$_}")} keys %pairs};
		push @{$self->{log}}, ['set', $path];
		$self->_fire('after_write');
		# A failure after the vault accepted the write, such as a read-back
		# that never catches up on an HA vault, or a signal
		if (my $err = delete $self->{die_after_write}) { die $err }
		return \%pairs;
	}

	sub clear {
		my ($self, $path) = @_;
		die $self->{clear_refused} if $self->{clear_refused};
		$self->_fire('before_write');
		push @{$self->{log}}, ['clear', $path];
		return unless exists $self->{store}{$path};
		delete $self->{store}{$path};
		$self->_fire('after_write');
		return 1;
	}

	# Every set or clear the vault was sent for a path
	sub writes_to {
		my ($self, $path) = @_;
		return grep { $_->[0] ne 'read' && $_->[1] eq $path } @{$self->{log}};
	}

	sub reads_of {
		my ($self, $path) = @_;
		return grep { $_->[0] eq 'read' && $_->[1] eq $path } @{$self->{log}};
	}
}

local $ENV{GENESIS_BOSH_COMMAND};
fake_bosh('');
Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});

my $EXODUS = 'secret/exodus/lock-test/bosh';
my $LOCK_PATH = "$EXODUS/network-claim-lock";
my $USER = $ENV{USER} // 'unknown';

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
	my ($bosh, %opts) = @_;
	return eval { quietly { $bosh->acquire_network_lock(%opts) }; 1 } ? 'won' : "refused: $@";
}

sub at { strftime('%Y-%m-%d %H:%M:%S +0000', gmtime(time - $_[0])) }

# A lock record as the vault gives it back: every value a string.
sub lock_record {
	my (%fields) = @_;
	return {
		at       => at($fields{age} // 60),
		hostname => $fields{hostname} // 'other-host',
		user     => $fields{user}     // 'other-user',
		pid      => ''.($fields{pid}  // 4242),
		env      => $fields{env}      // 'other-env',
		token    => $fields{token}    // 'held-elsewhere',
	};
}

sub seed_lock {
	my ($vault, $record) = @_;
	$vault->{store}{$LOCK_PATH} = {%$record};
}

# Seeds the lock as released Genesis versions keep it: a JSON string in the
# network-claim-lock key of the director's exodus secret, alongside the
# exodus data itself.
sub seed_legacy_lock {
	my ($vault, $record) = @_;
	$vault->{store}{$EXODUS} = {
		url                  => 'https://127.0.0.1:25555',
		'network-claim-lock' => ref($record) ? JSON::PP::encode_json($record) : $record,
	};
}

# The pid of a process that has exited and been reaped
sub dead_pid {
	my $pid = fork() // die "Could not fork: $!\n";
	exit 0 if $pid == 0;
	waitpid($pid, 0);
	die "Process $pid is still there after it was reaped\n" if kill(0, $pid);
	return $pid;
}

my $REFUSED = "Could not read %s from vault at https://vault.example.com:8200: 403 permission denied\n";
my $SEALED  = "Could not read %s from vault at https://vault.example.com:8200: Vault is sealed\n";

# ---------------------------------------------------------------------------
# Checking the lock
# ---------------------------------------------------------------------------

subtest 'a director with nothing stored at the lock path is unlocked' => sub {
	my $vault = MockLockVault->new;
	my $status = director($vault)->check_network_lock;
	is_deeply($status, {status => 'unlocked', path => $LOCK_PATH},
		'the check says so, and names where the lock is kept');
	is(scalar($vault->writes_to($LOCK_PATH)), 0, 'and a check writes nothing');
};

subtest 'a lock secret with no time in it holds nothing' => sub {
	# A build that released the lock by writing an empty record left a secret
	# with no keys there.
	for my $case (['no keys', {}], ['keys but no time', {hostname => 'h', user => 'u'}]) {
		my ($what, $record) = @$case;
		my $vault = MockLockVault->new;
		seed_lock($vault, $record);
		is(director($vault)->check_network_lock->{status}, 'unlocked', "$what: unlocked");
		is(try_acquire(director($vault)), 'won', "$what: and the lock can be taken");
	}
};

subtest 'a held lock is reported with who holds it' => sub {
	my $vault = MockLockVault->new;
	seed_lock($vault, lock_record(age => 120, user => 'jdoe', hostname => 'jumpbox', pid => 777, env => 'lab-ocf'));
	my $status = director($vault)->check_network_lock;
	is($status->{status}, 'locked', 'the lock is held');
	is($status->{path}, $LOCK_PATH, 'at the lock path');
	is_deeply($status->{lock}, $vault->{store}{$LOCK_PATH}, 'the record is passed on as it was read');
	cmp_ok(abs($status->{age} - 120), '<=', 5, 'with its age in seconds');
	is($status->{max_age}, 1800, 'and the thirty minute limit it was judged by');
	like($status->{description}, qr/ago by jdoe\@jumpbox \(env: lab-ocf, pid: 777\)/, 'and a description of the holder');
	is_deeply([sort keys %$status], [qw(age description lock max_age path status)],
		'and nothing about the mount it is stored on');
};

subtest 'stale locks' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);

	seed_lock($vault, lock_record(age => 7200));
	is($bosh->check_network_lock->{status}, 'stale', 'a lock older than thirty minutes is stale');
	seed_lock($vault, lock_record(age => 600));
	is($bosh->check_network_lock->{status}, 'locked', 'one ten minutes old is not');
	is($bosh->check_network_lock(max_lock_age => 300)->{status}, 'stale', 'unless max_lock_age says so');

	# A lock taken on this host by a process that has exited can never be
	# released by its owner, so it is stale however fresh it is.
	seed_lock($vault, lock_record(age => 60, hostname => Sys::Hostname::hostname(), pid => dead_pid()));
	is($bosh->check_network_lock->{status}, 'stale', 'a same-host lock whose pid is dead is stale, even when fresh');
	seed_lock($vault, lock_record(age => 60, hostname => Sys::Hostname::hostname(), pid => $$));
	is($bosh->check_network_lock->{status}, 'locked', 'a same-host lock whose pid is alive is not');
	seed_lock($vault, lock_record(age => 60, hostname => 'other-host', pid => dead_pid()));
	is($bosh->check_network_lock->{status}, 'locked', 'nor is one from another host, whose pid cannot be checked');

	SKIP: {
		skip 'running as root, which can signal every process', 2 if $> == 0;
		seed_lock($vault, lock_record(age => 60, hostname => Sys::Hostname::hostname(), pid => 1));
		ok(!kill(0, 1) && $!{EPERM}, 'pid 1 answers a signal check with EPERM');
		is($bosh->check_network_lock->{status}, 'locked', 'so a same-host lock it holds is still held');
	}
};

subtest 'a lock that cannot be read is never taken for unlocked' => sub {
	for my $case (['a refusal', $REFUSED, qr/403 permission denied/], ['an outage', $SEALED, qr/Vault is sealed/]) {
		my ($what, $error, $reason) = @$case;
		my $vault = MockLockVault->new;
		my $bosh = director($vault);
		is(try_acquire($bosh), 'won', "$what: the lock is taken");
		my @sent = $vault->writes_to($LOCK_PATH);
		$vault->{read_errors}{$LOCK_PATH} = sprintf($error, $LOCK_PATH);

		throws_ok { $bosh->check_network_lock } $reason, "$what: the check raises what the vault said";
		throws_ok { $bosh->network_locked_by_me } $reason, "$what: so does asking whether this process holds it";
		throws_ok { $bosh->ensure_network_lock_held('write the network claims') } $reason,
			"$what: and the check made before a write";
		like(as_other_process(sub { try_acquire(director($vault)) }), qr/^refused: .*$reason/s,
			"$what: an acquire stops on it");
		throws_ok { $bosh->clear_network_lock } $reason, "$what: and so does a clear";
		is(scalar($vault->writes_to($LOCK_PATH)), scalar(@sent), "$what: and nothing was set or cleared after the failed read");
	}
};

subtest 'a lock whose time cannot be read stops the check, and says how to look at it' => sub {
	my $vault = MockLockVault->new;
	seed_lock($vault, {%{lock_record()}, at => 'yesterday afternoon'});
	my $bosh = director($vault);
	eval { $bosh->check_network_lock };
	my $raised = Genesis::raised($@);
	is($raised && $raised->state, 'invalid', 'the check raises as an invalid record (D163)');
	is($raised && $raised->exitcode, Genesis::Exit::DATAERR, 'which exits DATAERR');
	throws_ok { $bosh->check_network_lock } qr/lock-test.*\Q$LOCK_PATH\E.*yesterday afternoon/s,
		'the check raises, naming the director, the record, and the time it holds';
	throws_ok { $bosh->check_network_lock } qr/safe get \Q$LOCK_PATH\E.*safe rm \Q$LOCK_PATH\E/s,
		'and gives the commands that show the record and remove it';
	like(try_acquire($bosh), qr/^refused: .*yesterday afternoon/s, 'an acquire stops on it');
	is(scalar($vault->writes_to($LOCK_PATH)), 0, 'and writes nothing');
};

# ---------------------------------------------------------------------------
# Taking the lock
# ---------------------------------------------------------------------------

subtest 'a free lock is taken with one plain write of six strings' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);
	my $lock;
	lives_ok { quietly { $lock = $bosh->acquire_network_lock } } 'the lock is taken';

	is_deeply([map {$_->[0]} $vault->writes_to($LOCK_PATH)], ['set'], 'with a single set of the lock secret');
	my $stored = $vault->{store}{$LOCK_PATH};
	is_deeply([sort keys %$stored], [qw(at env hostname pid token user)], 'holding every field of the lock');
	is_deeply($lock, $stored, 'which is what the acquire returns');
	is($stored->{pid}, "$$", 'the pid is this process\'s');
	is($stored->{user}, $USER, 'the user is this user');
	is($stored->{hostname}, Sys::Hostname::hostname(), 'the host is this host');
	like($stored->{at}, qr/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \+0000$/, 'the time is labelled as UTC');

	my $status = $bosh->check_network_lock;
	is($status->{status}, 'locked', 'the director then reads as locked');
	ok($bosh->network_locked_by_me, 'by this process');
	ok(!as_other_process(sub { director($vault)->network_locked_by_me }), 'and not by another');
};

subtest 'a lock held by another process is refused with the specifics' => sub {
	my $vault = MockLockVault->new;
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
	is(scalar($vault->writes_to($LOCK_PATH)), 0, 'and nothing was written');
	is($vault->{store}{$LOCK_PATH}{token}, 'held-elsewhere', 'so the holder keeps it');
};

subtest 'a second take by the process that holds the lock is refused, not nested' => sub {
	my $vault = MockLockVault->new;
	is(try_acquire(director($vault)), 'won', 'the lock is taken');
	like(try_acquire(director($vault)), qr/^refused: .*held by \Q$USER\E\@/s, 'and a second take is refused');
};

subtest 'a stale lock is taken over, and the takeover is said' => sub {
	my $vault = MockLockVault->new;
	seed_lock($vault, lock_record(age => 7200, user => 'crashed-user', hostname => 'crashed-host'));
	my $bosh = director($vault);
	my $out = join('', output_from(sub { $bosh->acquire_network_lock }));
	like($out =~ s/\s+/ /gr, qr/Taking over the stale network claims lock.*lock-test.*crashed-user\@crashed-host/,
		'the takeover names the director and who held the stale lock');
	ok($bosh->network_locked_by_me, 'and the lock is this process\'s');
	is_deeply([sort keys %{$vault->{store}{$LOCK_PATH}}], [qw(at env hostname pid token user)],
		'with every field replaced');
	is($vault->{store}{$LOCK_PATH}{user}, $USER, 'by this holder\'s');
};

subtest 'a lock taken on a host that is not on UTC records the right time' => sub {
	my $saved = $ENV{TZ};
	for my $tz ('America/Chicago', 'Asia/Kolkata', 'UTC') {
		local $ENV{TZ} = $tz;
		POSIX::tzset();
		my $vault = MockLockVault->new;
		my $bosh = director($vault);
		is(try_acquire($bosh), 'won', "$tz: the lock is taken");
		my $at = $vault->{store}{$LOCK_PATH}{at};
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

subtest 'a write the vault refuses is a failed acquire, with nothing held' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);
	$vault->{set_refused} = "Could not write $LOCK_PATH to vault at https://vault.example.com:8200:\n403 permission denied\n";
	my $result = try_acquire($bosh);
	like($result, qr/^refused: .*403 permission denied/s, 'the vault\'s refusal is kept');
	like($result, qr/lock-test/, 'with the director named');
	delete $vault->{set_refused};
	ok(!$bosh->network_locked_by_me, 'and this process holds nothing');
};

subtest 'a write that fails after it may have landed says the lock may be held, and how to clear it' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);
	$vault->{die_after_write} = "Wrote $LOCK_PATH to the vault, but 6 of its 6 keys did not read back within 10s.\n";
	my $result = try_acquire($bosh) =~ s/\s+/ /gr;
	like($result, qr/^refused: .*did not read back within 10s/s, 'the vault\'s failure is kept')
		or diag $result;
	like($result, qr/may now hold the network claims lock/, 'and it says this process may now hold the lock');
	like($result, qr/safe get \Q$LOCK_PATH\E.*host \Q@{[Sys::Hostname::hostname()]}\E and pid $$/s,
		'and how to tell that the lock is this process\'s');
	like($result, qr/safe rm \Q$LOCK_PATH\E/, 'and how to clear it');
	ok($bosh->network_locked_by_me, 'which it does, so a release by its caller removes it');
	ok($bosh->clear_network_lock, 'and the release does');

	$vault->{die_after_write} = "Hung up\n";
	my $signal = eval { quietly { $bosh->acquire_network_lock }; 1 } ? '' : $@;
	like($signal, qr/^Hung up\b/, 'a signal during the write passes through as it came');
	unlike($signal, qr/may now hold/, 'with nothing added to it');
};

# ---------------------------------------------------------------------------
# Two processes at once
#
# Taking the lock is a read and then a write, so two processes can both read
# it as free.  Both then write, and the later write replaces the earlier.
# The earlier writer believes it holds the lock until it checks, which it
# does before the cloud config upload and before the claims write.
# ---------------------------------------------------------------------------

subtest 'two acquirers that both read a free lock: the later write stays, and the other is stopped before it writes claims' => sub {
	my $vault = MockLockVault->new;
	my ($later, $earlier) = (director($vault), director($vault));

	# The earlier process reads and writes between the later one's read and
	# the later one's write.
	my $earlier_result;
	$vault->before_next_write(sub {
		$earlier_result = as_other_process(sub { try_acquire($earlier) });
	});
	my $later_result = try_acquire($later);

	is(scalar($vault->reads_of($LOCK_PATH)), 2, 'both read the lock');
	is_deeply([map {$_->[0]} @{$vault->{log}}[grep { $vault->{log}[$_][1] eq $LOCK_PATH } 0 .. $#{$vault->{log}}]],
		[qw(read read set set)], 'before either wrote it, and then both wrote');
	is($earlier_result, 'won', 'the earlier writer took the lock, as far as it could tell');
	is($later_result, 'won', 'and so did the later one');

	ok($later->network_locked_by_me, 'the later write is the one that stayed');
	ok(!as_other_process(sub { $earlier->network_locked_by_me }), 'so the earlier writer no longer holds the lock');
	ok($later->ensure_network_lock_held('write the network claims'), 'the holder may write its claims');

	my $sent = scalar($vault->writes_to($LOCK_PATH));
	throws_ok { as_other_process(sub { $earlier->ensure_network_lock_held('write the network claims') }) }
		qr/Cannot write the network claims.*lock-test.*no longer holds.*\Q$USER\E\@.*\Q$LOCK_PATH\E/s,
		'the earlier writer is stopped before its claims write, and told who holds the lock';
	throws_ok { as_other_process(sub { $earlier->ensure_network_lock_held('upload the cloud config') }) }
		qr/same moment/, 'and that two deploys taking it in the same moment is one way this happens';

	my $released;
	my $out = join('', output_from(sub { $released = as_other_process(sub { $earlier->release_network_lock }) }));
	is($released, 0, 'its release removes nothing');
	is(scalar($vault->writes_to($LOCK_PATH)), $sent, 'and sends the vault nothing');
	ok($later->network_locked_by_me, 'so the holder still holds the lock');
	is(quietly { $later->release_network_lock }, 1, 'until it releases it');
	is($later->check_network_lock->{status}, 'unlocked', 'and the director is unlocked');
};

subtest 'two acquirers that both find the same stale lock: the later takeover stays' => sub {
	my $vault = MockLockVault->new;
	seed_lock($vault, lock_record(age => 7200));
	my ($later, $earlier) = (director($vault), director($vault));

	my $earlier_result;
	$vault->before_next_write(sub {
		$earlier_result = as_other_process(sub { try_acquire($earlier) });
	});
	is(try_acquire($later), 'won', 'the later writer takes over the stale lock');
	is($earlier_result, 'won', 'as the earlier one did a moment before');
	ok($later->network_locked_by_me, 'the later write holds the lock');
	throws_ok { as_other_process(sub { $earlier->ensure_network_lock_held('write the network claims') }) }
		qr/no longer holds the network claims lock/, 'and the earlier writer is stopped before it writes';
};

subtest 'clearing a stale lock does not remove a lock another process has since taken' => sub {
	my $vault = MockLockVault->new;
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
	ok(!$cleared, 'the second finds a different lock there and clears nothing');
	ok($first->network_locked_by_me, "the first process's lock is still in place");
	like(as_other_process(sub { try_acquire($second) }), qr/^refused: /,
		'and the second is refused when it tries to take the lock');
};

subtest 'releasing a lock that went stale does not remove the lock that replaced it' => sub {
	my $vault = MockLockVault->new;
	my ($first, $second) = (director($vault), director($vault));

	is(try_acquire($first), 'won', 'the first process takes the lock');
	# It then outlives the lock timeout, and another process takes over.
	$vault->{store}{$LOCK_PATH}{at} = at(7200);
	is(as_other_process(sub { try_acquire($second) }), 'won', 'the second takes over the stale lock');

	ok(!$first->network_locked_by_me, 'the first process no longer holds it');
	ok(!$first->clear_network_lock, "so the first process's release removes nothing");
	ok(as_other_process(sub { $second->network_locked_by_me }), "and the second process's lock is still in place");
};

# ---------------------------------------------------------------------------
# A lock held by a released Genesis
#
# Released Genesis versions keep the lock as JSON in the network-claim-lock
# key of the exodus secret, and never read the lock's own secret.  One of
# them can be deploying against the same director, so taking the lock looks
# at that key first, and so does the check made before each write.
# ---------------------------------------------------------------------------

subtest 'a fresh lock under the old key refuses, naming the holder' => sub {
	my $vault = MockLockVault->new;
	seed_legacy_lock($vault, lock_record(
		age => 120, user => 'olduser', hostname => 'oldjumpbox', pid => 31337, env => 'lab-old',
	));
	my $result = try_acquire(director($vault));
	like($result, qr/^refused: /, 'the lock is not taken');
	like($result, qr/older Genesis/, 'the refusal says an older Genesis appears to be deploying');
	like($result, qr/olduser\@oldjumpbox/, 'and names the user and host that hold the old lock');
	like($result, qr/pid: 31337/, 'and its pid');
	like($result, qr/lab-old/, 'and the environment it was taken for');
	like($result, qr/ago/, 'and how long ago it was taken');
	like($result, qr/lock-test/, 'and the director');
	like($result, qr/usually means/, 'and the likely cause');
	like($result, qr/safe\s+get\s+\Q$EXODUS:network-claim-lock\E/, 'and how to check the old key');
	like($result, qr/safe\s+rm\s+-f\s+\Q$EXODUS:network-claim-lock\E/, 'and how to clear it when it is stale');
	is(scalar($vault->writes_to($LOCK_PATH)), 0, 'and nothing was written to the lock');
};

subtest 'an old lock that is stale, as the older Genesis counts it, does not block' => sub {
	my $aged = MockLockVault->new;
	seed_legacy_lock($aged, lock_record(age => 7200, user => 'crashed-user'));
	is(try_acquire(director($aged)), 'won', 'one past the thirty minute limit');
	ok(director($aged)->network_locked_by_me, 'and the lock is held by this process');

	my $dead = MockLockVault->new;
	seed_legacy_lock($dead, lock_record(age => 60, hostname => Sys::Hostname::hostname(), pid => dead_pid()));
	is(try_acquire(director($dead)), 'won', 'a fresh one from a dead process on this host');

	my $fresh = MockLockVault->new;
	seed_legacy_lock($fresh, lock_record(age => 1700));
	like(try_acquire(director($fresh)), qr/^refused: .*older Genesis/s,
		'one just inside the thirty minute limit still blocks');

	my $max_age = MockLockVault->new;
	seed_legacy_lock($max_age, lock_record(age => 600));
	is(try_acquire(director($max_age), max_lock_age => 300), 'won',
		'max_lock_age applies to the old lock as it does to the new one');
};

subtest 'an absent old key does not block' => sub {
	my $none = MockLockVault->new;
	is(try_acquire(director($none)), 'won', 'no exodus secret at all');

	my $no_field = MockLockVault->new;
	$no_field->{store}{$EXODUS} = {url => 'https://127.0.0.1:25555'};
	is(try_acquire(director($no_field)), 'won', 'an exodus secret without the lock field');

	my $empty = MockLockVault->new;
	seed_legacy_lock($empty, '');
	is(try_acquire(director($empty)), 'won', 'an empty lock field');
};

subtest 'an old lock value that is not a lock record does not block, and is warned about' => sub {
	for my $junk ('not json at all', '{"user":"x"}', '{"at":"yesterday"}') {
		my $vault = MockLockVault->new;
		seed_legacy_lock($vault, $junk);
		my ($result, $out);
		$out = join('', output_from(sub {
			$result = eval { director($vault)->acquire_network_lock; 'won' } || "refused: $@";
		}));
		is($result, 'won', "the lock is taken over '$junk'");
		like($out, qr/network-claim-lock.*is\s+not\s+a\s+lock\s+record/s, '... with a warning that names the key')
			or diag $out;
	}
};

subtest 'an old key that cannot be read stops the acquire' => sub {
	my $vault = MockLockVault->new;
	$vault->{read_errors}{$EXODUS} = sprintf($REFUSED, $EXODUS);
	my $result = try_acquire(director($vault));
	like($result, qr/^refused: /, 'the lock is not taken');
	like($result, qr/403 permission denied/, 'the vault\'s reason is kept');
	like($result, qr/older Genesis/, 'and it says why the old key matters');
	like($result, qr/lock-test/, 'it names the director');
	like($result, qr/network-claim-lock.*\Q$EXODUS\E/s, 'and the key and the secret it could not read');
	like($result, qr/Nothing was written/, 'and that nothing was written');
	is(scalar($vault->writes_to($EXODUS)) + scalar($vault->writes_to($LOCK_PATH)), 0, 'which is so');
};

subtest 'the old key is only ever read' => sub {
	for my $case (['fresh old lock', 120], ['stale old lock', 7200]) {
		my ($name, $age) = @$case;
		my $vault = MockLockVault->new;
		seed_legacy_lock($vault, lock_record(age => $age));
		my $before = JSON::PP->new->canonical->encode($vault->{store}{$EXODUS});
		my $bosh = director($vault);
		try_acquire($bosh);
		$bosh->clear_network_lock;
		is(scalar($vault->writes_to($EXODUS)), 0, "$name: no set or clear was sent for the exodus secret");
		is(JSON::PP->new->canonical->encode($vault->{store}{$EXODUS}), $before, "$name: and it is as it was");
		is(scalar($vault->reads_of($EXODUS)), 1, "$name: it was read once");
	}
};

subtest 'a fresh old lock that appears after this process took its lock stops the claims write' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken with no older lock about');
	ok($bosh->ensure_network_lock_held('write the network claims'), 'and the claims may be written');

	# An older Genesis starts after the lock was taken, and takes its own.
	seed_legacy_lock($vault, lock_record(age => 30, user => 'lateuser', hostname => 'latebox', pid => 555, env => 'lab-late'));
	my $before = JSON::PP->new->canonical->encode($vault->{store}{$EXODUS});
	throws_ok { $bosh->ensure_network_lock_held('write the network claims') }
		qr/Cannot write the network claims.*lock-test.*older Genesis.*lateuser\@latebox.*lab-late.*pid: 555/s,
		'the write is refused, naming the older Genesis and its holder';
	throws_ok { $bosh->ensure_network_lock_held('write the network claims') }
		qr/safe\s+get\s+\Q$EXODUS:network-claim-lock\E.*safe\s+rm\s+-f\s+\Q$EXODUS:network-claim-lock\E/s,
		'and gives the commands that check and clear the old key';
	is(scalar($vault->writes_to($EXODUS)), 0, 'nothing was written to the old key');
	is(JSON::PP->new->canonical->encode($vault->{store}{$EXODUS}), $before, 'the exodus secret is as it was');
	ok($bosh->network_locked_by_me, 'and this process still holds its own lock, for its release to clear');

	# Once that lock is stale, or gone, the claims may be written again.
	seed_legacy_lock($vault, lock_record(age => 7200));
	ok($bosh->ensure_network_lock_held('write the network claims'), 'a stale old lock does not stop the write');
	delete $vault->{store}{$EXODUS};
	ok($bosh->ensure_network_lock_held('write the network claims'), 'nor does an absent one');
};

subtest 'an old key that cannot be read stops the claims write' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');
	$vault->{read_errors}{$EXODUS} = sprintf($REFUSED, $EXODUS);
	throws_ok { $bosh->ensure_network_lock_held('write the network claims') }
		qr/Cannot write the network claims.*older Genesis.*403 permission denied/s,
		'the write is refused, with the vault\'s reason';
};

subtest 'a lock this process lost is reported as lost, before the old key is looked at' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);
	$vault->{read_errors}{$EXODUS} = sprintf($REFUSED, $EXODUS);
	throws_ok { $bosh->ensure_network_lock_held('write the network claims') }
		qr/no longer holds the network claims lock/, 'the lost lock is what is reported';
};

# ---------------------------------------------------------------------------
# Clearing the lock
# ---------------------------------------------------------------------------

subtest 'the holder clears its own lock, once' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');

	ok($bosh->clear_network_lock, 'the holder releases it');
	is_deeply([map {$_->[0]} $vault->writes_to($LOCK_PATH)], [qw(set clear)], 'with a single clear of the lock secret');
	ok(!exists $vault->{store}{$LOCK_PATH}, 'which leaves nothing stored there');
	is($bosh->check_network_lock->{status}, 'unlocked', 'and the director is unlocked again');
	ok(!$bosh->network_locked_by_me, 'network_locked_by_me() is false after release');
	ok(!$bosh->clear_network_lock, 'releasing again removes nothing');
	is(scalar($vault->writes_to($LOCK_PATH)), 2, 'and sends the vault nothing');
	is(try_acquire($bosh), 'won', 'and the lock can be taken again after a release');
};

subtest 'a lock held by another process is not this one\'s to clear' => sub {
	my $vault = MockLockVault->new;
	seed_lock($vault, lock_record(age => 60));
	ok(!director($vault)->clear_network_lock, 'a clear removes nothing');
	is(scalar($vault->writes_to($LOCK_PATH)), 0, 'and sends the vault nothing');
	is($vault->{store}{$LOCK_PATH}{token}, 'held-elsewhere', 'so the holder keeps its lock');
};

subtest 'a stale lock that is still the record that was shown is cleared' => sub {
	for my $case (
		['past the timeout', age => 7200],
		['from a dead pid on this host', age => 60, hostname => Sys::Hostname::hostname(), pid => dead_pid()],
	) {
		my ($what, %fields) = @$case;
		my $vault = MockLockVault->new;
		my $bosh = director($vault);
		seed_lock($vault, lock_record(%fields));
		my $seen = $bosh->check_network_lock;
		is($seen->{status}, 'stale', "$what: the lock is stale");
		ok($bosh->clear_network_lock(stale => $seen), "$what: and is cleared");
		ok(!exists $vault->{store}{$LOCK_PATH}, "$what: and is gone");
	}
};

subtest 'a stale lock that changed after it was shown is left alone' => sub {
	for my $change (
		['token', token => 'taken-since'],
		['holder', user => 'someone-else', hostname => 'elsewhere'],
		['time', age => 7300],
	) {
		my ($what, %changed) = @$change;
		my $vault = MockLockVault->new;
		my $bosh = director($vault);
		seed_lock($vault, lock_record(age => 7200));
		my $seen = $bosh->check_network_lock;
		seed_lock($vault, lock_record(age => 7200, %changed));
		ok(!$bosh->clear_network_lock(stale => $seen), "changed $what: the lock is not cleared");
		is(scalar($vault->writes_to($LOCK_PATH)), 0, "changed $what: the vault is sent nothing");
		ok(exists $vault->{store}{$LOCK_PATH}, "changed $what: and the lock is still there");
	}
};

subtest 'a clear the vault refuses is a failure, not a release' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');
	$vault->{clear_refused} = "Could not clear $LOCK_PATH in vault at https://vault.example.com:8200:\n403 permission denied\n";
	throws_ok { $bosh->clear_network_lock } qr/Could not clear.*permission denied/s, 'the refused clear raises';
	ok($bosh->network_locked_by_me, 'and the lock is still there, as the failure says');
};

# ---------------------------------------------------------------------------
# Still holding the lock, before a write
# ---------------------------------------------------------------------------

subtest 'a process that lost its lock while it waited is stopped before it changes anything' => sub {
	my $vault = MockLockVault->new;
	my ($first, $second) = (director($vault), director($vault));
	is(try_acquire($first), 'won', 'the first process takes the lock');
	ok($first->ensure_network_lock_held('upload the cloud config'), 'and may go on while it holds it');

	# The first waits at a prompt past the stale timeout, and a second
	# process clears the lock and takes it.
	$vault->{store}{$LOCK_PATH}{at} = at(7200);
	is(as_other_process(sub { try_acquire($second) }), 'won', 'the second takes over the stale lock');

	throws_ok { $first->ensure_network_lock_held('upload the cloud config') }
		qr/Cannot upload the cloud config.*lock-test.*no longer holds.*\Q$USER\E\@.*stale.*\Q$LOCK_PATH\E/s,
		'the first is stopped, and told who holds the lock now and why it lost it';

	ok(as_other_process(sub { $second->clear_network_lock }), 'once the second releases it');
	throws_ok { $first->ensure_network_lock_held('write the network claims') }
		qr/Cannot write the network claims.*no longer holds.*nothing holds it now/s,
		'the first is still stopped, and told that nothing holds the lock';
};

# ---------------------------------------------------------------------------
# Releasing the lock on the way out
# ---------------------------------------------------------------------------

subtest 'a release that cannot read the lock says its state is unknown, and never dies' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');

	$vault->{read_error} = sprintf($SEALED, $LOCK_PATH);
	my ($result, $out);
	lives_ok { $out = join('', output_from(sub { $result = $bosh->release_network_lock })) }
		'a release against an unreadable vault does not die';
	ok(!defined($result), 'it reports that the release failed');
	my $flat = $out =~ s/\s+/ /gr;
	like($flat, qr/could not be read.*Vault is sealed/, 'and logs that the lock state could not be read, and why');
	like($flat, qr/not known whether (?:this process|a lock)/i, 'and that it is not known whether a lock is held');
	unlike($flat, qr/could not be released/, 'without claiming that a release failed');
	like($flat, qr/lock-test/, 'naming the director');
	like($flat, qr/safe get \Q$LOCK_PATH\E/, 'and giving the command that shows the lock');
	like($flat, qr/safe vault status/, 'and the one that checks the vault');
	like($flat, qr/stale/, 'and when other deploys can take it');
	is(scalar(grep { $_->[0] eq 'clear' } @{$vault->{log}}), 0, 'and no clear was sent');

	delete $vault->{read_error};
	is(quietly { $bosh->release_network_lock }, 1, 'a release of this process\'s lock returns 1');
	is($bosh->check_network_lock->{status}, 'unlocked', 'and removes it');
	is(quietly { $bosh->release_network_lock }, 0, 'with nothing of ours to release, it returns 0');
};

subtest 'a release whose clear fails is logged as a failed release, and never dies' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');
	$vault->{clear_refused} = "Could not clear $LOCK_PATH in vault at https://vault.example.com:8200:\n403 permission denied\n";
	my ($result, $out);
	lives_ok { $out = join('', output_from(sub { $result = $bosh->release_network_lock })) }
		'a release the vault refuses does not die';
	ok(!defined($result), 'it reports that the release failed');
	my $flat = $out =~ s/\s+/ /gr;
	like($flat, qr/could not be released.*permission denied/, 'and logs that the lock could not be released, and why');
	unlike($flat, qr/could not be read/, 'without saying the state was unreadable');
	like($flat, qr/\Q$LOCK_PATH\E/, 'and where the lock is stored');
	like($flat, qr/stale/, 'and when other deploys can take it');
};

subtest 'a release that finds the lock taken by another process reports that it released nothing' => sub {
	my $vault = MockLockVault->new;
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');

	# Another process clears the lock as stale and takes it between the
	# release's ownership check and its clear.
	$vault->after_next_read(sub {
		$vault->{store}{$LOCK_PATH} = {%{$vault->{store}{$LOCK_PATH}}, token => 'another-process', pid => ''.getppid()};
	});
	my $result;
	my $out = join('', output_from(sub { $result = $bosh->release_network_lock }));
	is($result, 0, 'the release reports that nothing was released');
	unlike($out, qr/done/, 'without saying it was done');
	like($out, qr/no longer held by this process/, 'and says the lock was no longer this process\'s');
	is(scalar(grep { $_->[0] eq 'clear' } @{$vault->{log}}), 0, 'no clear was sent');
	is($vault->{store}{$LOCK_PATH}{token}, 'another-process', 'and the other process\'s lock is left alone');
};

done_testing;
