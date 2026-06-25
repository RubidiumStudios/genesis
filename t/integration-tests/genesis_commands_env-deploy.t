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
use Test::More;
use Test::Output;
use Test::Differences;
use Cwd qw/cwd abs_path/;
use File::Path qw/rmtree/;

use_ok 'Genesis::Config';
provide_rc();

use_ok 'Genesis::Env';
use Service::BOSH;
use Genesis::Top;
use Genesis::Env;
use Genesis;

use Service::Vault::Local;

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

	Service::Vault::Local->shutdown_all();
	teardown_vault();
};

done_testing;
