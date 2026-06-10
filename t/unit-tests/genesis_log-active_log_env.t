#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use_ok 'Genesis::Log';

# ===========================================================================
# Child-process safety: per-index GENESIS_ACTIVE_LOG_<N>
#
# The user's .genesis/config logs array is invariant across a Genesis
# process tree (parent and child read the same file).  Each log config
# has a stable array index.  We share the parent's realized log paths
# via per-index env vars - no count, no bookkeeping.
#
# Two helpers:
#   set_active_log_path($i, $path) - parent records realized path at $i
#   get_active_log_path($i)        - child reads inherited path at $i
# ===========================================================================

sub set_path { Genesis::Log::set_active_log_path(@_) }
sub get_path { Genesis::Log::get_active_log_path(@_) }

# ---------- set / get round-trip ----------

subtest 'set then get returns the same path' => sub {
	plan tests => 1;
	local %ENV = (%ENV);
	set_path(0, '/var/log/a.log');
	is get_path(0), '/var/log/a.log',
		'value at index 0 round-trips';
};

subtest 'multiple indices kept independent' => sub {
	plan tests => 3;
	local %ENV = (%ENV);
	set_path(0, '/a');
	set_path(1, '/b');
	set_path(2, '/c');
	is get_path(0), '/a', 'index 0';
	is get_path(1), '/b', 'index 1';
	is get_path(2), '/c', 'index 2';
};

# ---------- unset / missing ----------

subtest 'get for unset index returns undef' => sub {
	plan tests => 2;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_ACTIVE_LOG_0};
	delete $ENV{GENESIS_ACTIVE_LOG_5};
	is get_path(0), undef, 'index 0 unset => undef';
	is get_path(5), undef, 'index 5 unset => undef';
};

subtest 'sparse indices: only set ones return; gaps stay undef' => sub {
	plan tests => 3;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_ACTIVE_LOG_1};
	set_path(0, '/a');
	# index 1 deliberately not set
	set_path(2, '/c');
	is get_path(0), '/a',  'index 0';
	is get_path(1), undef, 'index 1 (gap) => undef';
	is get_path(2), '/c',  'index 2';
};

# ---------- env-var contract ----------

subtest 'set populates the documented env var name' => sub {
	plan tests => 2;
	local %ENV = (%ENV);
	set_path(3, '/tmp/foo.log');
	is $ENV{GENESIS_ACTIVE_LOG_3}, '/tmp/foo.log',
		'GENESIS_ACTIVE_LOG_3 set to the path';
	# Round-trip via the documented env var
	delete $ENV{GENESIS_ACTIVE_LOG_3};
	$ENV{GENESIS_ACTIVE_LOG_3} = '/from/parent.log';
	is get_path(3), '/from/parent.log',
		'get reads the documented env var directly';
};

subtest 'no GENESIS_ACTIVE_LOG_COUNT is set or consulted' => sub {
	plan tests => 2;
	local %ENV = (%ENV);
	delete $ENV{GENESIS_ACTIVE_LOG_COUNT};
	set_path(0, '/a');
	set_path(1, '/b');
	ok( !exists $ENV{GENESIS_ACTIVE_LOG_COUNT},
		'COUNT env var is not introduced by set' );
	# get should work even with no COUNT - it only consults its own index
	is get_path(0), '/a', 'get works without COUNT in env';
};

# ---------- propagation through Genesis::run ----------
#
# The whole point of these env vars is that child processes can read
# them.  Verify that Genesis::run inherits them automatically and that
# the defensive restore in run() preserves them even if a caller
# unintentionally passes env => { GENESIS_ACTIVE_LOG_N => undef }.

use Genesis;

subtest 'Genesis::run inherits GENESIS_ACTIVE_LOG_<N> to the child' => sub {
	plan tests => 1;
	local %ENV = (%ENV);
	set_path(0, '/parent/run.log');

	my ($out, $rc) = Genesis::run('echo "$GENESIS_ACTIVE_LOG_0"');
	is $out, '/parent/run.log',
		'child sees the parent-set GENESIS_ACTIVE_LOG_0';
};

subtest 'Genesis::run defends against opts{env} clearing GENESIS_ACTIVE_LOG_<N>' => sub {
	plan tests => 1;
	local %ENV = (%ENV);
	set_path(2, '/parent/inherit.log');

	# A clumsy caller passes undef to "clean up" - we should still
	# inherit the active log path in the child.
	my ($out, $rc) = Genesis::run(
		{ env => { GENESIS_ACTIVE_LOG_2 => undef } },
		'echo "$GENESIS_ACTIVE_LOG_2"',
	);
	is $out, '/parent/inherit.log',
		'defensive restore preserves inheritance despite opts{env}';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
