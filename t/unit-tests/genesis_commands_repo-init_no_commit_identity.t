#!perl
use strict;
use warnings;

# `genesis repo-init` checks for a git identity (user.name / user.email)
# in its validate phase.  That identity is only consumed by the initial
# commit, so with --no-commit nothing ever uses it -- yet the check used
# to run unconditionally and killed the command on any host where no
# operator had configured git.  Provisioning tools that stage a fresh
# deployment repository hit this before anyone could have set it up.
#
# These cases drive bin/genesis as a subprocess with HOME pointed at an
# empty directory and git told to ignore both the global and the system
# config, so no identity from the host, CI image, or t/helper.pm's test
# HOME can leak in.  The first case must succeed and leave a staged
# repository behind; the second, which would commit, must still stop
# with the setup message.

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Cwd qw/abs_path/;
use File::Temp qw/tempdir/;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

my $genesis = abs_path("$TOPDIR/bin/genesis");

# The sandbox lives outside the genesis source tree so repo-init does
# not detect an enclosing git worktree and switch to subdirectory mode.
my $sandbox = tempdir(CLEANUP => 1);
my $home    = "$sandbox/home";
my $kit     = "$sandbox/kit";
mkdir_or_fail($home);
mkdir_or_fail($kit);
put_file("$kit/kit.yml", "name: testkit\nversion: 0.0.1\n");

sub run_repo_init {
	my ($work, @args) = @_;
	mkdir_or_fail($work);

	local $ENV{HOME}                = $home;
	local $ENV{GIT_CONFIG_GLOBAL}   = '/dev/null';
	local $ENV{GIT_CONFIG_NOSYSTEM} = 1;
	delete local @ENV{qw/
		GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
	/};

	my $cmd = join(' ', map { "'$_'" } $genesis, 'repo-init', @args);
	my $out = qx(cd '$work' && $cmd 2>&1 </dev/null);
	return ($? >> 8, $out);
}

subtest 'the host really has no git identity in this environment' => sub {
	plan tests => 2;
	local $ENV{HOME}                = $home;
	local $ENV{GIT_CONFIG_GLOBAL}   = '/dev/null';
	local $ENV{GIT_CONFIG_NOSYSTEM} = 1;
	delete local @ENV{qw/GIT_AUTHOR_NAME GIT_COMMITTER_NAME/};
	my $name = qx(git config user.name 2>/dev/null);
	isnt($? >> 8, 0, 'git config user.name reports nothing configured');
	is($name, '', 'no user.name value leaks in from the host');
};

subtest '--no-commit succeeds without a git identity' => sub {
	plan tests => 6;

	my $work = "$sandbox/no-commit";
	my ($rc, $out) = run_repo_init($work, '--no-commit', '--skip-vault', '-l', $kit, 'my-bosh');

	is($rc, 0, 'repo-init --no-commit exits 0') or diag($out);
	unlike($out, qr/Please setup git/, 'no git setup message is printed');
	ok(-f "$work/my-bosh/.genesis/config", '.genesis/config was written');
	ok(-d "$work/my-bosh/.git", 'a git repository was initialised');
	like($out, qr/Skipping initial commit/, 'the initial commit is reported as skipped');

	my $log = qx(cd '$work/my-bosh' && git log --oneline 2>/dev/null);
	is($log, '', 'nothing was committed');
};

subtest 'committing still requires a git identity' => sub {
	plan tests => 3;

	my $work = "$sandbox/commit";
	my ($rc, $out) = run_repo_init($work, '--skip-vault', '-l', $kit, 'my-bosh');

	isnt($rc, 0, 'repo-init without --no-commit fails');
	like($out, qr/Please setup git: git config --global user\.name "Your Name"/,
		'the setup message still names the missing user.name');
	ok(!-e "$work/my-bosh", 'nothing was created before the identity check fired');
};

done_testing;
