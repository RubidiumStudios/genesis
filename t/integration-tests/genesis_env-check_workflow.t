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
use Cwd qw/cwd abs_path/;
use Time::Piece;

# Initialize Genesis
use_ok 'Genesis::Config';
# Initialize $Genesis::RC for tests that consult global config
provide_rc();

use_ok 'Genesis::Env';
use Service::BOSH;
use Genesis::Top;
use Genesis::Env;
use Genesis;

# BOSH mock setup
local $ENV{BOSH_NON_INTERACTIVE} = 1;
local $ENV{GENESIS_BOSH_COMMAND};
write_bosh_config 'standalone';
my ($director1) = fake_bosh_directors(
    {alias => 'standalone'},
);
fake_bosh;

# Environment setup
$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

sub reset_exodus_data {
	my $env = shift;
	my $action = scalar(@_) % 2 ? shift : 'deploy';
	my %overrides = @_;

	note "-- resetting exodus data for ".$env->name;

	$action //= 'deploy';
	$env->vault->clear($env->exodus_base,1);

	# Write exodus data directly to vault (bypass update_deployment_exodus
	# which tries to extract manifest data for 'deploy' actions)
	$env->vault->query('set', $env->exodus_base,
		'deployer=test-user',
		'dated=2024-12-06 01:23:45 +0000',
		'completed=2024-12-06 11:23:58 +0000',
		'kit_name=dev',
		'kit_version=latest',
		'kit_is_dev=1',
	);

	# Write deployment audit entry directly to vault using 'state' field
	# which triggers the sanitize path in Deployment->new (fills defaults
	# for kit, user, manifest, etc.)
	my $timestamp = Time::Piece->new->strftime('%Y%m%d%H%M%S');
	my $state = ($action eq 'deploy') ? 'deployed' : 'terminated';
	my $reason = exists $overrides{reason} ? $overrides{reason} : 'test';
	my $deploy_path = $env->exodus_base.'/deployments/'.$timestamp;
	$env->vault->query('set', $deploy_path,
		"state=$state",
		"genesis_version=$Genesis::VERSION",
		"started=2024-12-06 01:23:45 +0000",
		"completed=2024-12-06 11:23:58 +0000",
		"timestamp=$timestamp",
		"sequence=1",
		"reason=$reason",
	);
	$env->vault->set($env->exodus_base, 'sequence', 1);

	# Set up deployment cache
	my $filemap = $env->deployment_cache_setup('preserve');
	mkfile_or_fail($filemap->{$_}, "Contents of $_ file")
		for (grep {! -f $filemap->{$_}} keys %$filemap);

	$env->deployments->reset;
	delete $env->{deployment_state};
}

sub reset_secrets {
    my ($env) = @_;
    note "-- resetting secrets for ".$env->name;
    # Clear the whole secrets base so add_secrets always sees a
    # deterministic pre-state; then seed the user-provided secret so
    # add_secrets doesn't try to prompt for it.
    quietly {
        $env->vault->clear($env->secrets_base, 1);
    };
    $env->{__secrets_plan} = undef;
    $env->{__secrets_store} = undef;
    $env->vault->set($env->secrets_base.'super_secrets','password', 'super-secret-password');
    quietly {$env->add_secrets()};
}

subtest 'genesis env check workflow' => sub {
    plan tests => 8;

    my $vault_target = vault_ok;
    Service::Vault->clear_all();

    # Align the repo's minimum_version with the env fixture's declared
    # min_version so validate_genesis_version_requirements has a single
    # floor to compare against.  Top->create otherwise auto-bakes the
    # current $Genesis::VERSION (which helper.pm seeds to 999.999.999),
    # and the version-validation subtest below would see a floor higher
    # than the running version it intentionally pins.
    my $top = Genesis::Top->create(workdir, 'check-test',
        vault => $VAULT_URL, minimum_version => '3.1.0-rc.20');
    cp_kit('t/src/simple', $top);
    put_file $top->path("check-test.yml"), <<'EOF';
---
kit:
  name:   dev
  version: latest
  features: []
  overrides:
    certificates:
      base:
        test_cert:
          ca:
            valid_for: 1h
          server:
            names:
            - test-server-cert
            valid_for: 1h
    credentials:
      base:
        test_cred:
          username: uuid
          password: random 40
    provided:
      base:
        super_secrets:
          type: generic
          keys:
            password:
              prompt: "Enter the super secret password"
              type: string

genesis:
  env: check-test
  bosh_env: standalone
  min_version: 3.1.0-rc.20
EOF

    put_file $top->path(".cloud.yml"), <<'EOF';
--- {}
# not really a cloud config, but close enough
EOF

    my $env;
    lives_ok {
        $env = $top->load_env('check-test')
    } "check-test environment loaded";

    # Configure env for testing
    $env->top->config->set('manifest_store','hybrid');
    $env->use_config($top->path(".cloud.yml"));
    $Genesis::VERSION = '3.1.0-rc.20';

    subtest 'check with secrets validation passes when all secrets present' => sub {
        plan tests => 3;

        # Ensure all required secrets are present in vault.
        reset_secrets($env);

        # Presence-only check: the fixture's valid_for: 1h certs would
        # otherwise fail the deep validity check on any test host whose
        # clock is far from generation time.  This subtest is about the
        # secrets-present branch of Env::check, not certificate liveness.
        local $ENV{GENESIS_TESTING_CHECK_SECRETS_PRESENCE_ONLY} = 1;

        my ($out, $err, $rv);
        lives_ok {
            ($out, $err) = output_from {
                $rv = $env->check(
                    check_secrets      => 1,
                    check_manifest     => 0,
                    check_releases     => 0,
                    check_release_sha1 => 0,
                    check_stemcells    => 0,
                );
            };
        } "check() does not die when secrets are valid";

        ok($rv, "check() returns true when all secrets are valid");
        like($err, qr/all secrets valid/i,
            "check output reports all-secrets-valid state");
    };

    subtest 'check detects missing secrets' => sub {
        plan tests => 3;

        reset_secrets($env);

        # Remove one secret from vault so check detects it missing
        quietly {
            $env->vault->clear($env->secrets_base.'super_secrets', 1);
        };

        my ($out, $err);
        lives_ok {
            ($out, $err) = output_from {
                not_ok(
                    $env->check(
                        check_secrets  => 1,
                        check_manifest => 0,
                        check_releases => 0,
                        check_release_sha1 => 0,
                        check_stemcells => 0,
                    ),
                    "check fails when secrets are missing"
                );
            };
        } "check() does not die when secrets are missing";

        like($err, qr/missing|error/i, "check output reports missing or error state");
    };

    subtest 'check with manifest validation' => sub {
        plan tests => 2;

        reset_secrets($env);

        my ($out, $err);
        lives_ok {
            ($out, $err) = output_from {
                $env->check(
                    check_secrets      => 0,
                    check_manifest     => 1,
                    check_releases     => 0,
                    check_release_sha1 => 0,
                    check_stemcells    => 0,
                );
            };
        } "check() with manifest validation does not die";

        like($err, qr/manifest|viability/i, "check output mentions manifest viability");
    };

    subtest 'validate_genesis_version_requirements' => sub {
        plan tests => 4;

        my $orig_version = $Genesis::VERSION;

        # Version meeting minimum requirement passes
        $Genesis::VERSION = '3.1.0-rc.20';
        my $result;
        lives_ok {
            $result = $env->validate_genesis_version_requirements;
        } "validate_genesis_version_requirements does not die with current version";
        ok(!scalar(@{$result->{errors}}), "no errors when running version meets minimum");

        # Version below minimum requirement fails
        $Genesis::VERSION = '2.0.0';
        lives_ok {
            $result = $env->validate_genesis_version_requirements;
        } "validate_genesis_version_requirements does not die with old version";
        ok(scalar(@{$result->{errors}}), "errors reported when running version is below minimum");

        # Restore version
        $Genesis::VERSION = $orig_version;
    };

    subtest 'check handles missing BOSH configs gracefully' => sub {
        plan tests => 2;

        reset_secrets($env);

        # Create a fresh env without cloud config registered
        my $top2 = Genesis::Top->create(workdir, 'check-noconfig-test', vault => $VAULT_URL);
        cp_kit('t/src/simple', $top2);
        put_file $top2->path("check-noconfig.yml"), <<'EOF';
---
kit:
  name:   dev
  version: latest
  features: []
genesis:
  env: check-noconfig
  bosh_env: standalone
  min_version: 3.1.0-rc.20
EOF

        my $env2;
        lives_ok {
            $env2 = $top2->load_env('check-noconfig');
        } "environment without cloud config loaded";

        $env2->top->config->set('manifest_store','hybrid');
        $Genesis::VERSION = '3.1.0-rc.20';

        # check() should not crash when configs are missing -- it warns instead
        my ($out, $err);
        lives_ok {
            ($out, $err) = output_from {
                $env2->check(
                    check_secrets      => 0,
                    check_manifest     => 1,
                    check_releases     => 0,
                    check_release_sha1 => 0,
                    check_stemcells    => 0,
                );
            };
        } "check() does not die when BOSH configs are missing";
    };

    subtest 'check_yamls option lists YAML files' => sub {
        # Regression test for the scalar-vs-arrayref bug in
        # _check_environment_viability: it used to assign the list
        # return of manifest_provider->kit_files() to a scalar,
        # capturing only the last element.  check(check_yamls => 1)
        # then handed that scalar to format_yaml_files, which does
        # ->@* on its kit_files opt and crashed.
        plan tests => 4;

        reset_secrets($env);
        local $ENV{GENESIS_TESTING_CHECK_SECRETS_PRESENCE_ONLY} = 1;

        # The kit's blueprint hook requires a cpi config (in addition
        # to the cloud config already registered above); without it,
        # check_yamls skips the listing branch and prints "Required
        # BOSH configs not provided" instead.  Provide a stub so the
        # listing branch runs.
        put_file $top->path(".cpi.yml"), <<'EOF';
--- {}
EOF
        $env->use_config($top->path(".cpi.yml"), 'cpi');

        my ($out, $err);
        lives_ok {
            ($out, $err) = output_from {
                $env->check(
                    check_secrets      => 1,
                    check_manifest     => 0,
                    check_releases     => 0,
                    check_release_sha1 => 0,
                    check_stemcells    => 0,
                    check_yamls        => 1,
                );
            };
        } "check(check_yamls => 1) does not die";

        like($err, qr/inspecting YAML files used to build manifest/,
            "check_yamls announces YAML inspection");
        like($err, qr/\.ya?ml\b/,
            "check_yamls lists at least one .yml/.yaml file");
        unlike($err, qr/Can't call method "\@\*" on/,
            "no scalar-vs-arrayref crash in format_yaml_files");
    };
};

teardown_vault;
done_testing;
