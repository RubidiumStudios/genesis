#!/usr/bin/env perl
# Proves T203: genesis new runs the same pre-flight helper a session's
# begin runs, so a broken repository fails in one place with one text
# whether the command that met it opened a session or not.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Genesis;

# The final assertion in each case compares two wrapped lines, so the width
# is pinned here rather than left to the terminal the suite runs in.
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# An identity in this process's own environment is one the fixture git
# cannot take away, and every command under test is a child that inherits
# whatever this process carries, so all four variables go before any run.
# The committer pair alone would not be enough, because
# provision_ci_credentials copies the author pair into it as a handle is
# built, and the pre-flight reads both pairs when the repository names
# neither.
delete @ENV{qw/
	GIT_COMMITTER_NAME GIT_AUTHOR_NAME
	GIT_COMMITTER_EMAIL GIT_AUTHOR_EMAIL
/};

# The two shapes come from the harness, which marks the repository and lets
# the fixture git turn that marker into the environment real git refuses on.
# A chown to another user is what a process running as the one user that
# owns the suite's files cannot do, and it fails silently.
my @cases = (
	{
		name    => 'no committer identity',
		kind    => 'no_identity',
		matches => qr/git config user\.(email|name)/,
	},
	{
		# The refusal an operator meets here today is the one the
		# deployment root raises when git declines to call the directory a
		# checkout, and not the safe.directory fix the pre-flight names,
		# because Genesis::Top asks Service::Git->is_inside_work_tree
		# before any command runs and that predicate keeps git's reason to
		# itself.  Both callers still print the one line, which is what
		# this row is about, so the matcher names either wording and the
		# row reads the same whichever of the two the tree raises.  The
		# classification itself is held at the unit level, by the two
		# safe.directory rows in t/unit-tests/service_git-preflight.t.
		#
		# The alternation is to be narrowed to safe.directory alone when
		# Genesis::Top stops pre-checking is_inside_work_tree and
		# swallowing git's dubious-ownership reason.  Whoever makes that
		# change narrows this matcher with it.
		name    => 'a working tree git refuses to touch',
		kind    => 'safe_directory',
		matches => qr/safe\.directory|is not a git checkout/i,
	},
);

for my $case (@cases) {
	subtest "both callers fail on $case->{name}" => sub {
		my $h = make_harness(envs => ['qa'], type => 'bosh',
			kit => 'omega-v2.7.0');
		# The deployment branch is what gives the second caller a session
		# to open, because a deployed-state command runs where it stands
		# when the environment has never been delivered.
		init_branch($h, 'qa');
		refresh($h, 'a');
		fixture_preflight($h, $case->{kind}, copy => 'a');

		# Catches a genesis new that classifies a broken repository on its
		# own.  The two callers would each name the condition their own
		# way, and an operator would fix one repository twice.
		my ($out, $err, $exit) = run_genesis($h, 'new', 'prod', '--no-commit');
		isnt($exit, 0, 'genesis new failed');
		like($err, $case->{matches}, 'and named the condition');

		# A command that does open a session fails in the same helper, so
		# the two texts are the same string and not two spellings of it.
		my ($sout, $serr, $sexit) = run_genesis($h, 'qa', 'info');
		isnt($sexit, 0, 'the session caller failed too');
		like($serr, $case->{matches}, 'and named the same condition');

		# The discriminator.  Two callers classifying a broken repository
		# on their own would each print a line, and the two lines would
		# differ; one helper prints one line for both.
		my ($new_line)  = grep {$_ =~ $case->{matches}} split /\n/, $err;
		my ($sess_line) = grep {$_ =~ $case->{matches}} split /\n/, $serr;
		is($new_line, $sess_line,
			'both callers printed the same line from the same helper');

		# One classification carries one code, so a caller that reached
		# its own refusal would be visible here as well as in the text.
		is($sexit, $exit, 'and both exited on the same code');
	};
}

subtest 'both callers fail on a repository with no commits' => sub {
	# The third shape the pre-flight classifies, and it is built here
	# rather than through the harness.  fixture_preflight refuses to build
	# it in a copy, because both copies carry the seeding commit, and the
	# repository it builds beside the harness is no deployment root and can
	# hold no delivered branch, so no whole command can run in one.  An
	# orphan checkout is the same state read through the same question,
	# because HEAD resolves to nothing there, which is what the pre-flight
	# asks git and classifies the failure of.
	my $matches = qr/no commits/i;

	my $h = make_harness(envs => ['qa'], type => 'bosh',
		kit => 'omega-v2.7.0');
	init_branch($h, 'qa');
	refresh($h, 'a');
	run({dir => $h->a, onfailure => 'Failed to stand on an unborn branch'},
		'git', 'checkout', '-q', '--orphan', 'unborn');

	# Catches a gate that classifies the branch before the pre-flight has
	# had its say.  There is no branch here to measure against control's
	# tip, and a gate that measured anyway told an operator with nothing
	# committed to rebase.
	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod', '--no-commit');
	isnt($exit, 0, 'genesis new failed');
	like($err, $matches, 'and named the condition');

	# Catches a session whose begin skipped the pre-flight.  The operator
	# would meet the empty repository at the commit instead, which is the
	# late generic failure D80 moved the classification ahead of.
	my ($sout, $serr, $sexit) = run_genesis($h, 'qa', 'info');
	isnt($sexit, 0, 'the session caller failed too');
	like($serr, $matches, 'and named the same condition');

	my ($new_line)  = grep {$_ =~ $matches} split /\n/, $err;
	my ($sess_line) = grep {$_ =~ $matches} split /\n/, $serr;
	is($new_line, $sess_line,
		'both callers printed the same line from the same helper');
	is($sexit, $exit, 'and both exited on the same code');

	like($err, qr/git commit/, 'and the fix is a command to run');
};

done_testing;
