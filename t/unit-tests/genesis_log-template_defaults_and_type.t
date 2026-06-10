#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use Genesis;   # pre-load so our _log stub captures
use_ok 'Genesis::Log';

# ===========================================================================
# Template grammar extensions:
#   {name||default}  - fallback literal when name resolves to empty
#   {type}           - new identity var resolving to $ENV{GENESIS_TYPE}
#
# Both extensions affect expand_log_template (runtime) and
# template_to_glob_pattern (cleanup glob).
# ===========================================================================

sub expand { Genesis::Log->new->expand_log_template($_[0]) }
sub glob_for { Genesis::Log::template_to_glob_pattern(@_) }

# Capture deprecation-context log entries to assert on the
# malformed-template warning.
our @WARNINGS;
{
	no warnings 'redefine';
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
		push @WARNINGS, { level => $level, opts => \%opts, msg => $msg };
	};
}
sub reset_warnings { @WARNINGS = () }
sub depr_warnings  { grep { ($_->{opts}{context} // '') eq 'deprecation' } @WARNINGS }

# ---------- {type} resolves to $ENV{GENESIS_TYPE} ----------

subtest '{type} resolves to GENESIS_TYPE at expansion' => sub {
	plan tests => 2;
	local $ENV{GENESIS_TYPE} = 'bosh';
	is expand('genesis-{type}.log'), 'genesis-bosh.log',
		'{type} substituted with bosh';

	$ENV{GENESIS_TYPE} = 'shield';
	is expand('genesis-{type}.log'), 'genesis-shield.log',
		'{type} substituted with shield';
};

subtest '{type} with empty/missing GENESIS_TYPE drops the var' => sub {
	plan tests => 1;
	delete local $ENV{GENESIS_TYPE};
	is expand('genesis-{type}.log'), 'genesis-.log',
		'empty {type} drops to nothing (no separators to remove here)';
};

subtest '{-type} with set GENESIS_TYPE keeps the leading separator' => sub {
	plan tests => 2;
	local $ENV{GENESIS_TYPE} = 'vault';
	is expand('genesis{-type}.log'), 'genesis-vault.log',
		'{-type} = -vault';

	delete local $ENV{GENESIS_TYPE};
	is expand('genesis{-type}.log'), 'genesis.log',
		'{-type} with empty type drops the separator too';
};

# ---------- {name||default} substitution ----------

subtest '{name||default}: value set => name wins' => sub {
	plan tests => 1;
	local $ENV{GENESIS_TYPE} = 'shield';
	is expand('{type||bosh}'), 'shield',
		'value-of-name wins over default when name is set';
};

subtest '{name||default}: value empty => default emitted' => sub {
	plan tests => 1;
	delete local $ENV{GENESIS_TYPE};
	is expand('{type||bosh}'), 'bosh',
		'default emitted when name is empty';
};

subtest '{env||local} works for env variable too' => sub {
	plan tests => 2;
	local $ENV{GENESIS_ENVIRONMENT} = 'staging';
	is expand('{env||local}'), 'staging',
		'env set => emits staging';

	delete local $ENV{GENESIS_ENVIRONMENT};
	is expand('{env||local}'), 'local',
		'env empty => emits local default';
};

subtest 'composed template: {-command}-{env||fallback}.log' => sub {
	plan tests => 2;
	local $ENV{GENESIS_COMMAND}     = 'deploy';
	local $ENV{GENESIS_ENVIRONMENT} = 'staging';
	is expand('{command}-{env||local}.log'),
		'deploy-staging.log',
		'all values set';

	delete local $ENV{GENESIS_ENVIRONMENT};
	is expand('{command}-{env||local}.log'),
		'deploy-local.log',
		'env defaulted; command still substituted';
};

# ---------- mutual exclusivity: seps + default ----------

subtest '{-name||default} is malformed: emits deprecation warning' => sub {
	plan tests => 2;
	reset_warnings();
	local $ENV{GENESIS_ENVIRONMENT} = 'staging';
	expand('{-env||local}');
	my @depr = depr_warnings();
	ok scalar(@depr) > 0,
		'deprecation-context warning emitted for malformed combination';
	ok( ($depr[0]{msg} =~ /separator.*default|default.*separator|malformed/i),
		'warning mentions separator/default conflict' )
		or diag "msg: $depr[0]{msg}";
};

subtest '{-name||default} with value: default authoritative, seps ignored' => sub {
	plan tests => 2;
	reset_warnings();
	local $ENV{GENESIS_ENVIRONMENT} = 'staging';
	is expand('{-env||local}'), 'staging',
		'name value emitted (default takes form precedence, seps dropped)';

	reset_warnings();
	delete local $ENV{GENESIS_ENVIRONMENT};
	is expand('{-env||local}'), 'local',
		'default emitted when name empty (seps still ignored)';
};

# ---------- template_to_glob_pattern handling ----------

subtest 'glob: {type} wildcards in absence of concrete' => sub {
	plan tests => 1;
	is glob_for('/tmp/{type}.log'), '/tmp/*.log',
		'{type} => * wildcard';
};

subtest 'glob: {type} concrete substitution' => sub {
	plan tests => 1;
	is glob_for('/tmp/{type}.log', type => 'vault'),
		'/tmp/vault.log',
		'%concrete type=vault substituted';
};

subtest 'glob: {name||default} treated as the name variable' => sub {
	plan tests => 2;
	is glob_for('/tmp/{type||bosh}.log'),
		'/tmp/*.log',
		'no concrete: wildcards the var (defaults are a runtime concern)';
	is glob_for('/tmp/{type||bosh}.log', type => 'vault'),
		'/tmp/vault.log',
		'concrete value substituted; default ignored at glob time';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
