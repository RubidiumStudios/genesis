package Harness::Deps;
# Records which of the repository's own files each test really loads.
#
# Loaded through PERL5OPT while GENESIS_TEST_DEPS names a log, so every genesis
# child a test runs loads it too.  At exit, each test file and each genesis
# child appends the files under lib/ and t/ it loaded, tagged with the test
# file it belongs to.  t/bin/affected-tests reads the log to choose the tests
# a change can reach, which a static reading cannot do for the CLI: it loads
# its commands by name at run time.
#
# Only a test file (a name ending in .t) and bin/genesis record anything.
# Every other perl that inherits PERL5OPT loads this and does nothing.
use strict;
use warnings;

use Cwd ();
use Fcntl qw/:flock/;
use File::Basename qw/dirname/;

my $LOG = $ENV{GENESIS_TEST_DEPS};
my $RECORDING = $LOG && $0 =~ m{(?:\.t|/genesis)$};

# The test file a line belongs to; a child inherits it from its test.
$ENV{HARNESS_DEPS_ROOT} //= $0 if $RECORDING;
my $ROOT = $ENV{HARNESS_DEPS_ROOT} // '';

# The repository is where this file sits, two directories up, since a test
# may have changed directory by the time it exits.
my $REPO = dirname(dirname(dirname(Cwd::abs_path(__FILE__))));

END {
	if ($RECORDING) {
		# Each loaded module by the name it was required as, found under lib/
		# or t/ of this repository, so a module that came from elsewhere is
		# never named and a path relative to a directory since left is never
		# trusted.
		my @files = sort grep {defined} map {
			-f "$REPO/lib/$_" ? "lib/$_" : -f "$REPO/t/$_" ? "t/$_" : undef
		} grep {$_ ne 'Harness/Deps.pm'} keys %INC;

		if (@files && open(my $fh, '>>', $LOG)) {
			flock($fh, LOCK_EX);
			print $fh map {"$ROOT\t$_\n"} @files;
			close $fh;
		}
	}
}

1;
