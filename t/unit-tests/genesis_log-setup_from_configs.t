#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use File::Temp qw/tempdir/;
use Cwd qw/abs_path/;

sub mktmp { abs_path(tempdir(CLEANUP => 1)) }

use Genesis;   # pre-load so our stubs below survive
use_ok 'Genesis::Log';

# ===========================================================================
# setup_from_configs orchestration
#
# Wires the six primitives (parse_lifespan, find_log_files,
# apply_retention_policy, cleanup_old_logs, apply_on_reuse, and the
# active-log-path env vars) into the user-facing setup entry point.
# ===========================================================================

# Track what configure_log was called with so we can assert orchestration.
our @CONFIGURE_CALLS;
our @ON_REUSE_CALLS;
our @CLEANUP_CALLS;
our @LOG_ENTRIES;

sub reset_tracking {
	@CONFIGURE_CALLS = ();
	@ON_REUSE_CALLS  = ();
	@CLEANUP_CALLS   = ();
	@LOG_ENTRIES     = ();
}

sub depr_entries {
	grep { ($_->{opts}{context} // '') eq 'deprecation' } @LOG_ENTRIES;
}

# Install stubs once, after Genesis::Log is loaded
{
	no warnings 'redefine';
	my $real_apply_on_reuse  = \&Genesis::Log::apply_on_reuse;
	my $real_cleanup_old     = \&Genesis::Log::cleanup_old_logs;

	*Genesis::Log::apply_on_reuse = sub {
		my ($path, $mode) = @_;
		push @ON_REUSE_CALLS, { path => $path, mode => $mode };
		$real_apply_on_reuse->($path, $mode);
	};

	*Genesis::Log::cleanup_old_logs = sub {
		my ($cfg, %opts) = @_;
		push @CLEANUP_CALLS, { cfg => $cfg, opts => \%opts };
		$real_cleanup_old->($cfg, %opts);
	};

	# Stub configure_log to record args without disturbing logger state
	*Genesis::Log::configure_log = sub {
		my ($self, @args) = @_;
		my $log = (scalar(@args) % 2) ? shift @args : '<terminal>';
		push @CONFIGURE_CALLS, { log => $log, opts => { @args } };
		return $self;
	};

	# Capture all log entries at the lowest hook (_log).  This catches
	# deprecation entries regardless of whether they were emitted via
	# Genesis::deprecation, $self->warning({context=>...}, ...), or any
	# other route.
	*Genesis::Log::_log = sub {
		my ($self, $level, @contents) = @_;
		my %opts;
		while (ref($contents[0]) eq 'HASH') {
			my %m = %{shift @contents};
			@opts{keys %m} = values %m;
		}
		my $msg = scalar(@contents) > 1
			? sprintf($contents[0], @contents[1..$#contents])
			: $contents[0];
		push @LOG_ENTRIES, { level => $level, opts => \%opts, msg => $msg };
	};
}

# ---------- happy path: fresh setup, no inheritance ----------

subtest 'fresh single-log setup invokes on_reuse, cleanup, configure, set_active' => sub {
	plan tests => 6;
	reset_tracking();
	local %ENV = (%ENV);
	delete $ENV{GENESIS_ACTIVE_LOG_0};
	$ENV{GENESIS_COMMAND}     = 'deploy';
	$ENV{GENESIS_ENVIRONMENT} = 'staging';

	my $tmp = mktmp();
	Genesis::Log->setup_from_configs([
		{
			file     => "$tmp/log",
			lifespan => '5',
			on_reuse => 'truncate',
			level    => 'INFO',
		},
	]);

	# apply_on_reuse called against the realized path
	is scalar(@ON_REUSE_CALLS), 1, 'apply_on_reuse invoked once';
	is $ON_REUSE_CALLS[0]{path}, "$tmp/log", 'on_reuse received realized path';
	is $ON_REUSE_CALLS[0]{mode}, 'truncate', 'on_reuse mode passed through';

	# cleanup_old_logs called with the original template + parsed config
	is scalar(@CLEANUP_CALLS), 1, 'cleanup_old_logs invoked once';
	is $CLEANUP_CALLS[0]{opts}{active_path}, "$tmp/log",
		'active_path is the realized path';

	# configure_log called and active path recorded
	is $ENV{GENESIS_ACTIVE_LOG_0}, "$tmp/log",
		'GENESIS_ACTIVE_LOG_0 set to realized path for child inheritance';
};

# ---------- inheritance: child process skips cleanup ----------

subtest 'inherited log path: skips on_reuse + cleanup, configures with inherited path' => sub {
	plan tests => 4;
	reset_tracking();
	local %ENV = (%ENV);
	$ENV{GENESIS_ACTIVE_LOG_0} = '/parent/inherited.log';
	$ENV{GENESIS_COMMAND}     = 'deploy';
	$ENV{GENESIS_ENVIRONMENT} = 'staging';

	my $tmp = mktmp();
	Genesis::Log->setup_from_configs([
		{
			file     => "$tmp/local-template.log",
			lifespan => '5',
			on_reuse => 'rotate',
			level    => 'INFO',
		},
	]);

	is scalar(@ON_REUSE_CALLS), 0, 'apply_on_reuse skipped on inherit';
	is scalar(@CLEANUP_CALLS),  0, 'cleanup_old_logs skipped on inherit';
	is scalar(@CONFIGURE_CALLS), 1, 'configure_log still invoked';
	is $CONFIGURE_CALLS[0]{log}, '/parent/inherited.log',
		'configure_log uses the inherited path, not the local template';
};

# ---------- reserve_slots: realized path materialized vs not ----------

subtest 'reserve_slots: existing realized path => 0, non-existent => 1' => sub {
	plan tests => 2;

	# Case 1: pre-existing static path => after on_reuse (truncate), file still exists
	reset_tracking();
	local %ENV = (%ENV);
	delete $ENV{GENESIS_ACTIVE_LOG_0};
	my $tmp1 = mktmp();
	open my $fh1, '>', "$tmp1/static.log" or die "create: $!";
	print $fh1 "exists\n";
	close $fh1;

	Genesis::Log->setup_from_configs([
		{ file => "$tmp1/static.log", lifespan => '5', on_reuse => 'truncate' },
	]);
	is $CLEANUP_CALLS[0]{opts}{reserve_slots}, 0,
		'static existing path post-truncate => reserve 0';

	# Case 2: non-existent realized path (no file yet) => +1 reserve
	reset_tracking();
	delete $ENV{GENESIS_ACTIVE_LOG_0};
	my $tmp2 = mktmp();
	# Path is fresh; no file exists yet
	Genesis::Log->setup_from_configs([
		{ file => "$tmp2/never-existed.log", lifespan => '5', on_reuse => 'truncate' },
	]);
	is $CLEANUP_CALLS[0]{opts}{reserve_slots}, 1,
		'non-existent realized path => reserve 1';
};

# ---------- deprecation warning suppression ----------

subtest 'lifespan: current => deprecation-tagged log entry created' => sub {
	plan tests => 2;
	reset_tracking();
	local %ENV = (%ENV);
	delete $ENV{GENESIS_ACTIVE_LOG_0};
	delete $ENV{GENESIS_SUPPRESS_DEPRECATIONS};

	my $tmp = mktmp();
	Genesis::Log->setup_from_configs([
		{ file => "$tmp/log", lifespan => 'current' },
	]);

	my @depr = depr_entries();
	ok scalar(@depr), 'a deprecation-context entry was created';
	ok( ($depr[0]{msg} =~ /current.*deprecated/i),
		'message mentions the deprecation' )
		or diag "msg: $depr[0]{msg}";
};

subtest '_context_suppressed: env var GENESIS_SUPPRESS_DEPRECATIONS=1 suppresses globally' => sub {
	plan tests => 2;
	local %ENV = (%ENV);

	delete $ENV{GENESIS_SUPPRESS_DEPRECATIONS};
	ok( !Genesis::Log::_context_suppressed('<terminal>', {}, 'deprecation'),
		'no env var, no per-target list => not suppressed' );

	$ENV{GENESIS_SUPPRESS_DEPRECATIONS} = 1;
	ok( Genesis::Log::_context_suppressed('<terminal>', {}, 'deprecation'),
		'env var GENESIS_SUPPRESS_DEPRECATIONS=1 => suppressed globally' );
};

# ---------- multiple logs with mixed inheritance ----------

subtest 'mixed inherited + fresh logs: orchestration per index' => sub {
	plan tests => 4;
	reset_tracking();
	local %ENV = (%ENV);
	delete $ENV{GENESIS_ACTIVE_LOG_1};
	$ENV{GENESIS_ACTIVE_LOG_0} = '/parent/inherited.log';

	my $tmp = mktmp();
	Genesis::Log->setup_from_configs([
		{ file => "$tmp/first.log",  lifespan => '5' },   # index 0 - inherits
		{ file => "$tmp/second.log", lifespan => '3' },   # index 1 - fresh
	]);

	# Index 0: inherited; on_reuse + cleanup skipped
	is scalar(@ON_REUSE_CALLS), 1,
		'on_reuse only fires for the non-inherited log';
	is $ON_REUSE_CALLS[0]{path}, "$tmp/second.log",
		'on_reuse ran on the fresh log (index 1)';

	# configure_log invoked twice - once with inherited, once with realized
	is scalar(@CONFIGURE_CALLS), 2, 'configure_log called for both logs';
	is $CONFIGURE_CALLS[0]{log}, '/parent/inherited.log',
		'index 0 configured with inherited path';
};

# ---------- _context_suppressed per-target list semantics ----------

subtest '_context_suppressed: per-target list is authoritative when present' => sub {
	plan tests => 4;
	local %ENV = (%ENV);
	$ENV{GENESIS_SUPPRESS_DEPRECATIONS} = 1;   # global is suppress

	# Target explicitly lists 'deprecation' -> suppressed
	ok( Genesis::Log::_context_suppressed(
		'/some/log',
		{ suppress_contexts => ['deprecation'] },
		'deprecation',
	), 'context in per-target list => suppressed (regardless of global)' );

	# Target list exists but doesn't include 'deprecation' -> emit,
	# even though global says suppress.  Per-target wins.
	ok( !Genesis::Log::_context_suppressed(
		'/some/log',
		{ suppress_contexts => ['other-context'] },
		'deprecation',
	), 'context absent from per-target list => NOT suppressed (overrides global)' );

	# No per-target list, global env var on -> suppressed
	ok( Genesis::Log::_context_suppressed(
		'/some/log',
		{},
		'deprecation',
	), 'no per-target list, global env on => suppressed' );

	# No per-target list, global env off -> not suppressed
	delete $ENV{GENESIS_SUPPRESS_DEPRECATIONS};
	ok( !Genesis::Log::_context_suppressed(
		'/some/log',
		{},
		'deprecation',
	), 'no per-target list, global env off => not suppressed' );
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
