package Harness::GitEnv;
# The one place the suite takes git's own variables out of the environment.
#
# A fixture builds its repository by running git with the temporary directory
# as the working directory, and that is not enough on its own.  When GIT_DIR
# is inherited and GIT_WORK_TREE is not, git takes the repository from GIT_DIR
# and the work tree from wherever it is standing, so every fixture command
# reads and writes somebody else's repository while looking at the fixture's
# files.  A long run under an exported GIT_DIR did exactly that once and left
# a shared working tree with an empty index.
#
# It lives in a module of its own rather than in helper, because the git
# double is loaded into a spawned genesis child through PERL5OPT and loading
# helper there would print helper's own notice into that child's output.
# Everything else reaches it through helper, which re-exports it.
use strict;
use warnings;

use Exporter qw/import/;
our @EXPORT = qw/scrub_git_env/;

# @VARS - what a fixture clears, and what it deliberately leaves alone {{{
#
# The first seven are every way git can be told which repository, index, or
# object store a command is about, so clearing them is what puts the fixture
# back in charge of the repository it built.
#
# The four after them are the configuration.  helper::import already points
# HOME at the test home and writes a deterministic .gitconfig there, but an
# inherited GIT_CONFIG_GLOBAL or GIT_CONFIG_SYSTEM overrides that and hands
# the operator's own configuration back to the fixtures, GIT_CONFIG_COUNT
# does the same through its numbered key and value pairs, and
# GIT_CONFIG_NOSYSTEM decides whether the system file is read at all.
# Clearing GIT_CONFIG_COUNT is enough for the numbered pairs, since git reads
# none of them without a count to read them by.
#
# The author and committer pair are not here and must not be.  A fixture
# commit is signed out of them, Service::Git copies the author pair into the
# committer pair as a handle is built, and the pre-flight rows arm and
# withhold them deliberately.
#
# The configuration four carry the same warning from the other direction.
# t/unit-tests/genesis_commands_repo-init_no_commit_identity.t arms
# GIT_CONFIG_GLOBAL and GIT_CONFIG_NOSYSTEM on purpose, with a local, so that
# a row can watch git find no identity at all.  A scrub called deeper than an
# entry point, inside a scope like that one, would take the arming away and
# the row would quietly stop testing what it says it tests.
our @VARS = qw/
	GIT_DIR
	GIT_WORK_TREE
	GIT_INDEX_FILE
	GIT_OBJECT_DIRECTORY
	GIT_ALTERNATE_OBJECT_DIRECTORIES
	GIT_COMMON_DIR
	GIT_NAMESPACE

	GIT_CONFIG_GLOBAL
	GIT_CONFIG_SYSTEM
	GIT_CONFIG_NOSYSTEM
	GIT_CONFIG_COUNT
/;

# }}}
# scrub_git_env - clear them, and say how many went {{{
#
# Called at the entry points, and not down beside each git command, because
# Service::Git and the harness both set GIT_INDEX_FILE through a local of
# their own for the length of a call.  A scrub reaching inside one of those
# would take away the temporary index the call is standing on.
sub scrub_git_env {
	my @held = grep {exists $ENV{$_}} @VARS;
	delete @ENV{@VARS};
	return scalar @held;
}

# }}}

1;
