#!perl
use strict;
use warnings;
use utf8;

# CLI/UX surface for `genesis deploy`: exercises the user-visible flow
# through Genesis::Env::deploy (orchestration, notice text, exit codes,
# reaction handling).  Genesis::Env API-level behaviour belongs in
# genesis_env-*.t; this file is for the presentation/orchestration
# contract.

use lib 'lib';
use lib 't';
use helper;
use Test::Exception;
use Test::Deep;
use Test::Exit;
use Test::More;
use Test::Output;
use Test::Differences;
use Cwd qw/cwd abs_path/;
use File::Path qw/rmtree/;

# File-level plan: 3 use_ok/require_ok + 2 subtests = 5.
plan tests => 5;

use_ok 'Genesis::Config';
provide_rc();

use_ok 'Genesis::Env';
use Service::BOSH;
use Genesis::Top;
use Genesis::Env;
use Genesis;
use Genesis::Commands;
use Genesis::Commands::Env;     # define_command resolves the sub ref
                                 # lazily; tests call it directly so the
                                 # package must already be loaded.

# Register all command definitions so `prepare_command('deploy', ...)`
# can look up the deploy command spec.  bin/genesis guards its main()
# with `unless caller`, so this only loads the command registry.
require_ok './bin/genesis';

fake_bosh;

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS}=80;

subtest 'pre and post deploy reactions' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
  local $ENV{GENESIS_VERSION} = '3.0.0';
  local $Genesis::VERSION = '3.0.0';
	local $ENV{NOCOLOR} = "yes";
	# Fake bosh that succeeds on `deploy` but emits a valid empty-JSON
	# stub for `--json` queries (`bosh configs --json`, etc.), so the
	# deploy flow's incidental JSON parses don't choke when the bare
	# success line would otherwise be fed into load_json.
	fake_bosh(<<'EOF');
	if [[ " $* " == *" --json "* || " $* " == *" --json"* ]] ; then
		echo '{}'
	else
		echo 'BOSH Deploy ran successfully'
	fi
	exit 0
EOF

	my ($director1) = fake_bosh_directors(
		{alias => 'reactions'},
	);

	my $vault_target = vault_ok;
	Service::Vault->clear_all();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL);
	# Instead of linking, copy the reactions kit so it can be modified as needed
	`cp -a t/src/reactions ${\($top->path('dev'))}`;

  pushd $top->path;
	# Common cloud config
	put_file $top->path(".cloud.yml"), <<EOF;
--- {}
# not really a cloud config, but close enough
EOF


	mkdir_or_fail $top->path('bin');
	put_file $top->path("bin/pass-script.sh"), 0755, <<'EOF';
echo >&2 'This script passed'
i=0
if [[ $# -gt 0 ]] ; then
  for a in "$@" ; do
    echo >&2 "Argument $((++i)): '$a'"
  done
fi
exit 0
EOF
	put_file $top->path("bin/fail-script.sh"), 0755, <<EOF;
echo >&2 'This script failed'
exit 1
EOF

	#  Test failed predeploy:
	put_file $top->path("predeploy-reaction-fail.yml"), <<EOF;
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env:  predeploy-reaction-fail
  bosh_env: reactions
  reactions:
    pre:
    - addon: working-addon
      args: [ 'this', 'that' ]
    - script: fail-script.sh
    post:
    - script: pass-script.sh

EOF
	my $env = $top->load_env('predeploy-reaction-fail');
	$env->use_config($top->path(".cloud.yml"));

	{
		no Carp::Always;
		my ($stdout,$stderr,$err) = (
			output_from {
				dies_ok {$env->deploy()} 'deploy exits when invalid reactions defined'
			},
			$@
		);
		eq_or_diff($err, <<EOF, "deploy error should specify incorrect reactions");

[FATAL] Unexpected reactions specified under genesis.reactions: post, pre
        Valid values: pre-deploy, post-deploy

EOF
	}
	put_file $top->path("predeploy-reaction-fail.yml"), <<EOF;
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env:  predeploy-reaction-fail
  bosh_env: reactions
  reactions:
    pre-deploy:
    - addon: working-addon
      args: [ 'this', 'that' ]
    - script: fail-script.sh
EOF
	$env = $top->load_env('predeploy-reaction-fail');
	$env->use_config($top->path(".cloud.yml"));

	run('rm "'. $env->kit->path('hooks/addon') . '"');
	{
		no Carp::Always;
		my ($stdout,$stderr,$err) = (
			output_from {
				dies_ok {$env->deploy()} "deploy exits when specified addon hook doesn't exist"
			},
			$@
		);
		# The kit's hooks/addon file was rm'd above, but Genesis still has
		# a module-level addon fallback (@Genesis::Hook::Addon) for
		# help/list/blank scripts, so has_hook('addon') stays true and the
		# bail fires one layer deeper -- in Kit::run_hook, naming the
		# specific script that wasn't found.
		eq_or_diff($err, <<EOF, "deploy error should specify incorrect reactions");

[FATAL] Could not find addon hook for 'working-addon' script in kit
        reactions/in-development (dev)

EOF
	}

	reset_kit($env->kit);
	my ($stdout,$stderr,$err) = (
		output_from {dies_ok {$env->deploy()} "deploy exits when specified addon hook fails"},
		$@
	);
	eq_or_diff($err, <<EOF, "deploy error should specify failed reactions");

[FATAL] Cannnot deploy: environment pre-deploy reaction failed!

EOF

	local $ENV{GENESIS_OUTPUT_COLUMNS}=120;
	my $fragment = <<'EOF';
\[predeploy-reaction-fail/thing: PRE-DEPLOY\] Running working-addon addon from kit
reactions/in-development \(dev\):

This addon worked, with arguments of this that

\[predeploy-reaction-fail/thing: PRE-DEPLOY\] Running script `bin/fail-script.sh`
with no arguments:

This script failed
EOF
	like($stderr, qr/$fragment/ms, "deploy output should contain the correct pre-deploy output");

	reset_kit($env->kit);
	($stdout,$stderr,$err) = (
		output_from {dies_ok {$env->deploy()} "deploy exits when specified addon hook doesn't exist"},
		$@
	);

	my $cache_dir = $env->workpath('deploy-cache');
	rmtree $cache_dir if -d $cache_dir;

	put_file $top->path("postdeploy-reaction-fail.yml"), <<EOF;
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  min_version: 3.0.0
  env:  postdeploy-reaction-fail
  bosh_env: reactions
  reactions:
    pre-deploy:
    - addon: working-addon
      args: [ 'this', 'that' ]
    - script: pass-script.sh
      args:
        - just a single arg with spaces
    post-deploy:
    - script: fail-script.sh
    - script: pass-script.sh
EOF

	$env = $top->load_env('postdeploy-reaction-fail');
	$env->use_config($top->path(".cloud.yml"));
	$env->manifest_provider->reset->set_deployment('unredacted');

	($stdout,$stderr,$err) = (
		output_from {lives_ok {$env->deploy()} "deploy runs when pre-deploy reaction passes, but post-deploy reaction fails (and doesn't run remaining reactions after first failed reaction)"},
		$@
	);

	eq_or_diff($err, "", "no fatal error");

	# Pin the essential reaction flow via fragments rather than a full
	# output diff: deploy no longer auto-runs the check phase (moved to
	# `genesis check`), and BOSH-timing/notice text evolves orthogonally.
	my $deploy_flow = qr/
		\[postdeploy-reaction-fail\/thing:\ PRE-DEPLOY\]\ Running\ working-addon\ addon .*
		This\ addon\ worked,\ with\ arguments\ of\ this\ that .*
		\[postdeploy-reaction-fail\/thing:\ PRE-DEPLOY\]\ Running\ script\ `bin\/pass-script\.sh` .*
		This\ script\ passed .*
		Argument\ 1:\ 'just\ a\ single\ arg\ with\ spaces' .*
		\[postdeploy-reaction-fail\/thing\]\ all\ systems\ ok,\ initiating\ BOSH\ deploy\.\.\. .*
		\[postdeploy-reaction-fail\/thing\]\ Deployment\ successful\. .*
		\[postdeploy-reaction-fail\/thing:\ POST-DEPLOY\]\ Running\ script\ `bin\/fail-script\.sh` .*
		This\ script\ failed .*
		\[WARNING\]\ Environment\ post-deploy\ reaction\ failed!
	/sx;
	like($stderr, $deploy_flow,
		"deploy output should contain the correct pre/post-deploy reaction flow");
	# Cross-check that the second post-deploy reaction was skipped after
	# the first one failed (the failure short-circuits the chain).
	unlike($stderr, qr/POST-DEPLOY\] Running script `bin\/pass-script\.sh`/,
		"deploy stops running post-deploy reactions after a failure");

	$env = $top->load_env('postdeploy-reaction-fail'); # Get a fresh copy to reset the state
	$env->use_config($top->path(".cloud.yml"));
	$env->manifest_provider->reset->set_deployment('unredacted');
	($stdout,$stderr,$err) = (
		output_from {lives_ok {$env->deploy('disable-reactions' => 1)} "deploy does not run reactions when disabled"},
		$@
	);

	eq_or_diff($err, "", "no fatal error");

	like($stderr, qr/\[WARNING\] Reactions are disabled for this deploy/,
		"deploy emits a warning when reactions are disabled");
	like($stderr, qr/\[postdeploy-reaction-fail\/thing\] Deployment successful\./,
		"deploy still completes when reactions are disabled");
	unlike($stderr, qr/PRE-DEPLOY/,
		"deploy does not run pre-deploy reactions when disabled");
	unlike($stderr, qr/POST-DEPLOY/,
		"deploy does not run post-deploy reactions when disabled");
	logger->configure_log('/tmp/cleanup.out',level=>'T',show_stack =>'full',truncate=>1,no_color=>0);

  popd;

	teardown_vault();
};

# ---------------------------------------------------------------------------
# CLI option and argument validation
# ---------------------------------------------------------------------------
#
# Drives Genesis::Commands::Env::deploy() through prepare_command +
# direct call, matching the pattern at t/unit-tests/genesis-cli.t:404
# for repo-init.  All assertions target the option/arg validation
# layer that lives in Commands::Env::deploy BEFORE the call to
# $env->deploy() at the bottom of the sub.
#
# Pure CLI-surface unit tests for these scenarios are blocked until
# FWT-1011 (phased command refactor) lands.  Until then, this
# integration block carries the coverage with a shared real vault +
# fake_bosh + Genesis::Top fixture.

subtest 'deploy command option and argument validation' => sub {
	# Declarative plan: 1 vault_ok + (exits_nonzero + like) per
	# mutex pair × 3 pairs = 7.  Auto-plan detection has historically
	# tripped up on the output-capture / exit-via-Test::Exit pattern
	# under subtests, so the count is declared up front.
	plan tests => 7;

	local $ENV{GENESIS_BOSH_COMMAND};
	local $ENV{GENESIS_VERSION} = '3.0.0';
	local $Genesis::VERSION = '3.0.0';
	local $ENV{NOCOLOR} = 'yes';

	# Empty-JSON stub for any `--json` bosh queries the deploy
	# preflight may emit; bare `deploy` is irrelevant here because
	# every test in this block bails before the bosh call.
	fake_bosh(<<'EOF');
	if [[ " $* " == *" --json "* || " $* " == *" --json"* ]] ; then
		echo '{}'
	else
		echo 'BOSH Deploy ran successfully'
	fi
	exit 0
EOF

	my ($director1) = fake_bosh_directors(
		{alias => 'validation'},
	);

	my $vault_target = vault_ok;
	Service::Vault->clear_all();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});

	my $top = Genesis::Top->create(workdir, 'thing', vault => $VAULT_URL);
	`cp -a t/src/simple-3.0.0 ${\($top->path('dev'))}`;

	pushd $top->path;

	# Bare cloud-config the deploy flow can attach to.
	put_file $top->path('.cloud.yml'), <<EOF;
--- {}
# stub cloud config
EOF

	# ------------------- Shared env-file fixture builders -------------------

	# Standard bosh-director-deployed env.
	my $write_standard_env = sub {
		my %extra = @_;
		my $extra_yaml = '';
		for my $k (keys %extra) {
			$extra_yaml .= "  $k: $extra{$k}\n";
		}
		put_file $top->path('standalone.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env:      standalone
  bosh_env: validation
$extra_yaml
EOF
	};

	# Use the house pattern (cf. t/unit-tests/genesis-cli.t):
	#
	#   GENESIS_IGNORE_EVAL=1                ->  bail() exits instead
	#                                            of dying inside eval
	#                                            (lib/Genesis.pm:350).
	#   output_from + exits_nonzero          ->  capture stderr and
	#                                            assert the exit via
	#                                            Test::Exit (clean for
	#                                            Test::Builder).
	#   command_usage override calls exit    ->  GENESIS_IGNORE_EVAL
	#                                            doesn't unblock the
	#                                            command_usage path
	#                                            (Commands.pm:590
	#                                            gates exit on
	#                                            !under_test).  The
	#                                            --fix/--recreate/
	#                                            --dry-run mutex bails
	#                                            via command_usage,
	#                                            so we still need to
	#                                            patch it; we patch at
	#                                            the Exporter-installed
	#                                            alias inside
	#                                            Commands::Env.
	#
	# FWT-1011 (phased command refactor) will move validation to
	# bail()-based exits, eliminating the override entirely.
	local $ENV{GENESIS_IGNORE_EVAL} = 1;

	no warnings 'redefine', 'once';
	local *Genesis::Commands::Env::command_usage = sub {
		my ($rc, $msg) = @_;
		print STDERR sprintf("[FATAL] %s\n", $msg // '(usage)');
		exit($rc // 1);
	};

	# Helper: invoke Commands::Env::deploy through the registered
	# command machinery.  Returns (stdout, stderr).  All options and
	# positionals come through real argv parsing, so option spelling,
	# type coercion, and the `!` (negatable) flags are exercised
	# end-to-end.  Bails inside deploy() reach `exit` thanks to the
	# IGNORE_EVAL flag and the command_usage override above;
	# Test::Exit catches the exit cleanly inside output_from.
	my $run_deploy_cmd = sub {
		my @argv = @_;
		prepare_command('deploy', @argv);
		build_command_environment;
		my ($stdout, $stderr) = output_from {
			exits_nonzero { Genesis::Commands::Env::deploy(get_args()) }
				'deploy command exits non-zero';
		};
		return ($stdout, $stderr);
	};

	# ----------------------- Step 10: mutual exclusion ----------------------

	$write_standard_env->();
	for my $pair (
		[ qw(fix recreate) ],
		[ qw(fix dry-run) ],
		[ qw(recreate dry-run) ],
	) {
		my ($a, $b) = @$pair;
		my (undef, $stderr) = $run_deploy_cmd->(
			"--$a", "--$b", 'standalone', 'reason',
		);
		like(
			$stderr,
			qr/Can only specify one of --dry-run, --fix or --recreate/,
			"--$a + --$b rejects with mutual-exclusion message",
		);
	}

	# ------- Step 5 variant: --fix / --fix-stemcells on create-env --------
	#
	# Deferred: needs a bosh-director kit fixture so `use_create_env`
	# returns true (the simple-3.0.0 fixture isn't a bosh-director
	# kit, so the create-env code path is unreachable through it).
	# Tracked under FWT-1011 follow-up; t/src/bosh-3.0.0-create-env
	# is the right kit but needs the env shape worked out.

	# ----------- Step 13: kit IaaS support enforcement --------------------
	#
	# Deferred: needs a kit fixture declaring `supports:` metadata
	# (e.g. `supports: [aws]`) which none of the current t/src/* kits
	# carry.  Adding such a fixture is straightforward but distinct
	# from the option-validation thrust of this batch.

	# --------- Step 9: reason min-size policy ------------------------------
	#
	# Deferred: deployment_change_reason_required_size_policy reads
	# from the OCFP config or repo `.genesis/config` (see Env.pm:2042),
	# not from the env file — so wiring it up needs a config-level
	# fixture.  Trivial to add but distinct from this batch's option-
	# validation focus.  FWT-1011's phased refactor will isolate this
	# check inside _deploy_validate, making the bail straightforward
	# to exercise.

	popd;
	teardown_vault();
};
