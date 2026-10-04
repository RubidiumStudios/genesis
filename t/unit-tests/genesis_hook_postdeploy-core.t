#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Output;
use Genesis qw(bail);
use Cwd qw(abs_path);

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# ---------------------------------------------------------------------------
# Load the module under test
# ---------------------------------------------------------------------------
require_ok 'Genesis::Hook::PostDeploy';

# ---------------------------------------------------------------------------
# Test subclass - class name matches Genesis::Hook::<Type>::<KitName>
# convention required by label() in the base class.
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::PostDeploy::test_kit;
	use parent -norequire, 'Genesis::Hook::PostDeploy';

	sub perform {
		my ($self) = @_;
		$self->done(1);
	}
}

# ---------------------------------------------------------------------------
# Shared mock objects
# ---------------------------------------------------------------------------

my $test_seq = 0;

my $kit = mock "Genesis::Kit" => {
	name                => 'test-kit',
	version             => '1.0.0',
	genesis_version_min => '3.1.0-rc.10',
	id                  => sub { return $_[0]->name . '/' . $_[0]->version },
	kit_bug => sub {
		my ($self, $msg, @args) = @_;
		bail("Throwing a kit bug: " . $msg, @args);
	},
	path => sub {
		my ($self, $file) = @_;
		return "/mock/kit/path/$file";
	},
	metadata => { supports => ['aws', 'vsphere', 'openstack'] },
	get_hook_module => sub { return undef },
};

my $bosh = mock "Genesis::BOSH" => {
	alias                => 'mock-bosh',
	connect_and_validate => sub { return $_[0] },
};

sub mock_env {
	$test_seq++;
	my $seq = $test_seq;
	mock "Genesis::Env" => {(
		name            => "test-env-$seq",
		type            => 'test',
		kit             => $kit,
		bosh            => sub {
			my $self = shift;
			return $bosh;
		},
		use_create_env  => 0,
		features        => Mock::ReferencedValue->new(['ha', 'tls']),
		iaas            => 'aws',
		scale           => 'dev',
		is_ocfp         => 0,
		cpi_name        => 'aws_cpi',
		cpi_enabled     => 1,
		deployments     => mock("Genesis::Env::Deployments::$seq" => {
			current_state => 'deployed',
		}),
		workpath => sub {
			my ($self, $path) = @_;
			return "/tmp/genesis-test-work/$path";
		},
		exodus_lookup => sub {
			my ($self, $key, $default) = @_;
			return { director_url => 'https://bosh.example.com', admin_user => 'admin' }
				if $key eq '.';
			return $default;
		},
		lookup => sub {
			my ($self, $key, $default) = @_;
			return $default;
		},
		path => sub { return "/mock/env/path/$_[1]" },
		file => 'test-env.yml',
	), @_};
}

# Convenience: instantiate the test subclass with minimal required args
sub make_hook {
	my %args = (
		env => mock_env(),
		rc  => 0,
		@_,
	);
	return Genesis::Hook::PostDeploy::test_kit->init(%args);
}

# ---------------------------------------------------------------------------
# Globals set before all subtests
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{GENESIS_KIT_HOOK} = 'post-deploy';
$ENV{GENESIS_CALL_ENV} = 'genesis test-env';

# ---------------------------------------------------------------------------
# Module loads
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::PostDeploy module loads' => sub {
	plan tests => 1;
	ok(defined(&Genesis::Hook::PostDeploy::init),
		'Genesis::Hook::PostDeploy::init is defined');
};

# ---------------------------------------------------------------------------
# init - required arguments
# ---------------------------------------------------------------------------
subtest 'init - dies when env is missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::PostDeploy::test_kit->init(rc => 0)
	} qr/Missing required arguments for a perl-based kit hook call:.*env/,
		'init() without env dies with required-args message';
};

subtest 'init - dies when rc is missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::PostDeploy::test_kit->init(env => mock_env())
	} qr/Missing required arguments for a perl-based kit hook call:.*rc/,
		'init() without rc dies with required-args message';
};

subtest 'init - dies when both env and rc are missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::PostDeploy::test_kit->init()
	} qr/Missing required arguments for a perl-based kit hook call:/,
		'init() with no arguments dies with required-args message';
};

# ---------------------------------------------------------------------------
# init - valid construction
# ---------------------------------------------------------------------------
subtest 'init - returns blessed object with rc=0' => sub {
	plan tests => 6;

	my $env = mock_env();
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::PostDeploy::test_kit->init(env => $env, rc => 0)
	} 'init() with env and rc=0 succeeds';

	ok(defined $hook, 'init() returns a defined value');
	isa_ok($hook, 'Genesis::Hook::PostDeploy',
		'returned object isa Genesis::Hook::PostDeploy');
	isa_ok($hook, 'Genesis::Hook',
		'returned object isa Genesis::Hook');
	is($hook->env, $env,
		'env() returns the env passed to init()');
	is($hook->{rc}, 0,
		'rc stored on object as 0');
};

subtest 'init - returns blessed object with rc=1' => sub {
	plan tests => 3;

	my $hook;
	lives_ok {
		$hook = Genesis::Hook::PostDeploy::test_kit->init(
			env => mock_env(),
			rc  => 1,
		)
	} 'init() with rc=1 succeeds';

	ok(defined $hook, 'init() returns a defined value');
	is($hook->{rc}, 1, 'rc stored on object as 1');
};

subtest 'init - complete flag starts at 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{complete}, 0, 'complete flag initializes to 0');
};

subtest 'init - type set from GENESIS_KIT_HOOK env var' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{type}, 'post-deploy',
		'type reflects GENESIS_KIT_HOOK=post-deploy');
};

subtest 'init - stores extra opts on object' => sub {
	plan tests => 2;

	my $hook = Genesis::Hook::PostDeploy::test_kit->init(
		env        => mock_env(),
		rc         => 0,
		interactive => 1,
		purpose    => 'test-purpose',
	);
	is($hook->{interactive}, 1,              'extra opt "interactive" stored on hook');
	is($hook->{purpose},     'test-purpose', 'extra opt "purpose" stored on hook');
};

# ---------------------------------------------------------------------------
# deploy_successful
# ---------------------------------------------------------------------------
subtest 'deploy_successful - returns true when rc is 0' => sub {
	plan tests => 1;

	my $hook = make_hook(rc => 0);
	ok($hook->deploy_successful,
		'deploy_successful() returns true when rc=0');
};

subtest 'deploy_successful - returns false when rc is 1' => sub {
	plan tests => 1;

	my $hook = make_hook(rc => 1);
	ok(!$hook->deploy_successful,
		'deploy_successful() returns false when rc=1');
};

subtest 'deploy_successful - returns false when rc is 255' => sub {
	plan tests => 1;

	my $hook = make_hook(rc => 255);
	ok(!$hook->deploy_successful,
		'deploy_successful() returns false when rc=255');
};

subtest 'deploy_successful - returns false for any non-zero rc' => sub {
	plan tests => 3;

	for my $rc (2, 127, 128) {
		my $hook = make_hook(rc => $rc);
		ok(!$hook->deploy_successful,
			"deploy_successful() returns false when rc=$rc");
	}
};

subtest 'deploy_successful - distinguishes rc=0 from rc=1 on same hook' => sub {
	plan tests => 2;

	my $success = make_hook(rc => 0);
	my $failure = make_hook(rc => 1);

	ok( $success->deploy_successful, 'rc=0 hook: deploy_successful is true');
	ok(!$failure->deploy_successful, 'rc=1 hook: deploy_successful is false');
};

# ---------------------------------------------------------------------------
# data
# ---------------------------------------------------------------------------
subtest 'data - returns a hash reference' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $data = $hook->data;
	ok(ref($data) eq 'HASH', 'data() returns a hash reference');
};

subtest 'data - returns empty hash on first call' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $data = $hook->data;
	is(scalar keys %$data, 0, 'data() returns empty hash on first call');
};

subtest 'data - returns the same reference on subsequent calls' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $first  = $hook->data;
	my $second = $hook->data;

	is(ref($first),  'HASH', 'first call returns hash reference');
	is($first, $second, 'second call returns the same reference as first');
};

subtest 'data - mutations are visible across calls' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $data = $hook->data;
	$data->{custom_key} = 'custom_value';

	my $again = $hook->data;
	is($again->{custom_key}, 'custom_value',
		'mutation on first ref visible through second call');
	is(scalar keys %{$hook->data}, 1,
		'data hash has exactly one key after one mutation');
};

subtest 'data - each new hook instance has its own hash' => sub {
	plan tests => 2;

	my $hook_a = make_hook();
	my $hook_b = make_hook();

	$hook_a->data->{x} = 1;

	is($hook_a->data->{x}, 1, 'hook_a data has key x');
	ok(!exists $hook_b->data->{x}, 'hook_b data does not have key x');
};

# ---------------------------------------------------------------------------
# command
# ---------------------------------------------------------------------------
subtest 'command - simple args joined with spaces' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $cmd = $hook->command('do', 'test');
	is($cmd, 'genesis test-env do test',
		'command() joins GENESIS_CALL_ENV and simple args with spaces');
};

subtest 'command - no args returns just the call env' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $cmd = $hook->command();
	is($cmd, 'genesis test-env',
		'command() with no args returns GENESIS_CALL_ENV alone');
};

subtest 'command - multiple args all joined' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $cmd = $hook->command('do', 'upload-stemcells');
	is($cmd, 'genesis test-env do upload-stemcells',
		'command() with two args returns full joined string');
};

subtest 'command - uses GENESIS_CALL_ENV over GENESIS_CALL' => sub {
	plan tests => 1;

	local $ENV{GENESIS_CALL_ENV} = 'genesis my-env';
	local $ENV{GENESIS_CALL}     = 'genesis other';

	my $hook = make_hook();
	my $cmd = $hook->command('action');
	is($cmd, 'genesis my-env action',
		'command() prefers GENESIS_CALL_ENV when both env vars are set');
};

subtest 'command - falls back to GENESIS_CALL when GENESIS_CALL_ENV is unset' => sub {
	plan tests => 1;

	local $ENV{GENESIS_CALL_ENV} = undef;
	local $ENV{GENESIS_CALL}     = 'genesis fallback-env';

	my $hook = make_hook();
	my $cmd = $hook->command('do', 'something');
	is($cmd, 'genesis fallback-env do something',
		'command() falls back to GENESIS_CALL when GENESIS_CALL_ENV is unset');
};

subtest 'command - args without special chars are not quoted' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $cmd = $hook->command('deploy', '--dry-run');
	is($cmd, 'genesis test-env deploy --dry-run',
		'command() does not quote plain args');
};

subtest 'command - arg containing the quoting trigger sequence is quoted' => sub {
	plan tests => 1;

	# The regex in command() is / \(\)!\*\?/ -- a literal string match.
	# Only an arg containing exactly that sequence (space, (, ), !, *, ?)
	# will be wrapped in single quotes.
	#
	# NOTE: command() modifies its @_ aliases in place, so $trigger_arg is
	# mutated after the call.  Build the expected string before calling.
	my $hook = make_hook();
	my $raw_arg  = 'x ()!*?';
	my $expected = "genesis test-env '$raw_arg'";
	my $cmd = $hook->command($raw_arg);
	is($cmd, $expected,
		'command() single-quotes arg that matches the special-char trigger sequence');
};

# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------
subtest 'results - returns 1 unconditionally' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->results, 1,
		'results() returns 1 unconditionally');
};

subtest 'results - returns 1 regardless of rc' => sub {
	plan tests => 2;

	my $success = make_hook(rc => 0);
	my $failure = make_hook(rc => 1);

	is($success->results, 1, 'results() returns 1 when rc=0');
	is($failure->results, 1, 'results() returns 1 when rc=1');
};

# ---------------------------------------------------------------------------
# Heavy methods exist as can() checks
# ---------------------------------------------------------------------------
subtest 'update_director_network_config - method exists' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok($hook->can('update_director_network_config'),
		'hook can() update_director_network_config');
};

subtest 'upload_stemcells - method exists' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok($hook->can('upload_stemcells'),
		'hook can() upload_stemcells');
};

subtest 'upload_runtime_configs - method exists' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok($hook->can('upload_runtime_configs'),
		'hook can() upload_runtime_configs');
};

# Per-config value validation.  bosh-configs.runtime.<name> must accept
# a hash (options), a JSON boolean true (enable with defaults), OR a
# JSON boolean false (explicitly disable).  Explicit-false was
# previously rejected, which broke user expectations: the only way to
# turn off a single runtime config was to omit its key entirely, and
# users configuring via defaults + per-env overrides had no way to
# disable a config that a shared default turned on.
subtest 'upload_runtime_configs - accepts per-config false to disable' => sub {
	plan tests => 4;

	my @hook_calls;
	my $env = mock_env(
		lookup => sub {
			my ($self, $key, $default) = @_;
			return { blacksmith => JSON::PP::false, dns => JSON::PP::true }
				if $key eq 'bosh-configs.runtime';
			return $default;
		},
		has_hook => sub { $_[1] eq 'runtime-config' ? 1 : 0 },
		notify   => sub { 1 },
		kit      => $kit,
		run_hook => sub {
			my ($self, $hook, %opts) = @_;
			push @hook_calls, { hook => $hook, args => $opts{args} };
			return ('', 0, '');
		},
	);
	my $hook = Genesis::Hook::PostDeploy::test_kit->init(env => $env, rc => 0);

	my ($out, $err) = output_from { eval { $hook->upload_runtime_configs } };
	is $@, '', 'no bail when a per-config value is false';
	like $err, qr/done/, 'reports completion on stderr';
	is $out, '', 'nothing on stdout';
	is_deeply $hook_calls[0]{args},
		{ blacksmith => JSON::PP::false, dns => JSON::PP::true },
		'runtime-config hook receives the full opts hash including false values';
};

subtest 'upload_runtime_configs - still bails on plain-string per-config value' => sub {
	plan tests => 1;

	my $env = mock_env(
		lookup => sub {
			my ($self, $key, $default) = @_;
			return { blacksmith => 'yes' } if $key eq 'bosh-configs.runtime';
			return $default;
		},
		has_hook => sub { $_[1] eq 'runtime-config' ? 1 : 0 },
		notify   => sub { 1 },
		kit      => $kit,
	);
	my $hook = Genesis::Hook::PostDeploy::test_kit->init(env => $env, rc => 0);

	eval { $hook->upload_runtime_configs };
	like $@, qr/hash reference or boolean/i,
		'string value still rejected; error mentions boolean as accepted type';
};

subtest 'upload_director_cpi_config - method exists' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok($hook->can('upload_director_cpi_config'),
		'hook can() upload_director_cpi_config');
};

subtest 'upload_director_cpi_config - delegates to env' => sub {
	plan tests => 3;

	# Build an env mock whose upload_director_cpi_config captures the call
	# and returns a sentinel. The hook's method should pass through opts
	# verbatim and return whatever the env returned.
	my @env_calls;
	my $env = mock_env(
		upload_director_cpi_config => sub {
			my ($self, %opts) = @_;
			push @env_calls, \%opts;
			return 'sentinel-return-value';
		},
	);
	my $hook = Genesis::Hook::PostDeploy::test_kit->init(env => $env, rc => 0);

	my $ret = $hook->upload_director_cpi_config(credhub_prefix => '/x/');

	is $ret, 'sentinel-return-value',
		'hook returns whatever env->upload_director_cpi_config returned';
	is scalar(@env_calls), 1,
		'env->upload_director_cpi_config was called exactly once';
	is_deeply $env_calls[0], { credhub_prefix => '/x/' },
		'opts passed through verbatim';
};

subtest '_commit_config_credhub_secrets - method exists' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok($hook->can('_commit_config_credhub_secrets'),
		'hook can() _commit_config_credhub_secrets');
};

subtest 'upload_stemcells - returns immediately without action when rc is non-zero' => sub {
	plan tests => 1;

	# When deploy_successful is false, upload_stemcells must return early.
	# We verify this by ensuring no BOSH call is attempted (the mock env has
	# no get_target_bosh, so any BOSH access would die).
	my $hook = make_hook(rc => 1);
	my $ret;
	lives_ok {
		$ret = $hook->upload_stemcells
	} 'upload_stemcells() with rc=1 returns early without BOSH access';
};

# ---------------------------------------------------------------------------
# update_director_network_config - the network claims lock
# ---------------------------------------------------------------------------
# The director's own cloud config is built from the claims every deployment on
# that director has recorded, and the step rewrites the director's network
# record.  It holds the director's network claims lock while it does, so a
# deploy on the same director can't record claims that the rewrite then
# erases.  When another process holds the lock, the step waits for it, and if
# the wait runs out, or the lock is stale, it fails only this step.

my @netcalls; # director, hook, and vault calls, in order
my $net_seq = 0;

# net_bosh - a director mock whose lock answers come from @$states in turn
# (the last one repeats), or from its own state once this process takes it
sub net_bosh {
	my (%o) = @_;
	my $alias  = $o{alias} // 'lab-ocf';
	my @states = @{$o{states} // [{status => 'unlocked'}]};
	my $mine   = 0;
	$net_seq++;
	return mock "Mock::PostDeploy::NetBosh$net_seq" => {
		alias => $alias,
		check_network_lock => sub {
			push @netcalls, ['check_network_lock', $alias];
			return {status => 'locked', description => 'just now by this process'} if $mine;
			return @states > 1 ? shift(@states) : $states[0];
		},
		acquire_network_lock => sub { push @netcalls, ['acquire_network_lock', $alias]; $mine = 1 },
		network_locked_by_me => sub { $mine },
		clear_network_lock   => sub { push @netcalls, ['clear_network_lock', $alias]; $mine = 0; 1 },
		upload_config => sub {
			my ($self, $content, $type, $name) = @_;
			push @netcalls, ['upload_config', $alias, $type, $name];
			die "director refused the cloud config\n" if $o{fail_upload};
			return 1;
		},
	};
}

sub net_env {
	my (%o) = @_;
	my $self_bosh   = $o{self_bosh};
	my $create_env  = $o{create_env} ? 1 : 0;
	$net_seq++;
	my $vault = mock "Mock::PostDeploy::NetVault$net_seq" => {
		set_path => sub {
			my ($self, @args) = @_;
			push @netcalls, ['set_path', @args];
			die "vault sealed\n" if $o{fail_set_path};
			return 1;
		},
	};
	return mock_env(
		name                    => 'lab-ocf',
		type                    => 'bosh',
		use_create_env          => $create_env,
		can_build_cloud_configs => 1,
		notify                  => sub { 1 },
		exodus_base             => 'secret/exodus/lab-ocf/bosh',
		vault                   => $vault,
		get_call_path_with_env  => sub { wantarray ? ('genesis', 'lab-ocf') : 'genesis lab-ocf' },
		get_target_bosh => sub {
			my ($self, $opts) = @_;
			push @netcalls, ['get_target_bosh', $opts->{self} ? 'self' : 'default'];
			# create-env directors answer for themselves with no option
			return ($opts->{self} || $create_env) ? $self_bosh : die "the parent director was asked for\n";
		},
		run_hook => sub {
			my ($self, $hook, %opts) = @_;
			push @netcalls, ['run_hook', $hook, $opts{purpose} // ''];
			die "the director cloud-config hook failed\n" if $o{fail_hook};
			return ("director: yes\n", {subnets => {'ocfp-2' => {claims => {}}}});
		},
	);
}

sub netcall {
	my (@want) = @_;
	CALL: for my $i (0..$#netcalls) {
		for my $j (0..$#want) {
			next CALL unless defined($netcalls[$i][$j]) && $netcalls[$i][$j] eq $want[$j];
		}
		return $i;
	}
	return undef;
}

subtest 'update_director_network_config - takes the lock before the hook and releases it after the exodus write' => sub {
	plan tests => 6;
	@netcalls = ();
	my $bosh = net_bosh();
	my $hook = make_hook(env => net_env(self_bosh => $bosh));
	my $ret;
	output_from { $ret = $hook->update_director_network_config };
	my $acquire = netcall('acquire_network_lock', 'lab-ocf');
	my $build   = netcall('run_hook', 'cloud-config', 'director');
	my $write   = netcall('set_path', 'secret/exodus/lab-ocf/bosh/network');
	my $release = netcall('clear_network_lock', 'lab-ocf');
	ok(defined $acquire && defined $build && $acquire < $build, 'the lock is taken before the hook runs')
		or diag explain \@netcalls;
	ok(defined $write && defined $acquire && $acquire < $write, 'and before the exodus write');
	ok(defined $release && $release > $write, 'and released after the exodus write');
	ok(defined(netcall('upload_config', 'lab-ocf', 'cloud', 'lab-ocf.bosh.director')), 'the director config is uploaded');
	ok(!$bosh->network_locked_by_me, 'no lock of ours is left');
	is($ret, 1, 'the step reports success');
};

subtest 'update_director_network_config - waits for a lock that another process releases' => sub {
	plan tests => 5;
	no warnings 'once';
	local $Genesis::Hook::PostDeploy::NETWORK_LOCK_POLL_SECONDS = 1;
	local $ENV{GENESIS_NETWORK_LOCK_WAIT} = 30;
	@netcalls = ();
	my $held = {status => 'locked', description => 'about 1 minute ago by ubuntu@bastion (env: cf, pid: 4242)'};
	my $bosh = net_bosh(states => [$held, $held, {status => 'unlocked'}]);
	my $hook = make_hook(env => net_env(self_bosh => $bosh));
	my ($ret, $out, $err);
	($out, $err) = output_from { $ret = $hook->update_director_network_config };
	is(scalar(grep { $_->[0] eq 'check_network_lock' } @netcalls[0..(netcall('acquire_network_lock') // 0)]), 3,
		'the lock is checked until the third check finds it free');
	my $all = ($out.$err) =~ s/\s+/ /gr;
	like($all, qr/held about 1 minute ago by ubuntu\@bastion \(env: cf, pid: 4242\); waiting up to 30 seconds/, 'the wait names the holder and the limit');
	is(scalar(() = $all =~ /waiting up to/g), 1, 'and is announced once');
	ok(defined(netcall('set_path')), 'the step then completes');
	is($ret, 1, 'and reports success');
};

subtest 'update_director_network_config - fails only this step when the wait runs out' => sub {
	plan tests => 8;
	no warnings 'once';
	local $Genesis::Hook::PostDeploy::NETWORK_LOCK_POLL_SECONDS = 1;
	local $ENV{GENESIS_NETWORK_LOCK_WAIT} = 2;
	@netcalls = ();
	my $held = {status => 'locked', description => 'about 3 minutes ago by ubuntu@bastion (env: cf, pid: 4242)'};
	my $bosh = net_bosh(states => [$held]);
	my $hook = make_hook(env => net_env(self_bosh => $bosh));
	my ($ret, $out, $err);
	lives_ok { ($out, $err) = output_from { $ret = $hook->update_director_network_config } } 'the step does not bail';
	my $all = ($out.$err) =~ s/\s+/ /gr; # the error is wrapped to the terminal
	is($ret, 0, 'it returns 0, so only this step fails');
	ok(!defined(netcall('run_hook')), 'no hook runs');
	ok(!defined(netcall('upload_config')), 'nothing is uploaded');
	ok(!grep({ $_->[0] =~ /^(acquire|clear)_network_lock$/ } @netcalls), 'the other process\'s lock is left untouched');
	like($all, qr/held about 3 minutes ago by ubuntu\@bastion \(env: cf, pid: 4242\)/, 'the error names the holder');
	like($all, qr/genesis lab-ocf bosh-configs upload --type cloud --name lab-ocf\.bosh\.director -y/,
		'and gives the exact command that finishes the step');
	like($all, qr/deployed and is working, but its own cloud config lab-ocf\.bosh\.director and its network record in exodus were not updated/,
		'and says the director deployed but its network record was not updated');
};

subtest 'update_director_network_config - fails at once on a stale lock and leaves it in place' => sub {
	plan tests => 5;
	no warnings 'once';
	local $Genesis::Hook::PostDeploy::NETWORK_LOCK_POLL_SECONDS = 1;
	local $ENV{GENESIS_NETWORK_LOCK_WAIT} = 30;
	@netcalls = ();
	my $stale = {status => 'stale', description => 'about 2 hours ago by ubuntu@bastion (env: cf, pid: 4242)'};
	my $bosh = net_bosh(states => [$stale]);
	my $hook = make_hook(env => net_env(self_bosh => $bosh));
	my ($ret, $out, $err);
	my $start = time;
	($out, $err) = output_from { $ret = $hook->update_director_network_config };
	is($ret, 0, 'the step fails');
	ok(time - $start < 5, 'without waiting');
	ok(!grep({ $_->[0] =~ /^(acquire|clear)_network_lock$/ } @netcalls), 'the stale lock is not cleared');
	my $all = ($out.$err) =~ s/\s+/ /gr; # the error is wrapped to the terminal
	like($all, qr/stale: it was taken about 2 hours ago by ubuntu\@bastion/, 'the error names the stale holder');
	like($all, qr/genesis lab-ocf bosh-configs upload --type cloud --name lab-ocf\.bosh\.director -y/, 'and gives the command that finishes the step');
};

subtest 'update_director_network_config - releases the lock when a step inside it fails' => sub {
	plan tests => 9;
	my %cases = (
		'a failed upload'       => {fail_upload   => 1, error => qr/director refused the cloud config/},
		'a failed exodus write' => {fail_set_path => 1, error => qr/vault sealed/},
		'a failed hook'         => {fail_hook     => 1, error => qr/the director cloud-config hook failed/},
	);
	for my $case (sort keys %cases) {
		my $c = $cases{$case};
		@netcalls = ();
		my $bosh = net_bosh(fail_upload => $c->{fail_upload});
		my $hook = make_hook(env => net_env(self_bosh => $bosh, fail_set_path => $c->{fail_set_path}, fail_hook => $c->{fail_hook}));
		throws_ok { output_from { $hook->update_director_network_config } } $c->{error}, "$case is reported";
		ok(defined(netcall('clear_network_lock', 'lab-ocf')), "$case: the lock is released");
		ok(!$bosh->network_locked_by_me, "$case: no lock of ours is left");
	}
};

subtest 'update_director_network_config - releases the lock on a signal' => sub {
	plan tests => 4;
	@netcalls = ();
	my $sent = 0;
	my $base_bosh = net_bosh();
	# Delivers TERM to ourselves while the lock is held, which is the only way
	# to exercise the handler the step installs
	my $signal_bosh = mock "Mock::PostDeploy::SignalBosh" => {
		alias                => 'lab-ocf',
		check_network_lock   => sub { $base_bosh->check_network_lock },
		acquire_network_lock => sub { $base_bosh->acquire_network_lock },
		network_locked_by_me => sub { $base_bosh->network_locked_by_me },
		clear_network_lock   => sub { $base_bosh->clear_network_lock },
		upload_config        => sub { $sent++; kill TERM => $$; return 1 },
	};
	my $hook = make_hook(env => net_env(self_bosh => $signal_bosh));
	throws_ok { output_from { $hook->update_director_network_config } } qr/Terminated/, 'TERM stops the step';
	is($sent, 1, 'it arrived while the lock was held');
	ok(defined(netcall('clear_network_lock', 'lab-ocf')), 'the lock is released on the way out');
	ok(!$base_bosh->network_locked_by_me, 'no lock of ours is left');
};

subtest 'update_director_network_config - a create-env director locks itself' => sub {
	plan tests => 3;
	@netcalls = ();
	my $bosh = net_bosh();
	my $hook = make_hook(env => net_env(self_bosh => $bosh, create_env => 1));
	output_from { $hook->update_director_network_config };
	ok(defined(netcall('get_target_bosh', 'default')), 'the director is resolved without --self, as create-env requires');
	ok(defined(netcall('acquire_network_lock', 'lab-ocf')), 'the lock is taken on the director itself');
	ok(defined(netcall('clear_network_lock', 'lab-ocf')), 'and released there');
};

done_testing;
