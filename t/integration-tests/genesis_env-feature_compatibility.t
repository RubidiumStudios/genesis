#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Output;
use Test::Exit;

use_ok 'Genesis::Config';
provide_rc();

use_ok 'Genesis::Env';
use_ok 'Genesis::Commands::Core';
use Genesis::Top;
use Genesis;
use JSON::PP qw/decode_json/;

# ---------------------------------------------------------------------------
# Test fixture: real Top with min_version baked in.  helper.pm's
# $Genesis::VERSION seed (999.999.999) ensures the running version
# satisfies whichever floor we declare, so no errors get raised.
# ---------------------------------------------------------------------------

sub mk_env_with_min {
	my ($repo_min, $env_min) = @_;
	my $top = make_top(name => 'fc-test', minimum_version => $repo_min, no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	my $env_min_yaml = defined($env_min)
		? "  min_version: $env_min\n"
		: '';
	put_file($top->path('fc-test.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: fc-test
$env_min_yaml
EOF
	return $top->load_env('fc-test');
}

# ---------------------------------------------------------------------------
# Env::effective_minimum_version + source - the canonical accessors
# ---------------------------------------------------------------------------
subtest 'effective_minimum_version - max(env_min, repo_min)' => sub {
	plan tests => 5;

	# repo > env -> repo wins
	my $env = mk_env_with_min('3.2.0-rc.1', '3.0.0');
	is($env->effective_minimum_version, '3.2.0-rc.1',
		'repo_min wins when greater than env_min');
	is($env->effective_minimum_version_source, 'repository',
		'source = repository when repo_min wins');

	# env > repo -> env wins
	$env = mk_env_with_min('3.0.0', '3.2.0-rc.1');
	is($env->effective_minimum_version, '3.2.0-rc.1',
		'env_min wins when greater than repo_min');
	is($env->effective_minimum_version_source, 'environment',
		'source = environment when env_min wins');

	# Only env declared
	$env = mk_env_with_min(undef, '3.1.0');
	is($env->effective_minimum_version, '3.1.0',
		'env_min governs alone when repo_min is absent');
};

# ---------------------------------------------------------------------------
# validate_genesis_version_requirements no longer errors on mismatch
# (regression: previously env_min < repo_min was a fatal error)
# ---------------------------------------------------------------------------
subtest 'validate does not error on env_min < repo_min when running satisfies both' => sub {
	plan tests => 3;
	my $env = mk_env_with_min('3.2.0-rc.1', '3.0.0');
	my $result = $env->validate_genesis_version_requirements;
	is(scalar(@{$result->{errors}}),   0, 'no errors when running >= both floors');
	is(scalar(@{$result->{warnings}}), 0, 'no warnings either - mismatch is debug-only');
	is($result->{effective_minimum}, '3.2.0-rc.1',
		'effective_minimum tracks the greater of env_min, repo_min');
};

# ---------------------------------------------------------------------------
# DeploymentManager captures feature_compatibility fields in audit record
# ---------------------------------------------------------------------------
subtest 'deployment audit record captures feature_compatibility' => sub {
	plan tests => 3;
	my $env = mk_env_with_min('3.2.0-rc.1', '3.0.0');

	# result='assumed' short-circuits past the kit/vault/bosh metadata
	# block, which needs live infrastructure we don't have in
	# integration tests.  The new feature_compatibility fields live in
	# the always-populated base section, so 'assumed' fully exercises
	# the contract.  The kit/vault/bosh path is covered (via mocks)
	# in t/unit-tests/genesis_env_deploymentmanager-core.t.
	my $dm   = $env->deployments;
	my $base = $dm->_base_deployment_content('deploy', 'assumed');

	is($base->{feature_compatibility},        '3.2.0-rc.1',
		'audit record carries effective_minimum_version');
	is($base->{feature_compatibility_source}, 'repository',
		'audit record carries source label');
	is($base->{genesis_version}, $Genesis::VERSION,
		'audit record still carries running genesis_version (unchanged contract)');
};

subtest 'audit record omits fc fields when no floor declared' => sub {
	plan tests => 2;
	my $env = mk_env_with_min(undef, undef);
	my $dm = $env->deployments;
	my $base = $dm->_base_deployment_content('deploy', 'assumed');
	ok(!exists $base->{feature_compatibility},
		'feature_compatibility absent when no floor declared');
	ok(!exists $base->{feature_compatibility_source},
		'feature_compatibility_source absent when no floor declared');
};

# ---------------------------------------------------------------------------
# Genesis::Commands::Core::_detect_feature_compatibility - needs real Top
# loaded from cwd, so this lives in the integration suite rather than the
# unit test for the renderer helpers.
# ---------------------------------------------------------------------------

# Run a coderef inside $top's root so Genesis::Top->new('.') picks it
# up.  Restores cwd via DESTROY-based scope guard so even
# Return::MultiLevel-driven unwinds (e.g. Test::Exit catching exit())
# don't leave cwd inside a tmpdir the harness can't rmtree at END.
{ package _CwdGuard;
  sub new { my ($c, $prev) = @_; bless { prev => $prev }, $c }
  sub DESTROY { chdir($_[0]->{prev}) }
}
sub in_repo (&$) {
	my ($code, $env) = @_;
	require Cwd;
	my $guard = _CwdGuard->new(Cwd::getcwd());
	chdir($env->top->path) or die "chdir failed: $!";
	return $code->();
}

subtest '_detect_feature_compatibility - returns (undef, undef) outside a repo' => sub {
	plan tests => 2;
	# Use a tmp dir that is not a Genesis repo.
	my $tmp = workdir();
	require Cwd;
	my $prev = Cwd::getcwd();
	chdir($tmp) or die "chdir failed: $!";
	my ($lvl, $src) = Genesis::Commands::Core::_detect_feature_compatibility();
	chdir($prev) or die "chdir back failed: $!";
	is($lvl, undef, 'level is undef outside a repo');
	is($src, undef, 'source is undef outside a repo');
};

subtest '_detect_feature_compatibility - no env arg, repo_min only' => sub {
	plan tests => 2;
	my $env = mk_env_with_min('3.2.0-rc.1', undef);
	my ($lvl, $src) = in_repo { Genesis::Commands::Core::_detect_feature_compatibility() } $env;
	is($lvl, '3.2.0-rc.1', 'level reflects repo_min');
	is($src, 'repository', 'source = repository');
};

subtest '_detect_feature_compatibility - no env arg, no repo_min - returns undef' => sub {
	plan tests => 2;
	my $env = mk_env_with_min(undef, '3.0.0');
	# Without an env_name, only repo_min counts; with no repo_min, the
	# detector returns (undef, undef).  The env_min is only consulted
	# when the caller passes an env name.
	my ($lvl, $src) = in_repo { Genesis::Commands::Core::_detect_feature_compatibility() } $env;
	is($lvl, undef, 'level undef when no env arg and no repo_min');
	is($src, undef, 'source undef when no env arg and no repo_min');
};

subtest '_detect_feature_compatibility - env arg, repo > env -> repo wins' => sub {
	plan tests => 2;
	my $env = mk_env_with_min('3.2.0-rc.1', '3.0.0');
	my ($lvl, $src) = in_repo { Genesis::Commands::Core::_detect_feature_compatibility('fc-test') } $env;
	is($lvl, '3.2.0-rc.1', 'level = max(repo, env)');
	is($src, 'repository', 'source = repository when repo wins');
};

subtest '_detect_feature_compatibility - env arg, env > repo -> env wins' => sub {
	plan tests => 2;
	my $env = mk_env_with_min('3.0.0', '3.2.0-rc.1');
	my ($lvl, $src) = in_repo { Genesis::Commands::Core::_detect_feature_compatibility('fc-test') } $env;
	is($lvl, '3.2.0-rc.1', 'level = max(repo, env)');
	is($src, 'environment', 'source = environment when env wins');
};

subtest '_detect_feature_compatibility - sentinel 0.0.0 returned as (undef, undef)' => sub {
	plan tests => 2;
	# Both sides absent -> effective_minimum_version returns 0.0.0,
	# which the detector translates into "no opt-in".
	my $env = mk_env_with_min(undef, undef);
	my ($lvl, $src) = in_repo { Genesis::Commands::Core::_detect_feature_compatibility('fc-test') } $env;
	is($lvl, undef, '0.0.0 sentinel maps to undef level');
	is($src, undef, '0.0.0 sentinel maps to undef source');
};

# ---------------------------------------------------------------------------
# Genesis::Commands::Core::version - full command via prepare_command +
# intercepted exit/output.  Exercises env-arg detection, field-selector
# validation, and JSON/simple-line output shapes with the new fields.
# ---------------------------------------------------------------------------

# Run the `version` command, returning (stdout, exit_code).
#
# Skips Genesis::Commands::prepare_command (which would require
# bin/genesis to have registered the command in %GENESIS_COMMANDS) and
# instead localises $COMMAND_OPTIONS directly.  The version sub uses
# get_options() (returns $COMMAND_OPTIONS) and its @_ as the argument
# vector.
#
# stdout_from MUST be the outer layer: Test::Exit uses Return::MultiLevel
# to unwind the stack out of exit_code, bypassing normal return flow.
# Capture::Tiny (used by stdout_from) sets up fd-level redirection
# that survives the unwind.
sub run_version {
	my %opts = ref($_[0]) eq 'HASH' ? %{shift()} : ();
	my @argv = @_;
	require Genesis::Commands;
	my $exit;
	local $Genesis::Commands::COMMAND_OPTIONS = \%opts;
	my $stdout = Test::Output::stdout_from(sub {
		$exit = Test::Exit::exit_code(sub {
			Genesis::Commands::Core::version(@argv);
		});
	});
	return ($stdout, $exit);
}

subtest 'version - simple line shows feature level tail when in repo' => sub {
	plan tests => 2;
	my $env = mk_env_with_min('3.2.0-rc.1', undef);
	my ($out, $exit) = in_repo { run_version() } $env;
	is($exit, 0, 'version exits 0');
	like($out, qr/feature level: v3\.2\.0-rc\.1 \[repository\]/,
		'simple-line tail names level and source');
};

subtest 'version <env> - tail reflects effective_minimum (env > repo wins)' => sub {
	plan tests => 1;
	my $env = mk_env_with_min('3.0.0', '3.2.0-rc.1');
	my ($out) = in_repo { run_version('fc-test') } $env;
	like($out, qr/feature level: v3\.2\.0-rc\.1 \[environment\]/,
		'env_min wins; source labelled environment');
};

subtest 'version --json - includes feature_compatibility fields when in repo' => sub {
	plan tests => 3;
	my $env = mk_env_with_min('3.2.0-rc.1', undef);
	my ($out) = in_repo { run_version({json => 1}) } $env;
	my $j = decode_json($out);
	is($j->{feature_compatibility},        '3.2.0-rc.1',
		'JSON includes feature_compatibility');
	is($j->{feature_compatibility_source}, 'repository',
		'JSON includes feature_compatibility_source');
	ok(exists $j->{semver},
		'JSON still includes existing fields like semver');
};

subtest 'version --json - omits fc fields when no floor declared' => sub {
	plan tests => 2;
	my $env = mk_env_with_min(undef, undef);
	my ($out) = in_repo { run_version({json => 1}) } $env;
	my $j = decode_json($out);
	ok(!exists $j->{feature_compatibility},
		'feature_compatibility omitted when no floor');
	ok(!exists $j->{feature_compatibility_source},
		'feature_compatibility_source omitted when no floor');
};

subtest 'version - field selector for feature_compatibility prints just the value' => sub {
	plan tests => 1;
	my $env = mk_env_with_min('3.2.0-rc.1', undef);
	my ($out) = in_repo { run_version('feature_compatibility') } $env;
	like($out, qr/^3\.2\.0-rc\.1$/m,
		'field-selector mode prints just the value on its own line');
};

subtest 'version <env> field-selector - env arg + field both honoured' => sub {
	plan tests => 1;
	my $env = mk_env_with_min('3.0.0', '3.2.0-rc.1');
	my ($out) = in_repo { run_version('fc-test', 'feature_compatibility_source') } $env;
	like($out, qr/^environment$/m,
		'first positional consumed as env arg, second as field selector');
};

done_testing;
