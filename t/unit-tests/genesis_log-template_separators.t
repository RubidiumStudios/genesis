#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use Genesis;   # pre-load so our Genesis::warning stub below survives
use_ok 'Genesis::Log';

# ===========================================================================
# Template separator syntax: {[sep]name[sep]}
#
# Inside template braces, allow an optional separator from the set
# [-_.~/] before and/or after the variable name.  If the variable
# resolves to a non-empty value, separators are emitted alongside the
# value.  If empty, both separators are dropped.
#
# Covers both:
#   - expand_log_template (runtime path realization)
#   - template_to_glob_pattern (cleanup glob construction)
# ===========================================================================

# ---------- helpers ----------

sub expand {
	my ($template) = @_;
	# expand_log_template is a method on the singleton logger; new()
	# returns the singleton.
	return Genesis::Log->new->expand_log_template($template);
}

sub glob_for { Genesis::Log::template_to_glob_pattern(@_) }

# Track Genesis::warning() invocations for deprecation assertions.
our @WARNINGS;
{
	no warnings 'redefine';
	*Genesis::warning = sub { push @WARNINGS, sprintf(shift, @_) };
}
sub reset_warnings { @WARNINGS = () }

# ---------- expand_log_template: new syntax with non-empty values ----------

subtest 'expand: leading sep with non-empty value' => sub {
	plan tests => 1;
	local $ENV{GENESIS_COMMAND} = 'deploy';
	local $ENV{GENESIS_ENVIRONMENT} = 'staging';
	like expand('genesis-{command}{-env}.log'),
		qr|^genesis-deploy-staging\.log$|,
		'{-env} emits "-staging" with env set';
};

subtest 'expand: trailing sep with non-empty value' => sub {
	plan tests => 1;
	local $ENV{GENESIS_COMMAND} = 'deploy';
	local $ENV{GENESIS_ENVIRONMENT} = 'staging';
	like expand('{env-}{command}.log'),
		qr|^staging-deploy\.log$|,
		'{env-} emits "staging-" with env set';
};

subtest 'expand: both seps with non-empty value' => sub {
	plan tests => 1;
	local $ENV{GENESIS_COMMAND} = 'deploy';
	local $ENV{GENESIS_ENVIRONMENT} = 'staging';
	like expand('{-env-}{command}'),
		qr|^-staging-deploy$|,
		'{-env-} emits "-staging-" with env set';
};

# ---------- expand_log_template: empty value drops seps ----------

subtest 'expand: leading sep with empty value drops both' => sub {
	plan tests => 1;
	local $ENV{GENESIS_COMMAND} = 'ping';
	delete local $ENV{GENESIS_ENVIRONMENT};
	like expand('genesis-{command}{-env}.log'),
		qr|^genesis-ping\.log$|,
		'{-env} drops the leading dash with empty env';
};

subtest 'expand: trailing sep with empty value drops both' => sub {
	plan tests => 1;
	local $ENV{GENESIS_COMMAND} = 'ping';
	delete local $ENV{GENESIS_ENVIRONMENT};
	like expand('{env-}{command}.log'),
		qr|^ping\.log$|,
		'{env-} drops the trailing dash with empty env';
};

subtest 'expand: both seps with empty value drops both' => sub {
	plan tests => 1;
	local $ENV{GENESIS_COMMAND} = 'ping';
	delete local $ENV{GENESIS_ENVIRONMENT};
	like expand('{-env-}{command}'),
		qr|^ping$|,
		'{-env-} drops both dashes with empty env';
};

# ---------- expand_log_template: explicit slash form ----------

subtest 'expand: explicit {env/} with env set' => sub {
	plan tests => 1;
	local $ENV{GENESIS_COMMAND} = 'deploy';
	local $ENV{GENESIS_ENVIRONMENT} = 'staging';
	like expand('logs/{env/}{command}.log'),
		qr|^logs/staging/deploy\.log$|,
		'{env/} emits "staging/" with env set';
};

subtest 'expand: explicit {env/} with env empty drops slash' => sub {
	plan tests => 2;
	reset_warnings();
	local $ENV{GENESIS_COMMAND} = 'ping';
	delete local $ENV{GENESIS_ENVIRONMENT};
	like expand('logs/{env/}{command}.log'),
		qr|^logs/ping\.log$|,
		'{env/} drops the slash with empty env';
	ok( !(grep { /deprecat/i } @WARNINGS),
		'explicit {env/} does NOT emit deprecation warning' );
};

# ---------- expand_log_template: separator character set ----------

subtest 'expand: all five separator chars work' => sub {
	plan tests => 5;
	local $ENV{GENESIS_ENVIRONMENT} = 'staging';
	like expand('{-env}'),  qr|^-staging$|,  'dash separator';
	like expand('{_env}'),  qr|^_staging$|,  'underscore separator';
	like expand('{.env}'),  qr|^\.staging$|, 'dot separator';
	like expand('{~env}'),  qr|^~staging$|,  'tilde separator';
	like expand('{/env}'),  qr|^/staging$|,  'slash separator';
};

# ---------- expand_log_template: bare {name} unchanged ----------

subtest 'expand: bare {name} (no seps) behaves as before' => sub {
	plan tests => 1;
	local $ENV{GENESIS_COMMAND} = 'deploy';
	local $ENV{GENESIS_ENVIRONMENT} = 'staging';
	like expand('{env}/{command}/log.txt'),
		qr|^staging/deploy/log\.txt$|,
		'bare {env}/{command} substitution unchanged';
};

# ---------- expand_log_template: implicit {env}/ slash-removal ----------

subtest 'expand: implicit {env}/ removal still works (back-compat)' => sub {
	plan tests => 1;
	local $ENV{GENESIS_COMMAND} = 'ping';
	delete local $ENV{GENESIS_ENVIRONMENT};
	like expand('logs/{env}/{command}.log'),
		qr|^logs/ping\.log$|,
		'implicit {env}/ removal preserved (no double slash)';
};

subtest 'expand: implicit {env}/ removal emits deprecation warning' => sub {
	plan tests => 2;
	reset_warnings();
	local $ENV{GENESIS_COMMAND} = 'ping';
	delete local $ENV{GENESIS_ENVIRONMENT};
	expand('logs/{env}/{command}.log');
	ok scalar(@WARNINGS) > 0,
		'deprecation warning emitted for implicit {env}/ removal';
	ok( (grep { /env.*deprecated|implicit.*env|use.*\{env\/\}/i } @WARNINGS),
		'warning suggests explicit form' )
		or diag "WARNINGS: ", join("\n  ", @WARNINGS);
};

# ---------- template_to_glob_pattern: new syntax with %concrete ----------

subtest 'glob: separator with concrete value' => sub {
	plan tests => 1;
	is glob_for('/tmp/genesis-{command}{-env}.log',
		command => 'deploy', env => 'staging'),
		'/tmp/genesis-deploy-staging.log',
		'concrete values emitted with seps';
};

subtest 'glob: separator with wildcard value (env unspecified)' => sub {
	plan tests => 1;
	is glob_for('/tmp/genesis-{command}{-env}.log'),
		'/tmp/genesis-*-*.log',
		'wildcard substitution preserves the separator literally';
};

subtest 'glob: explicit {env/} with concrete' => sub {
	plan tests => 1;
	is glob_for('/tmp/logs/{env/}{command}.log',
		env => 'staging', command => 'deploy'),
		'/tmp/logs/staging/deploy.log',
		'{env/} with concrete env emits "staging/"';
};

subtest 'glob: explicit {env/} with wildcard' => sub {
	plan tests => 1;
	is glob_for('/tmp/logs/{env/}{command}.log'),
		'/tmp/logs/*/*.log',
		'{env/} with wildcard env keeps the slash';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
