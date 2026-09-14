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

	local $ENV{PATH} = $h->preflight_bin . ":$ENV{PATH}";

	my ($err, $exit) = bail_from(sub { Service::Git->new($path) });
	like($err, qr/git config --global --add safe\.directory \Q$path\E/,
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

	# One helper, two callers.  D80 keeps the pre-flight in begin and shares
	# it rather than giving genesis new a second copy, so H20 closes in the
	# session for every switching command and here for the one that does not.
	# The begin half of this row is asserted where begin lands.
	my $new_pm = get_file('lib/Genesis/Commands/Env.pm');
	like($new_pm, qr/->preflight\b/,
		'genesis new calls the shared helper, as D80 says it does');
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
