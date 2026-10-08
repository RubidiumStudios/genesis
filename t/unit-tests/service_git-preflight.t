#!/usr/bin/env perl
# Proves T72: the pre-flight names each of the three failures it can
# classify, and begin and genesis new reach them through the same helper.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Cwd ();
use Test::More;
use Genesis;
use Genesis::Exit qw/CONFIG DATAERR/;
use_ok 'Service::Git';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a working tree git refuses under safe.directory' => sub {
	plan tests => 4;

	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'safe_directory');
	my $git  = Service::Git->new($path);

	# git compares a safe.directory entry against the resolved path, so the
	# resolved spelling is the one the operator has to paste.  The row reads
	# it off the filesystem rather than off the handle, so a message naming
	# some other repository would still be caught.
	my $resolved = Cwd::abs_path($path);

	# The fixture marks the repository and leaves the rest to the harness
	# git, which turns the marker into the ownership git refuses on.  That
	# git has to be first on the path for as long as the call runs, which
	# is what the helper's own comment asks a row reading a shape to do.
	# The handle is built above it, under the real git, because the shim
	# refuses the constructor's own first question, which is the row below.
	local $ENV{PATH} = $h->preflight_bin . ":$ENV{PATH}";

	my ($err, $exit) = bail_from(sub { $git->preflight });
	like($err, qr/dubious ownership|safe\.directory/,
		'the message names the condition git refused on');
	like($err, qr/git config --global --add safe\.directory \Q$resolved\E/,
		'the message names the fix as a command the operator can run');
	unlike($err, qr/Failed to checkout/,
		"the generic checkout message H20 names is not what the operator sees");
	is($exit, CONFIG, 'it exits CONFIG, the misconfigured environment');
};

subtest 'the handle refuses to be built there for the same reason' => sub {
	plan tests => 3;

	# The pre-flight is not the first thing that asks git a question.  The
	# constructor asks for the top level before any caller holds a handle,
	# and git declines that too, so a classification that lived only in the
	# pre-flight would never be reached by the command that needs it.  Both
	# raise the one refusal instead.
	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'safe_directory');

	# The same spelling the pre-flight names, because both refusals resolve
	# the path git resolves and an operator who meets this twice should be
	# handed one command rather than two that differ by a symlink.
	my $resolved = Cwd::abs_path($path);

	local $ENV{PATH} = $h->preflight_bin . ":$ENV{PATH}";

	my ($err, $exit) = bail_from(sub { Service::Git->new($path) });
	like($err, qr/git config --global --add safe\.directory \Q$resolved\E/,
		'the constructor names the same fix the pre-flight names');
	unlike($err, qr/Not a git repository/,
		'and not the generic complaint, which says the wrong thing here');
	is($exit, CONFIG, 'it exits CONFIG, as the pre-flight does');
};

subtest 'a process with no committer identity' => sub {
	plan tests => 3;

	# An identity in this process's own environment is one the fixture git
	# cannot take away, and provision_ci_credentials copies the author pair
	# into the committer pair as the handle is built, so all four go before
	# anything else in the row runs.
	my @carried = qw/
		GIT_COMMITTER_NAME GIT_AUTHOR_NAME
		GIT_COMMITTER_EMAIL GIT_AUTHOR_EMAIL
	/;
	local @ENV{@carried};
	delete @ENV{@carried};

	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'no_identity');
	my $git  = Service::Git->new($path);

	local $ENV{PATH} = $h->preflight_bin . ":$ENV{PATH}";

	my ($err, $exit) = bail_from(sub { $git->preflight });
	like($err, qr/no committer identity/,
		'the message names the missing identity');
	like($err, qr/git config user\.name.*git config user\.email/s,
		'the message names both halves of the fix');
	is($exit, CONFIG, 'it exits CONFIG');
};

subtest 'a repository with no commits' => sub {
	plan tests => 3;

	# The only shape that needs no fixture git, because a repository that
	# has never been committed to has no head whatever git is asked.
	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'no_commits');
	my $git  = Service::Git->new($path);

	my ($err, $exit) = bail_from(sub { $git->preflight });
	like($err, qr/has no commits/,
		'the message names the empty repository');
	like($err, qr/git commit/,
		'the message names the fix');
	is($exit, DATAERR, "it exits DATAERR, since the repository's state is the input");
};

subtest 'an unborn HEAD in a repository with commits is not an empty one' => sub {
	plan tests => 4;
	require Genesis::CI::Preflight;

	# The tree stands on a branch with no commit yet while its other branches
	# have commits, as a clone does whose checked-out branch was deleted under
	# it.  There is still no branch to come back to, so it is a problem, but
	# the repository is not empty, and the index reads as added files only
	# because HEAD names nothing to compare it against.
	my $h   = make_harness(envs => ['qa']);
	my $git = $h->git('a');
	run({dir => $h->a, onfailure => 'Failed to stand on an unborn branch'},
		'git', 'checkout', '-q', '--orphan', 'feature/unborn');

	my @problems = $git->preflight_problems;
	is($problems[0] && $problems[0]{code}, DATAERR, 'it is DATAERR');
	like($problems[0] && $problems[0]{text}, qr{feature/unborn.*no commits yet}s,
		'naming the branch the tree stands on');
	unlike($problems[0] && $problems[0]{text}, qr/repository at .* has no commits/s,
		'and not calling the repository one with no commits');
	is(scalar(Genesis::CI::Preflight::repository_problems($git)), 1,
		'nor are the files the index holds called uncommitted changes');
};

subtest 'current_branch names no branch where HEAD names none' => sub {
	plan tests => 3;

	# The pre-deploy gate asks for the branch before the pre-flight has had
	# its say, so what current_branch answers on the shape above decides
	# which of the two an operator hears from.  git prints the literal
	# string HEAD and a fatal and exits non-zero here, and a reader that
	# merged that stream into its answer handed the fatal on as a branch
	# name, which arrived spliced into the gate's own refusal about a tip
	# nothing descends from.  The row catches that reader.
	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'no_commits');
	my $git  = Service::Git->new($path);

	my $branch = $git->current_branch;
	ok(!defined $branch, 'an unborn HEAD answers undefined');
	unlike($branch // '', qr/fatal|ambiguous argument/,
		"and git's own complaint is not handed back as a name");

	# A detached HEAD is the state the answer HEAD belongs to, and the
	# session's _standing_on tells the two apart by exactly that, so the
	# row holds the answer that case still gets.
	my $on = $h->git('a');
	run({dir => $h->a, onfailure => 'Failed to detach HEAD'},
		'git', 'checkout', '-q', '--detach');
	is($on->current_branch, 'HEAD',
		'while a detached HEAD still answers HEAD, as git says it');
};

# D115 asks these before anything else and reports them with every other
# problem it finds, so they are answered rather than raised, in the words the
# refusal had; dubious ownership stays a refusal, because git declines every
# question after it.
subtest 'the problems are answered, not raised, for the run to collect' => sub {
	plan tests => 6;

	my @carried = qw/
		GIT_COMMITTER_NAME GIT_AUTHOR_NAME
		GIT_COMMITTER_EMAIL GIT_AUTHOR_EMAIL
	/;
	local @ENV{@carried};
	delete @ENV{@carried};

	my $h = make_harness(envs => ['qa']);

	my $nobody = Service::Git->new(fixture_preflight($h, 'no_identity'));
	my @who = do {
		local $ENV{PATH} = $h->preflight_bin . ":$ENV{PATH}";
		$nobody->preflight_problems;
	};
	is(scalar @who, 1, 'a missing identity is one problem');
	is($who[0] && $who[0]{code}, CONFIG, 'at CONFIG');
	like($who[0] && $who[0]{text}, qr/no committer identity.*git config user\.name/s,
		'in the words the refusal had');

	my $empty = Service::Git->new(fixture_preflight($h, 'no_commits'));
	my @none = $empty->preflight_problems;
	is($none[0] && $none[0]{code}, DATAERR, 'a repository with no commits is DATAERR');
	like($none[0] && $none[0]{text}, qr/has no commits/, 'naming it');

	is(scalar($h->git('a')->preflight_problems), 0, 'and a healthy one has none');
};

subtest 'dubious ownership is still refused on the spot' => sub {
	plan tests => 1;
	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'safe_directory');
	my $git  = Service::Git->new($path);
	local $ENV{PATH} = $h->preflight_bin . ":$ENV{PATH}";
	my (undef, $exit) = bail_from(sub { $git->preflight_problems });
	is($exit, CONFIG, 'because git answers nothing after it');
};

subtest 'a dirty working tree is a problem for the run to collect' => sub {
	plan tests => 4;
	require Genesis::CI::Preflight;

	my $h   = make_harness(envs => ['qa']);
	my $git = $h->git('a');
	is(scalar(Genesis::CI::Preflight::repository_problems($git)), 0,
		'a clean tree has none');

	put_file($h->a . '/qa.yml', "---\nchanged: 1\n");
	my @dirty = Genesis::CI::Preflight::repository_problems($git);
	is($dirty[0] && $dirty[0]{code}, DATAERR,
		'uncommitted changes are DATAERR, a state a person must clear');
	like($dirty[0] && $dirty[0]{text}, qr/uncommitted changes/, 'named as such');
	like($dirty[0] && $dirty[0]{text}, qr/\bqa\.yml\b/, 'with the path that changed');
	run({dir => $h->a}, 'git', 'checkout', '--', 'qa.yml');
};

subtest 'a healthy working tree passes and returns the handle' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa']);
	my $git = $h->git('a');

	my $returned = $git->preflight;
	is($returned, $git, 'the helper returns the handle so callers can chain');
	ok($git->is_clean, 'and it changed nothing about the working tree');
};

subtest 'the git directory is the one the lock will live in' => sub {
	plan tests => 3;

	my $h   = make_harness(envs => ['qa']);
	my $git = $h->git('a');

	my $dir = $git->git_dir;
	like($dir, qr{^/}, 'it answers an absolute path');
	is($dir, $git->root . '/.git',
		"and in an ordinary clone that is the working tree's own .git");
	isnt($dir, $git->root,
		'which is not the working tree root, since the two part company '.
		'in a linked working tree');
};

subtest 'a git directory that cannot be resolved is refused' => sub {
	plan tests => 2;

	# git answers a failure with its complaint rather than with nothing, so
	# a guard that only asks whether an answer came back would hand the
	# complaint on as a path, and the lock that follows would be written
	# somewhere no one could find it.
	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'safe_directory');
	my $git  = Service::Git->new($path);
	my $root = $git->root;

	local $ENV{PATH} = $h->preflight_bin . ":$ENV{PATH}";

	my $answer = 'untouched';
	my ($err) = bail_from(sub { $answer = $git->git_dir });
	like($err, qr/Unable to resolve the git directory of \Q$root\E/,
		'the refusal names the working tree it could not resolve');
	is($answer, 'untouched',
		"and nothing is handed back where a path belongs");
};

subtest 'genesis new, which opens no session, calls the same helper' => sub {
	plan tests => 2;

	# One helper, two callers.  The pre-flight lives in begin and is shared
	# rather than copied into genesis new, so H20 closes in the session for
	# every switching command and here for the one that does not.  The begin
	# half of this row is asserted where begin lands.
	my $new_pm = get_file('lib/Genesis/Commands/Env.pm');
	like($new_pm, qr/->preflight\b/,
		'genesis new calls the shared helper');
	unlike($new_pm, qr/dubious ownership|safe\.directory/,
		'and classifies nothing of its own');
};

# One local helper, because an assertion helper lives beside its test.  bail
# dies rather than exits whenever it is reached from inside an eval, which a
# test file always is, so there is no exit code in this process to read.  The
# refusal is caught where the code raises it instead, and the code it would
# have exited with is read off the arguments it was composed with, which is
# the same way the pull request branch's refusal is read.
sub bail_from {
	my ($code) = @_;

	my @raised;
	my $died;
	{
		no warnings 'redefine';
		local *Service::Git::bail = sub { push @raised, [@_]; die "refused\n" };
		eval { $code->(); 1 } or $died = $@;
	}
	unless (@raised) {
		# A death with no refusal behind it is something else going wrong,
		# and a row reading an empty message has no way to say so.
		diag("nothing was refused, and the code died with: $died")
			if defined $died;
		return ('', undef);
	}

	my @args = @{$raised[0]};
	my $opts = ref($args[0]) eq 'HASH' ? shift(@args) : {};
	my ($format, @rest) = @args;

	return (sprintf($format, @rest), $opts->{exitcode});
}

done_testing;
