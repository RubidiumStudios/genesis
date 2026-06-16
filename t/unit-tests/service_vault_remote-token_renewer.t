#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use lib 'lib';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;
use POSIX ();

use_ok 'Service::Vault';
use_ok 'Service::Vault::Remote';
use Genesis;

# ===========================================================================
# Service::Vault::Remote token renewer.
#
# Forked-child renewer for vault token renewal tied to the lifetime of the
# parent vault instance.  Built in atomic steps; this file grows with each
# commit.
#
# Step 1: _token_renewal_available($info) — pure predicate.
# Step 3: _run_renewer_loop — testable loop body with injected callbacks
#         for sleep, parent-liveness check, vault query, and token_info.
#         Returns an exit code instead of calling POSIX::_exit so unit
#         tests can drive it without forking.
# Step 4: start_token_renewer / stop_token_renewer / renewer_pid —
#         lifecycle plumbing.  Exercises real fork() for the kill/waitpid
#         path; the loop body is stubbed so the child only sleeps.
# Step 5: Wire DESTROY -> stop_token_renewer, authenticate ->
#         start_token_renewer on success.
# ===========================================================================

sub make_remote {
	my (%args) = @_;
	return Service::Vault::Remote->new(
		$args{url}       // 'https://vault.example.com:8200',
		$args{name}      // 'test-vault',
		$args{verify}    // 1,
		$args{namespace} // '',
		$args{strongbox},
		$args{mount}     // '/secret/',
	);
}

# ---------- _token_renewal_available: pure predicate ----------

subtest '_token_renewal_available accepts renewable token with positive ttl' => sub {
	plan tests => 1;
	my $v = make_remote();
	ok($v->_token_renewal_available({data => {renewable => 1, ttl => 3600}}),
		'renewable=1, ttl=3600 => available');
};

subtest '_token_renewal_available rejects non-renewable token' => sub {
	plan tests => 1;
	my $v = make_remote();
	ok(!$v->_token_renewal_available({data => {renewable => 0, ttl => 3600}}),
		'renewable=0 => unavailable');
};

subtest '_token_renewal_available rejects zero ttl' => sub {
	plan tests => 1;
	my $v = make_remote();
	ok(!$v->_token_renewal_available({data => {renewable => 1, ttl => 0}}),
		'ttl=0 => unavailable');
};

subtest '_token_renewal_available rejects undefined ttl' => sub {
	plan tests => 1;
	my $v = make_remote();
	ok(!$v->_token_renewal_available({data => {renewable => 1, ttl => undef}}),
		'ttl=undef => unavailable');
};

subtest '_token_renewal_available rejects empty/missing token_info' => sub {
	plan tests => 2;
	my $v = make_remote();
	ok(!$v->_token_renewal_available({}), 'empty info => unavailable');
	ok(!$v->_token_renewal_available(undef), 'undef info => unavailable');
};

# ---------- _run_renewer_loop: schedule math ----------

subtest 'loop sleeps ttl/2 for ttl >= 120' => sub {
	plan tests => 2;
	my $v = make_remote();
	my @slept;
	my $rc = $v->_run_renewer_loop(
		parent_pid => 1,
		ttl        => 600,
		sleep_fn   => sub { push @slept, $_[0] },
		kill_fn    => sub { 1 },
		query_fn   => sub { ('', 0, '') },
		# After first renew, token becomes non-renewable so the loop
		# terminates cleanly without busy-looping the test harness.
		info_fn    => sub { {data => {renewable => 0, ttl => 1200}} },
	);
	is(scalar(@slept), 1, 'one sleep before termination');
	is($slept[0], 300, 'ttl=600 sleeps for 300 (half-life)');
};

subtest 'loop floors sleep at 60s for ttl < 120' => sub {
	plan tests => 1;
	my $v = make_remote();
	my @slept;
	$v->_run_renewer_loop(
		parent_pid => 1,
		ttl        => 90,
		sleep_fn   => sub { push @slept, $_[0] },
		kill_fn    => sub { 1 },
		query_fn   => sub { ('', 0, '') },
		info_fn    => sub { {data => {renewable => 0, ttl => 0}} },
	);
	is($slept[0], 60, 'ttl=90 sleeps for 60 (floor)');
};

subtest 'loop uses fresh ttl after renew' => sub {
	plan tests => 3;
	my $v = make_remote();
	my @slept;
	my $iter = 0;
	$v->_run_renewer_loop(
		parent_pid => 1,
		ttl        => 600,
		sleep_fn   => sub { push @slept, $_[0] },
		kill_fn    => sub { 1 },
		query_fn   => sub { ('', 0, '') },
		info_fn    => sub {
			$iter++;
			# First wake: token renewed, new ttl=1200.
			# Second wake: non-renewable, loop exits.
			return $iter == 1
				? {data => {renewable => 1, ttl => 1200}}
				: {data => {renewable => 0, ttl => 1200}};
		},
	);
	is(scalar(@slept), 2, 'two sleeps before termination');
	is($slept[0], 300, 'first sleep is initial ttl/2 = 300');
	is($slept[1], 600, 'second sleep uses renewed ttl/2 = 600');
};

# ---------- _run_renewer_loop: termination conditions ----------

subtest 'loop exits 0 when parent dies (kill_fn returns false)' => sub {
	plan tests => 2;
	my $v = make_remote();
	my $renew_called = 0;
	my $rc = $v->_run_renewer_loop(
		parent_pid => 99999,
		ttl        => 600,
		sleep_fn   => sub { },
		kill_fn    => sub { 0 },   # parent reported dead immediately
		query_fn   => sub { $renew_called++; ('', 0, '') },
		info_fn    => sub { {data => {renewable => 1, ttl => 600}} },
	);
	is($rc, 0, 'returns 0 on parent-dead');
	is($renew_called, 0, 'renew not attempted after parent-dead check');
};

subtest 'loop exits 1 when renew fails' => sub {
	plan tests => 1;
	my $v = make_remote();
	my $rc = $v->_run_renewer_loop(
		parent_pid => 1,
		ttl        => 600,
		sleep_fn   => sub { },
		kill_fn    => sub { 1 },
		query_fn   => sub { ('error', 1, 'permission denied') },
		info_fn    => sub { {data => {renewable => 1, ttl => 600}} },
	);
	is($rc, 1, 'returns 1 on renew failure (parent will re-auth next call)');
};

subtest 'loop exits 0 when token becomes non-renewable' => sub {
	plan tests => 1;
	my $v = make_remote();
	my $rc = $v->_run_renewer_loop(
		parent_pid => 1,
		ttl        => 600,
		sleep_fn   => sub { },
		kill_fn    => sub { 1 },
		query_fn   => sub { ('', 0, '') },
		info_fn    => sub { {data => {renewable => 0, ttl => 3600}} },
	);
	is($rc, 0, 'returns 0 when token transitions to non-renewable');
};

subtest 'loop exits 0 when ttl decays to zero' => sub {
	plan tests => 1;
	my $v = make_remote();
	my $rc = $v->_run_renewer_loop(
		parent_pid => 1,
		ttl        => 600,
		sleep_fn   => sub { },
		kill_fn    => sub { 1 },
		query_fn   => sub { ('', 0, '') },
		info_fn    => sub { {data => {renewable => 1, ttl => 0}} },
	);
	is($rc, 0, 'returns 0 when ttl decays to 0');
};

# ---------- renewer_pid: simple accessor ----------

subtest 'renewer_pid returns stored pid' => sub {
	plan tests => 2;
	my $v = make_remote();
	is($v->renewer_pid, undef, 'undef when no pid stored');
	$v->{__renewer_pid} = 12345;
	is($v->renewer_pid, 12345, 'returns the stored pid');
};

# ---------- start_token_renewer: decision + fork ----------

subtest 'start_token_renewer returns undef when token not renewable' => sub {
	plan tests => 2;
	my $v = make_remote();
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::token_info = sub {
		{data => {renewable => 0, ttl => 3600}};
	};
	use warnings 'redefine';
	my $pid = $v->start_token_renewer();
	is($pid, undef, 'returns undef when token not renewable');
	is($v->renewer_pid, undef, 'no renewer_pid stored');
};

subtest 'start_token_renewer returns undef when ttl is zero' => sub {
	plan tests => 1;
	my $v = make_remote();
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::token_info = sub {
		{data => {renewable => 1, ttl => 0}};
	};
	use warnings 'redefine';
	is($v->start_token_renewer(), undef, 'returns undef when ttl is zero');
};

subtest 'start_token_renewer sets __renewer_armed_at marker on success' => sub {
	plan tests => 3;
	my $v = make_remote();
	is($v->{__renewer_armed_at}, undef, 'precondition: marker is unset');
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::token_info = sub {
		{data => {renewable => 1, ttl => 3600}};
	};
	local *Service::Vault::Remote::_run_renewer_loop = sub {
		sleep 30;
		return 0;
	};
	use warnings 'redefine';

	my $before = time;
	my $pid = $v->start_token_renewer;
	ok(defined($v->{__renewer_armed_at}),
		'__renewer_armed_at defined after successful start');
	cmp_ok($v->{__renewer_armed_at}, '>=', $before,
		'marker reflects start time (not stale)');

	# Cleanup
	kill 'TERM', $pid;
	waitpid($pid, 0);
};

subtest 'start_token_renewer does NOT set marker when not renewable' => sub {
	plan tests => 1;
	my $v = make_remote();
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::token_info = sub {
		{data => {renewable => 0, ttl => 3600}};
	};
	use warnings 'redefine';
	$v->start_token_renewer;
	is($v->{__renewer_armed_at}, undef,
		'marker remains undef when no renewer started');
};

subtest 'start_token_renewer forks a child and stores its pid' => sub {
	plan tests => 4;
	my $v = make_remote();
	no warnings 'redefine', 'once';
	# Renewable token so we enter the fork path.
	local *Service::Vault::Remote::token_info = sub {
		{data => {renewable => 1, ttl => 3600}};
	};
	# Stub the loop body so the child just sleeps (no real `safe` calls).
	# The child inherits this stub via fork.
	local *Service::Vault::Remote::_run_renewer_loop = sub {
		sleep 30;
		return 0;
	};
	use warnings 'redefine';

	my $pid = $v->start_token_renewer();
	ok($pid && $pid =~ /^\d+$/, 'returns a positive child pid');
	is($v->renewer_pid, $pid, 'pid stored on the instance');

	# Give the child a moment to enter its sleep
	select(undef, undef, undef, 0.05);
	ok(kill(0, $pid), 'child process is alive');

	# Cleanup so we don't leave a zombie or a 30s-sleep child behind.
	kill 'TERM', $pid;
	waitpid($pid, 0);
	ok(1, 'reaped child');
};

# ---------- stop_token_renewer: lifecycle ----------

subtest 'stop_token_renewer is idempotent when no renewer running' => sub {
	plan tests => 2;
	my $v = make_remote();
	is($v->renewer_pid, undef, 'precondition: no renewer');
	lives_ok { $v->stop_token_renewer() } 'no-op when no pid';
};

subtest 'stop_token_renewer SIGTERMs and reaps a real child' => sub {
	plan tests => 3;
	# Stand-in: a long-sleeping child that the stop path must signal
	# and reap.  Using `exec sleep` rather than perl-level sleep so we
	# don't risk the Perl child inheriting any test-side state.
	my $pid = fork();
	die "fork failed: $!" unless defined $pid;
	if ($pid == 0) {
		exec('sleep', '30') or POSIX::_exit(127);
	}
	# Let exec land
	select(undef, undef, undef, 0.05);
	ok(kill(0, $pid), 'precondition: stand-in child is alive');

	my $v = make_remote();
	$v->{__renewer_pid} = $pid;
	$v->stop_token_renewer();

	is($v->renewer_pid, undef, 'renewer_pid cleared after stop');
	# Give the kernel a moment to deliver SIGTERM + reap
	select(undef, undef, undef, 0.2);
	ok(!kill(0, $pid), 'stand-in child no longer alive');
};

# ---------- dead-man switches ----------

subtest 'start_token_renewer fails closed when token_info dies' => sub {
	plan tests => 2;
	my $v = make_remote();
	no warnings 'redefine', 'once';
	# token_info dies if read_json_from chokes on an empty/malformed
	# vault response.  start_token_renewer must NOT propagate the die —
	# unreachable vault => no renewer, but never a crash inside
	# authenticate().
	local *Service::Vault::Remote::token_info = sub { die "vault unreachable\n" };
	use warnings 'redefine';
	my $pid;
	lives_ok { $pid = $v->start_token_renewer() }
		'no propagation of token_info die';
	is($pid, undef, 'no renewer started when token_info dies');
};

subtest 'start_token_renewer reaps any prior renewer before starting a new one' => sub {
	plan tests => 4;
	my $v = make_remote();
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::token_info = sub {
		{data => {renewable => 1, ttl => 3600}};
	};
	local *Service::Vault::Remote::_run_renewer_loop = sub { sleep 30; 0 };
	use warnings 'redefine';

	my $first = $v->start_token_renewer();
	ok($first, 'first renewer started');
	select(undef, undef, undef, 0.05);
	ok(kill(0, $first), 'first child alive');

	my $second = $v->start_token_renewer();
	isnt($first, $second, 'second start returns a different pid');
	# After a brief wait the first child must be gone.
	select(undef, undef, undef, 0.2);
	ok(!kill(0, $first), 'first child reaped before second started');

	# Cleanup
	kill 'TERM', $second;
	waitpid($second, 0);
};

subtest 'child exits non-zero via POSIX::_exit when loop body dies' => sub {
	plan tests => 3;
	my $v = make_remote();
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::token_info = sub {
		{data => {renewable => 1, ttl => 3600}};
	};
	# Stub the loop body to die immediately.  The eval wrap in
	# start_token_renewer should catch it and POSIX::_exit(2) — bypassing
	# Perl's END blocks.
	local *Service::Vault::Remote::_run_renewer_loop = sub { die "boom\n" };
	use warnings 'redefine';

	my $pid = $v->start_token_renewer();
	ok($pid, 'fork happened despite the loop being doomed');
	my $reaped = waitpid($pid, 0);
	is($reaped, $pid, 'child reaped');
	is($? >> 8, 2, 'child exit code is the eval-wrap sentinel (2)');
};

subtest 'stop_token_renewer escalates to KILL when child ignores TERM' => sub {
	plan tests => 3;
	# Hand-rolled child that ignores TERM.  We do NOT route through
	# start_token_renewer because we need to install $SIG{TERM}='IGNORE'
	# AFTER init_forked_child (which would otherwise install the polite
	# handler).
	my $pid = fork();
	die "fork failed: $!" unless defined $pid;
	if ($pid == 0) {
		# Reset everything the test harness installed, then ignore TERM
		# and sleep.  The parent stop must escalate to KILL.
		$SIG{TERM} = 'IGNORE';
		$SIG{INT}  = 'IGNORE';
		$SIG{HUP}  = 'IGNORE';
		# Use a non-Perl sleep so any inherited signal handling doesn't
		# get a chance to short-circuit us.
		exec('sleep', '60') or POSIX::_exit(127);
	}
	select(undef, undef, undef, 0.05);
	ok(kill(0, $pid), 'precondition: TERM-ignoring child is alive');

	my $v = make_remote();
	$v->{__renewer_pid} = $pid;

	my $t0 = time;
	$v->stop_token_renewer();
	my $elapsed = time - $t0;

	# 20 polls * 0.1s = ~2s ceiling on the TERM phase, then KILL is
	# essentially instant.  Allow generous slack on slow CI.
	cmp_ok($elapsed, '<', 6, 'stop completed within ~6s');
	ok(!kill(0, $pid), 'stand-in child no longer alive');
};

# ---------- authenticate integration: starts renewer on success ----------

subtest 'authenticate starts the renewer after successful auth' => sub {
	plan tests => 2;
	my $v = make_remote();
	my $start_called = 0;
	no warnings 'redefine', 'once';
	# Already-authenticated short-circuit means authenticate() returns
	# self without touching credentials — exactly the path real callers
	# hit on every Genesis command.
	local *Service::Vault::Remote::authenticated      = sub { 1 };
	local *Service::Vault::Remote::start_token_renewer = sub {
		$start_called++;
		return 99997;
	};
	use warnings 'redefine';
	my $ret = $v->authenticate();
	is($ret, $v, 'authenticate returns self on success');
	is($start_called, 1, 'start_token_renewer invoked exactly once');
};

# ---------- DESTROY integration: stops renewer ----------

subtest 'DESTROY calls stop_token_renewer' => sub {
	plan tests => 1;
	my $stopped = 0;
	{
		no warnings 'redefine', 'once';
		local *Service::Vault::Remote::stop_token_renewer = sub {
			$stopped++;
		};
		use warnings 'redefine';
		my $v = make_remote();
		$v->{__renewer_pid} = 99996;
		# Scope exit triggers DESTROY
	}
	is($stopped, 1, 'stop_token_renewer invoked from DESTROY');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
