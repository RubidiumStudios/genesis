#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use_ok 'Service::Vault';
use Genesis;

# ===========================================================================
# Service::Vault::needs_write_confirmation
#
# Whether a write to this target has to be read back before it can be
# treated as landed.  Sources, in priority order:
#   1. GENESIS_VAULT_CONFIRM_WRITES env var ('0' or '1')
#   2. the server's /sys/leader, which reports ha_enabled
#   3. fail safe: confirm
#
# Gated on ha_enabled and nothing else.  NOT on is_self: leadership fails
# over, and the target URL is usually a load balancer, so is_self
# describes whichever node answered that one request rather than the one
# that will serve the next.  ha_enabled is stable for the cluster's life.
#
# Engine-agnostic by construction -- Vault 1.14.4 and OpenBao 2.6.1 both
# report ha_enabled at /sys/leader, so nothing here has to know which it
# is talking to.
# ===========================================================================

sub make_vault {
	my (%args) = @_;
	return Service::Vault->new(
		$args{url}       // 'https://vault.example.com:8200',
		$args{name}      // 'test-vault',
		$args{verify}    // 1,
		$args{namespace} // '',
		$args{strongbox},
		$args{mount}     // '/secret/',
	);
}

# Per-instance stub, so nothing leaks between subtests.
sub stub_query {
	my ($v, $out, $rc, $err) = @_;
	$v->{__calls} = 0;
	$v->{__test_query} = sub { $v->{__calls}++; return ($out, $rc // 0, $err // '') };
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

# safe curl --data-only against /sys/leader, as both engines answer it.
my $HA_OFF = '{"ha_enabled":false,"is_self":false,"leader_address":""}';
my $HA_ON  = '{"ha_enabled":true,"is_self":true,'.
             '"leader_address":"https://10.0.0.5:8200"}';

subtest 'ha_enabled false means no confirmation is needed' => sub {
	plan tests => 1;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_VAULT_CONFIRM_WRITES};

	my $v = make_vault();
	stub_query($v, $HA_OFF, 0);
	ok !$v->needs_write_confirmation,
		'a single-node target reads its own writes, so no confirm';
};

subtest 'ha_enabled true means confirmation is needed' => sub {
	plan tests => 1;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_VAULT_CONFIRM_WRITES};

	my $v = make_vault();
	stub_query($v, $HA_ON, 0);
	ok $v->needs_write_confirmation,
		'an HA target may serve the next read from a lagging standby';
};

subtest 'is_self does not decide it' => sub {
	plan tests => 2;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_VAULT_CONFIRM_WRITES};

	# Leadership fails over, and the URL is usually a load balancer, so
	# being the leader for THIS request says nothing about the next one.
	my $leader = make_vault(name => 'leader');
	stub_query($leader, '{"ha_enabled":true,"is_self":true}', 0);
	ok $leader->needs_write_confirmation,
		'still confirms while talking to the leader';

	my $standby = make_vault(name => 'standby');
	stub_query($standby, '{"ha_enabled":false,"is_self":false}', 0);
	ok !$standby->needs_write_confirmation,
		'and still skips when HA is off, whoever answered';
};

subtest 'an unusable probe fails safe' => sub {
	plan tests => 3;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_VAULT_CONFIRM_WRITES};

	# A confirm we did not need costs one read.  A confirm we needed and
	# skipped loses data with no error, so the doubt resolves to confirm.
	my $unreachable = make_vault(name => 'unreachable');
	stub_query($unreachable, '', 1, 'connection refused');
	ok $unreachable->needs_write_confirmation, 'unreachable => confirm';

	my $garbage = make_vault(name => 'garbage');
	stub_query($garbage, 'not json at all', 0);
	ok $garbage->needs_write_confirmation, 'unparseable => confirm';

	my $silent = make_vault(name => 'silent');
	stub_query($silent, '{"something":"else"}', 0);
	ok $silent->needs_write_confirmation, 'no ha_enabled key => confirm';
};

subtest 'the env var overrides the probe in both directions' => sub {
	plan tests => 2;
	local %ENV = (%ENV);

	$ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
	my $off = make_vault(name => 'forced-off');
	stub_query($off, $HA_ON, 0);           # probe would say yes
	ok !$off->needs_write_confirmation, '0 suppresses it on an HA target';

	$ENV{GENESIS_VAULT_CONFIRM_WRITES} = '1';
	my $on = make_vault(name => 'forced-on');
	stub_query($on, $HA_OFF, 0);           # probe would say no
	ok $on->needs_write_confirmation, '1 forces it on a single-node target';
};

subtest 'the probe runs once per vault' => sub {
	plan tests => 2;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_VAULT_CONFIRM_WRITES};

	my $v = make_vault();
	stub_query($v, $HA_ON, 0);
	$v->needs_write_confirmation for 1..5;
	is $v->{__calls}, 1, 'memoized -- a write loop does not re-probe';

	# False is a real answer, not an absent one, so it must memoize too.
	my $off = make_vault(name => 'off');
	stub_query($off, $HA_OFF, 0);
	$off->needs_write_confirmation for 1..5;
	is $off->{__calls}, 1, 'and a false answer is remembered as well';
};

# ===========================================================================
# Reading a write back before trusting it.
#
# The model is the topology openbao#3877 describes: a write lands on the
# leader, a read is answered from a standby's view, and the standby then
# catches up -- so it is always one operation stale.  `safe set` is
# read-modify-write and its read goes through that same standby, which is
# how a write merges into a base that no longer exists.
# ===========================================================================

# $state->{leader} is what the path actually holds.
sub install_lagging_vault {
	my ($v, %opt) = @_;
	my $state = {
		leader  => {%{$opt{preexisting} // {}}},
		standby => {%{$opt{preexisting} // {}}},
		reads   => 0,
		writes  => 0,
	};
	$v->{__state} = $state;

	$v->{__test_query} = sub {
		my ($cmd, @args) = @_;
		if ($cmd eq 'set') {
			$state->{writes}++;
			my (undef, @pairs) = @args;
			# read-modify-write, through the standby's stale view
			my %base = %{$state->{standby}};
			for my $pair (@pairs) {
				my ($k, $val) = split /=/, $pair, 2;
				$base{$k} = $val;
			}
			$state->{leader} = \%base;
			return ('', 0, '');
		}
		if ($cmd eq 'rm') {
			$state->{leader} = {};
			return ('', 0, '');
		}
		if ($cmd eq 'exists') {
			my $answer = scalar(CORE::keys %{$state->{standby}}) ? 1 : 0;
			$state->{standby} = {%{$state->{leader}}};
			return $answer;
		}
		return ('', 0, '');
	};

	# Confirmation compares values, so it reads through get() rather than
	# a key listing -- no path prefix is involved at any point.
	$v->{__get} = sub {
		$state->{reads}++;
		my %answer = %{$state->{standby}};
		$state->{standby} = {%{$state->{leader}}};   # catches up after answering
		return \%answer;
	};
	return $state;
}

{
	no warnings 'redefine', 'once';
	*Service::Vault::get = sub {
		my ($self, $path, $key) = @_;
		return $self->{__get}->($path) if $self->{__get} && !defined($key);
		return {};
	};
}

# Comfortably past the 900-character guard, so it chunks.
sub chunky {
	return map {("key-with-a-reasonably-long-name-$_" => "value-$_" x 4)} (1..45);
}

subtest 'a write is read back before it is trusted' => sub {
	plan tests => 2;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '1';
	local $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT} = '1';

	my $v = make_vault(name => 'confirmed');
	my $state = install_lagging_vault($v);
	$v->set('secret/confirmed', alpha => 1, beta => 2);

	cmp_ok $state->{reads}, '>=', 1, 'the write was followed by a read';
	is_deeply $state->{leader}, {alpha => 1, beta => 2},
		'and the value is what was asked for';
};

subtest 'no confirmation when the target is not HA' => sub {
	plan tests => 2;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
	local $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT} = '1';

	my $v = make_vault(name => 'single-node');
	my $state = install_lagging_vault($v);
	$v->set('secret/single', alpha => 1, beta => 2);

	is $state->{reads}, 0, 'a single-node target pays no extra round-trip';
	cmp_ok $state->{writes}, '>=', 1, 'the write still happened';
};

subtest 'the final write is confirmed, not just the chunks before it' => sub {
	plan tests => 2;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '1';
	local $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT} = '1';

	# A guard that only runs between chunks leaves the last write with
	# nothing after it, and an unchunked payload with nothing at all.
	my $multi = make_vault(name => 'tail-multi');
	my $ms = install_lagging_vault($multi);
	$multi->set('secret/tail/multi', chunky());
	cmp_ok $ms->{reads}, '>=', $ms->{writes},
		'multi-chunk: every write has a read after it';

	my $single = make_vault(name => 'tail-single');
	my $ss = install_lagging_vault($single);
	$single->set('secret/tail/single', alpha => 1);
	cmp_ok $ss->{reads}, '>=', 1,
		'single-chunk: an unchunked write is confirmed too';
};

subtest 'a lag that catches up is waited out, not failed' => sub {
	plan tests => 2;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '1';
	local $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT} = '2';
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	# The counterpart to the stale-base test below: a standby that does
	# catch up must succeed, or the guard is just refusing everything.
	my $v = make_vault(name => 'control');
	my $state = install_lagging_vault($v);
	my %data = chunky();
	my $err = '';
	eval {$v->set('secret/control', %data); 1} or $err = $@;

	is $err, '', 'a lagging standby alone does not fail the write';
	my @missing = grep {!exists $state->{leader}{$_}} CORE::keys %data;
	is_deeply \@missing, [], 'and every key is in the final value';
};

subtest 'a write that merged into a stale base is caught' => sub {
	plan tests => 2;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '1';
	local $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT} = '1';
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	my $v = make_vault(name => 'stale-base');
	my $state = install_lagging_vault($v);

	# One chunk merges into an empty base, discarding its predecessors --
	# the exact shape of the original report.
	my $writes = 0;
	my $inner = $v->{__test_query};
	$v->{__test_query} = sub {
		my ($cmd, @args) = @_;
		$state->{standby} = {} if $cmd eq 'set' && ++$writes == 2;
		return $inner->($cmd, @args);
	};

	my %data = chunky();
	my $err = '';
	eval {$v->set('secret/stale', %data); 1} or $err = $@;

	ok $err, 'the loss is reported rather than returned as success';
	like $err, qr/read back|did not/i, 'and named as a failed read-back';
};

subtest 'clear is confirmed before anything writes over it' => sub {
	plan tests => 2;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '1';
	local $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT} = '1';
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	# An unpropagated delete leaves the old keys as the base the next
	# write merges into, and they survive into the new value.
	my $v = make_vault(name => 'cleared');
	my $state = install_lagging_vault($v, preexisting => {old => 'gone'});
	my $err = '';
	eval {$v->clear('secret/cleared', 0); 1} or $err = $@;

	is $err, '', 'a delete that does propagate is accepted';
	is_deeply $state->{leader}, {}, 'and the path really is empty';
};

subtest 'a clear that leaves keys behind is caught' => sub {
	plan tests => 1;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '1';
	local $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT} = '1';
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	my $v = make_vault(name => 'stuck');
	install_lagging_vault($v, preexisting => {stubborn => 'here'});
	# A delete that never lands: reads keep answering with the old keys.
	$v->{__get} = sub { return {stubborn => 'here'} };

	my $err = '';
	eval {$v->clear('secret/stuck', 0); 1} or $err = $@;
	ok $err, 'a path that will not empty is reported rather than written over';
};

done_testing;
