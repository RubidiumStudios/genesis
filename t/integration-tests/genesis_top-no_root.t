#!/usr/bin/env perl
# Proves T418's refusal rows (D120, noted 2026-11-02): a command that finds no
# deployment root, in a git work tree, says where the roots are and what to
# do, the same words whatever the command.
#
# A branch carrying no root at all, in a repository with control (local, or
# only a remote's), names the branch, control, the roots control carries, and
# the checkout and the cd.  A branch that does carry roots, where the
# directory is none of them, names this branch's roots, or the one root the
# directory sits inside.  Outside a git work tree, or where there is neither
# a root on the branch nor a control, the message is the one it always was.
#
# What the rows catch: an operator on a fresh clone standing on a rootless
# default branch told only that '.' is not a deployment repository, or that
# their environment is an unrecognised command.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use File::Temp qw/tempdir/;

use Genesis qw/run mkdir_or_fail mkfile_or_fail/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $base = "$ENV{GENESIS_TEST_TMP}/no-root";
mkdir_or_fail($base);

sub git_in {
	my ($dir, @args) = @_;
	run({dir => $dir, onfailure => "git @args failed in $dir"},
		'git', '-c', 'user.email=t@example.com', '-c', 'user.name=T', @args);
}

# R: control carries the doomsday root, with a subdirectory; main is an
# orphan carrying a README alone, as GitHub's default branch is before
# control is made the default.
my $r = "$base/r";
mkdir_or_fail($r);
git_in($r, 'init', '-q', '-b', 'control');
mkfile_or_fail("$r/doomsday/.genesis/config", "---\ngenesis:\n  deployment_type: doomsday\n  version: 3\n");
mkfile_or_fail("$r/doomsday/ops/shared.yml", "---\n");
git_in($r, 'add', '-A');
git_in($r, 'commit', '-q', '-m', 'the doomsday root');
git_in($r, 'checkout', '-q', '--orphan', 'main');
git_in($r, 'rm', '-q', '-r', '-f', '.');
mkfile_or_fail("$r/README.md", "readme\n");
git_in($r, 'add', 'README.md');
git_in($r, 'commit', '-q', '-m', 'readme');

sub said {
	my ($dir, @argv) = @_;
	my ($out, $rc, $err) = run({dir => $dir, stderr => 0, passfail => 0},
		"$helper::TOPDIR/bin/genesis", @argv);
	my $said = join("\n", grep {defined} $out, $err);
	$said =~ s/\e\[[0-9;]*m//g;
	$said =~ s/\s+/ /g;
	return ($said, $rc);
}

subtest 'a rootless branch, control here: every command names control\'s roots' => sub {
	for my $argv (['pipeline-status'], ['qa', 'info']) {
		my ($said, $rc) = said($r, @$argv);
		isnt($rc, 0, "genesis @$argv refuses");
		like($said, qr/the branch checked out here, main, carries no deployment root/,
			'naming the branch');
		like($said, qr/live on control/, 'and control');
		like($said, qr/\bdoomsday\b/, 'listing the root control carries');
		like($said, qr/git checkout control/, 'with the checkout');
		like($said, qr/cd doomsday/, 'and the cd');
		unlike($said, qr/Unrecognized command|is not a Genesis deployment repository/,
			'never the old words');
	}
};

subtest 'a fresh clone on the rootless branch reads control off the remote' => sub {
	my $clone = "$base/clone";
	git_in($base, 'clone', '-q', '-b', 'main', "file://$r", $clone);
	my ($said) = said($clone, 'pipeline-status');
	like($said, qr/live on control/, 'naming control, which only the remote has');
	like($said, qr/\bdoomsday\b/, 'and its root');
	like($said, qr/git checkout control/, 'with the checkout that makes it local');
};

subtest 'a branch with roots, in none of them' => sub {
	git_in($r, 'checkout', '-q', 'control');
	my ($said) = said($r, 'pipeline-status');
	like($said, qr/not a Genesis deployment root/, 'the top of the clone is not a root');
	like($said, qr/roots on this branch, control,.*\bdoomsday\b/, 'naming the branch\'s roots');
	like($said, qr/cd doomsday/, 'and how to reach one');
	unlike($said, qr/git checkout/, 'with no checkout, the branch being right');

	my ($inside) = said("$r/doomsday/ops", 'pipeline-status');
	like($inside, qr/inside the deployment root doomsday/, 'below a root, that root is named');
	like($inside, qr{cd \.\.}, 'with the way back up to it');
	git_in($r, 'checkout', '-q', 'main');
};

subtest 'neither a root nor control: the old words' => sub {
	my $plain = "$base/plain";
	mkdir_or_fail($plain);
	git_in($plain, 'init', '-q', '-b', 'main');
	mkfile_or_fail("$plain/README.md", "readme\n");
	git_in($plain, 'add', 'README.md');
	git_in($plain, 'commit', '-q', '-m', 'readme');
	my ($said) = said($plain, 'pipeline-status');
	like($said, qr/is not a Genesis deployment repository/, 'a repository with neither');

	my $outside = tempdir(CLEANUP => 1);
	($said) = said($outside, 'pipeline-status');
	like($said, qr/is not a Genesis deployment repository/, 'and outside any git work tree');
};

done_testing;
