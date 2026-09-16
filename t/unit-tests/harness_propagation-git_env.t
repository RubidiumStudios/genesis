#!/usr/bin/env perl
# The fixtures build their repositories by running git with the temporary
# directory as the working directory, which is not on its own enough.  When
# GIT_DIR is inherited and GIT_WORK_TREE is not, git takes the repository from
# GIT_DIR and the work tree from wherever it is standing, so every fixture
# command reads and writes somebody else's repository while looking at the
# fixture's files.  That has already emptied a shared working tree's index
# under a long run, so the fixtures clear those variables themselves rather
# than trusting the environment they were handed.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Genesis qw/run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a fixture build never reaches the repository GIT_DIR names' => sub {
	plan tests => 3;

	# A throwaway of our own, in this test's own temporary directory, so an
	# escape lands here and nowhere a person would miss it.
	my $victim = workdir() . '/victim-' . $$ . '.git';
	run({onfailure => "Failed to build the throwaway"},
		'git', 'init', '-q', '--bare', $victim);

	my $h;
	{
		local $ENV{GIT_DIR} = $victim;
		$h = make_harness(envs => ['qa'], vault => 0);
		init_branch($h, 'qa');
	}

	my ($count, $rc) = run({dir => $victim, stderr => 0},
		'git', 'rev-list', '--all', '--count');
	chomp $count if defined $count;
	is($rc, 0, 'the throwaway is still a repository git can read');
	is($count, '0', 'and it took none of the commits the fixture wrote');

	ok(scalar(commits_on($h->a, $h->control)) > 0,
		'while the fixture repository took them, so the build did happen');
};

subtest 'the scrub clears what git reads a repository out of' => sub {
	# Every variable git would take a repository, an index, an object store,
	# or a configuration file from, and nothing else.  The author and
	# committer pair stay, because a fixture commit is signed out of them and
	# the pre-flight rows arm them deliberately.
	my @cleared = qw/
		GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
		GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
		GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
		GIT_CONFIG_COUNT
	/;
	my @kept = qw/
		GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
		GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
	/;
	plan tests => scalar(@cleared) + scalar(@kept);

	local @ENV{@cleared, @kept};
	$ENV{$_} = 'armed by this row' for (@cleared, @kept);

	scrub_git_env();

	ok(!exists $ENV{$_}, "$_ is gone") for @cleared;
	is($ENV{$_}, 'armed by this row', "$_ is left alone") for @kept;
};

done_testing;
