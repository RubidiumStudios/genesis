#!perl
use strict;
use warnings;
use utf8;

# Integration coverage for `genesis repo-init` (alias: `init`) --
# the phases that create real filesystem state.  Split from the
# sibling unit-tests file, which stays focused on registration-
# shape and option-parsing assertions.
#
# Subtests in this file:
#   1. Validate phase -- _repo_init_validate lives/throws, exercising
#      real kit tarballs and dev-kit fixtures on disk
#   2. Execute phase  -- _repo_init_execute against real workdirs;
#      creates deployment dirs, extracts kit tarballs, writes
#      .genesis/config, initialises git, symlinks dev kits
#
# Tests are written against the CURRENT command spec, not legacy.  The
# `--sub`/`--no-sub` option was removed in favour of auto-detection via
# `Service::Git->is_inside_work_tree('.')` (Commands/Repo.pm:131).  The
# `--ci-provider` option was replaced by `--with-ci` (commit 2dbb3984,
# 2026-04-22): repo-init now only sets up the manual provider, with
# automated providers configured later via `genesis repo config ci` --
# bootstrap circularity means we can't init with the very provider
# being deployed by this repo.  `--force` was standardised to `-f`
# (commit 78da5319, 2026-04-19).

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Output;

use Genesis::Commands;
use PadWalker qw/closed_over/;
# Explicit Genesis import list -- the default `use Genesis;` would
# export workdir(), shadowing helper::workdir().  helper's version
# returns predictable $WORKDIR/<name> paths; Genesis's returns
# tempdir-within-tempdir paths with random basenames (Genesis.pm:406),
# which breaks any test relying on basename() of the workdir path.
use Genesis qw/pushd popd slurp run mkfile_or_fail symlink_or_fail/;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# Both validate and execute phases emit info() output (the "Creating
# <name> deployment repository" banner, "Files staged for initial
# commit" listing, "Committed XXXX..." line).  Useful diagnostics in
# a real run; pure noise during the test suite if we just drop them.
# These wrappers capture stdout/stderr around each call and return
# ($rv, $stdout, $stderr) so individual tests can either ignore the
# output (most cases) or assert on representative banner content.
sub run_validate {
	my ($rv, $out, $err);
	($out, $err) = output_from(sub {
		$rv = Genesis::Commands::Repo::_repo_init_validate();
	});
	return ($rv, $out, $err);
}
sub run_execute {
	my ($rv, $out, $err);
	($out, $err) = output_from(sub {
		$rv = Genesis::Commands::Repo::_repo_init_execute();
	});
	return ($rv, $out, $err);
}

# Load the command registry by requiring bin/genesis (its main() is
# guarded with `unless caller`, so this only runs the define_command
# calls, not the CLI dispatcher).  Needed here so prepare_command()
# resolves 'repo-init' in the validate + execute subtests below.
# Registration-shape assertions live in the sibling unit-tests file.
require './bin/genesis';

# ---------------------------------------------------------------------------
# Phase 3: validate phase -- _repo_init_validate lives/throws
# ---------------------------------------------------------------------------

subtest 'validate phase' => sub {
	plan tests => 13;

	require Genesis::Commands::Repo;
	delete $ENV{GENESIS_IGNORE_EVAL};       # let bail() die instead of exit
	$ENV{GIT_AUTHOR_NAME}     = 'Test User';
	$ENV{GIT_AUTHOR_EMAIL}    = 'test@example.com';
	$ENV{GIT_COMMITTER_NAME}  = 'Test User';
	$ENV{GIT_COMMITTER_EMAIL} = 'test@example.com';

	# pushd into a non-git working directory so the auto-detect at
	# Commands/Repo.pm:131 (Service::Git->is_inside_work_tree) does NOT
	# treat the genesis source tree as the enclosing repo.  Without
	# this, any test that exercises the subdir code path (e.g. the
	# --with-ci subdir + control-branch check at Commands/Repo.pm:165)
	# would bail because the current branch is v3.2.x-dev, not control.
	my $sandbox = workdir('validate-sandbox');
	pushd($sandbox);

	my $vt_devkit  = workdir('validation-devkit');
	# Make $vt_devkit a proper kit fixture: the validate phase now
	# rejects -l targets without kit.yml.  The `name:` field is set
	# to match the dir basename so name-derivation tests below have
	# a deterministic expected value either way.
	mkfile_or_fail("$vt_devkit/kit.yml", "name: validation-devkit\nversion: 0.0.1\n");

	my $vt_tarball = workdir('validation-tarball');
	mkfile_or_fail("$vt_tarball/bosh-0.0.1.tar.gz", "fake kit tarball");

	# Valid: kit tarball + explicit name.  --skip-vault keeps the
	# validate phase non-interactive (it would otherwise call
	# _select_vault_target and prompt at Commands/Repo.pm:238).
	# Vault-selection mechanics are tested separately; validate just
	# delegates.
	prepare_command('repo-init', '-k', "$vt_tarball/bosh-0.0.1.tar.gz",
		'--skip-vault', 'my-bosh');
	build_command_environment;
	my ($vrv, $vout, $verr);
	lives_ok { ($vrv, $vout, $verr) = run_validate() }
		'valid: local kit tarball + name';
	like($verr, qr/Creating\s+my-bosh\s+deployment\s+repository/,
		'validate banner names the deployment');
	like($verr, qr{my-bosh/}, 'validate banner names the target directory');

	# Valid: link-dev-kit + skip-vault
	prepare_command('repo-init', '-l', $vt_devkit, '--skip-vault', 'my-bosh');
	build_command_environment;
	lives_ok { run_validate() }
		'valid: link-dev-kit + skip-vault';

	# Valid: with-ci (manual provider only, no provider type needed)
	prepare_command('repo-init', '-l', $vt_devkit, '--skip-vault', '--with-ci', 'my-bosh');
	build_command_environment;
	lives_ok { run_validate() }
		'valid: --with-ci enables manual provider';

	# Valid: name derived from link-dev-kit basename when positional omitted
	prepare_command('repo-init', '-l', $vt_devkit, '--skip-vault');
	build_command_environment;
	lives_ok { run_validate() }
		'valid: name derived from link-dev-kit basename';

	# Invalid: --vault and --skip-vault together
	prepare_command('repo-init', '-l', $vt_devkit,
		'--vault', 'my-vault', '--skip-vault', 'my-bosh');
	build_command_environment;
	throws_ok { run_validate() }
		qr/Cannot specify both --vault and --skip-vault/,
		'invalid: --vault + --skip-vault rejected';

	# Invalid: --kit and --link-dev-kit together
	prepare_command('repo-init', '-k', "$vt_tarball/bosh-0.0.1.tar.gz",
		'-l', $vt_devkit, 'my-bosh');
	build_command_environment;
	throws_ok { run_validate() }
		qr/only specify one of kit.*or link/i,
		'invalid: --kit + --link-dev-kit rejected';

	# Invalid: nothing supplied -- no name, no kit, no dev-kit link
	prepare_command('repo-init');
	build_command_environment;
	throws_ok { run_validate() }
		qr/must specify a deployment name/i,
		'invalid: empty invocation rejected';

	# Valid: name-only (no -k, no -l) creates a repo with an empty
	# dev/ directory the user can populate manually.  Per the kit
	# option's help text in bin/genesis: "If you do not specify a kit,
	# a dev directory will be created for you to develop a local kit
	# into."  This is the explicit "I'll write my own kit" path.
	prepare_command('repo-init', '--skip-vault', 'my-bosh');
	build_command_environment;
	lives_ok { run_validate() }
		'valid: name-only (empty dev kit will be created)';

	# -l pointing to a directory without kit.yml bails.  A link target
	# without kit.yml isn't a valid kit definition -- the user is
	# expressing "link to a kit" intent and would otherwise get an
	# invalid kit silently.  Users who want an empty dev directory
	# should use name-only (just-tested above) without -l.
	my $empty_link_target = workdir('validate-empty-link');
	# (directory created by workdir() but no kit.yml inside)
	prepare_command('repo-init', '-l', $empty_link_target, '--skip-vault', 'my-bosh');
	build_command_environment;
	throws_ok { run_validate() }
		qr/missing kit\.yml/i,
		'invalid: -l target without kit.yml rejected';

	# -l target has a kit.yml but it lacks the required `name:` field.
	# Source can't derive a deployment name from a nameless kit, so it
	# bails rather than fall back to the directory basename (which
	# would silently mask the malformed kit).
	my $no_name_link = workdir('validate-no-name-link');
	mkfile_or_fail("$no_name_link/kit.yml", "version: 0.0.1\n");
	prepare_command('repo-init', '-l', $no_name_link, '--skip-vault');
	build_command_environment;
	throws_ok { run_validate() }
		qr/missing the required.*name:/i,
		'invalid: -l target with nameless kit.yml rejected';

	# -l target has a kit.yml that doesn't parse as YAML.  Source
	# surfaces the parse failure rather than silently falling through.
	my $bad_yaml_link = workdir('validate-bad-yaml-link');
	mkfile_or_fail("$bad_yaml_link/kit.yml", "name: : : not valid yaml :::\n");
	prepare_command('repo-init', '-l', $bad_yaml_link, '--skip-vault');
	build_command_environment;
	throws_ok { run_validate() }
		qr/unreadable kit\.yml/i,
		'invalid: -l target with malformed kit.yml rejected';

	popd;
};

# ---------------------------------------------------------------------------
# Phase 4: execute phase -- _repo_init_execute against real workdirs
# ---------------------------------------------------------------------------

subtest 'execute phase' => sub {
	plan tests => 41;

	require Genesis::Commands::Repo;
	local $Genesis::VERSION = '3.2.0-rc2';
	delete $ENV{GENESIS_IGNORE_EVAL};

	$ENV{GIT_AUTHOR_NAME}     = 'Test User';
	$ENV{GIT_AUTHOR_EMAIL}    = 'test@example.com';
	$ENV{GIT_COMMITTER_NAME}  = 'Test User';
	$ENV{GIT_COMMITTER_EMAIL} = 'test@example.com';

	my $devkit      = Cwd::abs_path('t/src/simple');
	my $kit_tarball = Cwd::abs_path(
		't/repos/compiled-kit-test/.genesis/kits/compiled-0.0.1.tar.gz');

	# ----- Auto-detect subdir mode: inside an enclosing git repo -----

	my $sub = workdir('execute-subdir');
	pushd($sub);
	run('git init 2>/dev/null');
	prepare_command('repo-init', '-l', $devkit, '--skip-vault', 'bosh');
	build_command_environment;
	run_validate();
	my ($r, $eout, $eerr) = run_execute();

	ok(-d "$sub/bosh",                'subdir: bosh directory created');
	ok(-d "$sub/bosh/.genesis",       'subdir: .genesis directory created');
	ok(-f "$sub/bosh/.genesis/config",'subdir: .genesis/config written');
	ok(!-e "$sub/bosh/.git",          'subdir: no .git in subdirectory mode');
	ok(-l "$sub/bosh/dev",            'subdir: dev symlink created for linked dev kit');
	ok(!-d "$sub/bosh/.genesis/bin",  'subdir: no .genesis/bin without --with-ci');
	ok($r->{submodule},               'subdir: result submodule is true');
	is($r->{name}, 'bosh',            'subdir: result name is bosh');
	ok($r->{vault_skipped},           'subdir: result vault_skipped is true');
	ok(!$r->{vault},                  'subdir: result vault is undef');
	like($eerr, qr/Files staged for initial commit/,
		'subdir: execute reports staged files banner');
	like($eerr, qr/Committed\s+\S+\s+--\s+Initial Genesis repo for bosh/,
		'subdir: execute reports initial commit with sha and message');
	popd;

	# ----- Auto-detect standalone mode: outside any git repo -----

	my $standalone = workdir('execute-standalone');
	pushd($standalone);   # no git init -- this is not a git repo
	prepare_command('repo-init', '-l', $devkit, '--skip-vault', 'bosh');
	build_command_environment;
	run_validate();
	my ($rstand) = run_execute();

	ok(-d "$standalone/bosh/.git",
		'standalone: .git created (not inside any enclosing repo)');
	ok(!$rstand->{submodule},
		'standalone: result submodule is false');
	popd;

	# ----- --force replaces an existing target directory -----

	my $force = workdir('execute-force');
	pushd($force);
	mkdir_or_fail("$force/bosh");
	mkfile_or_fail("$force/bosh/sentinel.txt", "should be removed");

	prepare_command('repo-init', '-l', $devkit, '--skip-vault', '-f', 'bosh');
	build_command_environment;
	run_validate();
	run_execute();

	ok(-d "$force/bosh/.genesis",
		'force: .genesis created after force replace');
	ok(!-f "$force/bosh/sentinel.txt",
		'force: old sentinel file removed by --force');
	popd;

	# ----- Existing directory without --force bails (non-interactive) -----

	my $nf = workdir('execute-no-force');
	pushd($nf);
	mkdir_or_fail("$nf/bosh");
	prepare_command('repo-init', '-l', $devkit, '--skip-vault', 'bosh');
	build_command_environment;
	throws_ok { run_validate() }
		qr/already exists.*-f\b/,
		'no-force: bails on existing directory in non-interactive mode (suggests -f)';
	popd;

	# ----- Name derived from --link-dev-kit basename when omitted -----

	my $derived = workdir('execute-derived-name');
	pushd($derived);
	prepare_command('repo-init', '-l', $devkit, '--skip-vault');
	build_command_environment;
	run_validate();
	my ($rderived) = run_execute();

	ok(-d "$derived/simple/.genesis",
		'derived: directory named from dev-kit basename (simple)');
	is($rderived->{name}, 'simple',
		'derived: result name from dev-kit basename');
	popd;

	# ----- Custom --directory overrides the default name-derived dir -----

	my $cd = workdir('execute-custom-dir');
	pushd($cd);
	prepare_command('repo-init', '-k', $kit_tarball,
		'--skip-vault', '-d', 'my-custom-dir', 'bosh');
	build_command_environment;
	run_validate();
	run_execute();

	ok(-d "$cd/my-custom-dir/.genesis",
		'custom-dir: created under -d path');
	ok(!-e "$cd/bosh",
		'custom-dir: default "bosh" directory not created');
	my $cfg_cd = slurp("$cd/my-custom-dir/.genesis/config");
	like($cfg_cd, qr/deployment_type: bosh/,
		'custom-dir: deployment_type still derived from kit, not directory name');
	popd;

	# ----- Custom name different from the kit name -----

	my $cn = workdir('execute-custom-name');
	pushd($cn);
	prepare_command('repo-init', '-l', $devkit, '--skip-vault', 'my-boshen');
	build_command_environment;
	run_validate();
	my ($rcn) = run_execute();

	ok(-d "$cn/my-boshen/.genesis",
		'custom-name: directory uses custom name, not kit name');
	is($rcn->{name}, 'my-boshen',
		'custom-name: result name matches custom name');
	my $cfg_cn = slurp("$cn/my-boshen/.genesis/config");
	like($cfg_cn, qr/deployment_type: my-boshen/,
		'custom-name: deployment_type uses custom name');
	popd;

	# ----- --link-dev-kit creates symlink + records descriptive kit_desc -----

	my $sym = workdir('execute-symlink');
	my $dk  = workdir('execute-symlink-devkit');
	mkdir_or_fail("$dk/hooks");
	mkfile_or_fail("$dk/kit.yml", "name: testkit\nversion: 0.0.1\n");
	pushd($sym);
	prepare_command('repo-init', '-l', $dk, '--skip-vault', 'my-devkit');
	build_command_environment;
	run_validate();
	my ($rsym) = run_execute();

	ok(-d "$sym/my-devkit/.genesis",
		'symlink: .genesis created for linked dev kit');
	ok(-l "$sym/my-devkit/dev",
		'symlink: dev is a symlink');
	is(Cwd::abs_path(readlink("$sym/my-devkit/dev")), Cwd::abs_path($dk),
		'symlink: dev symlink points to the linked dev-kit dir');
	like($rsym->{kit_desc}, qr/linked.*kit/i,
		'symlink: result kit_desc mentions linked kit');
	popd;

	# ----- Config field correctness (using compiled kit tarball) -----

	my $cfg = workdir('execute-config');
	pushd($cfg);
	prepare_command('repo-init', '-k', $kit_tarball, '--skip-vault', 'my-cf');
	build_command_environment;
	run_validate();
	run_execute();

	my $c = slurp("$cfg/my-cf/.genesis/config");
	like($c, qr/deployment_type: my-cf/,        'config: deployment_type matches name');
	like($c, qr/version: 3/,                    'config: version: 3 (current schema)');
	like($c, qr/creator_version: 3\.2\.0-rc2/,  'config: creator_version recorded');
	like($c, qr/minimum_version: 3\.2\.0-rc2/,  'config: minimum_version recorded');
	like($c, qr/manifest_store: exodus/,        'config: manifest_store defaults to exodus');
	unlike($c, qr/secrets_provider/,            'config: no secrets_provider when --skip-vault');
	unlike($c, qr/kit_provider/,                'config: no kit_provider (using default)');
	popd;

	# ----- -l derives deployment_type from the linked kit.yml's
	#       `name:` field, not from the directory basename.  The dir
	#       basename ('some-other-basename') deliberately differs
	#       from kit.yml's `name: widget` so the assertion is
	#       meaningful (proves the source read kit.yml, not basename).

	my $kit_yml_dir = workdir('some-other-basename');
	mkdir_or_fail("$kit_yml_dir/hooks");
	mkfile_or_fail("$kit_yml_dir/kit.yml",
		"name: widget\nversion: 0.0.1\n");

	my $kydir = workdir('execute-kit-yml-target');
	pushd($kydir);
	prepare_command('repo-init', '-l', $kit_yml_dir, '--skip-vault');
	build_command_environment;
	run_validate();
	run_execute();

	ok(-d "$kydir/widget",
		'kit.yml-derived: directory uses kit.yml name (widget), not link basename');
	my $cfg_ky = slurp("$kydir/widget/.genesis/config");
	like($cfg_ky, qr/deployment_type: widget/,
		'kit.yml-derived: deployment_type matches kit.yml name');
	popd;

	# ----- --with-ci sets up the manual provider scaffolding -----

	my $wc = workdir('execute-with-ci');
	pushd($wc);
	prepare_command('repo-init', '-l', $devkit, '--skip-vault', '--with-ci', 'bosh');
	build_command_environment;
	run_validate();
	my ($rwc) = run_execute();

	my $cfg_wc = slurp("$wc/bosh/.genesis/config");
	like($cfg_wc, qr/^ci:/m,
		'with-ci: config has a ci: section');
	like($cfg_wc, qr/enabled: true/,
		'with-ci: ci.enabled is true');
	is($rwc->{ci_provider}, 'manual',
		'with-ci: result ci_provider is manual (full provider config deferred to `repo config ci`)');
	popd;
};

done_testing;
