#!perl
#
# Proves T296: no file under bin/, lib/, docs/ci, or workplans/ uses the
# retired routing sense of "entry point", while the ordinary meaning of a
# command's CLI entry is left untouched.
#
# D89 retired the term in its routing sense, because it named the output of a
# computation the design removed.  The walk visits every environment and each
# control commit is either delivered or held with a reason, so there is no set
# of environments picked out ahead of the walk for the term to name.
#
# The two senses are told apart by the company the term keeps.  The routing
# sense always travels with the propagation vocabulary, and the ordinary sense
# never does, so a hit counts only when one of the routing words stands within
# three lines of it.  Five shapes of line are then allowed outright, and they
# are what keeps the check from banning a word.  A line may name a command's
# or a CLI's entry point, or an entry point for, of, or to a name written in
# a code span, or an entry point that something registers, calls, or uses, or
# a primary, secondary, third, single, or top-level entry point.  The fifth
# is a shape rather than a place, and it is a table row whose first cell is
# bold and whose third cell opens on Retired or Superseded, wherever it
# stands under the four roots.  Such a row records a term as retired rather
# than using it, and the only row it matches today is in the workplan's
# superseded terms table.
#
use strict;
use warnings;
use Test::More;

use File::Find;

my $TERM = qr/entry[- ]?points?|entrypoints?/i;

my @ROUTING = (
	qr/prior[_ ]env/i,
	qr/propagat/i,
	qr/cascade/i,
	qr/ancestor/i,
	qr/undeployed/i,
	qr/withheld|withhold/i,
	qr/\bblocked\b/i,
	qr/env branch/i,
	qr/control HEAD/i,
	qr/predecessor/i,
	qr/\bDAG\b/,
	qr/topology/i,
	qr/pipeline section/i,
);

my @ORDINARY = (
	qr/(?:command|CLI)[ -]entry[- ]?point/i,
	qr/entry[- ]?points? (?:for|of|to) (?:the )?[C`]/i,
	qr/entry[- ]?point (?:registered|called by|used by)\b/i,
	qr/(?:primary|secondary|third|single|top-level) entry[- ]?point/i,

	# A table row that records a term as retired or superseded, which is how
	# a document keeps the trail of a term it dropped.  Such a row names the
	# term to say it is gone, so it mentions the sense rather than using it,
	# and without this the one table built to keep the reasoning trail is the
	# one place the trail cannot be written.
	#
	# This is a shape and not a place.  It spares any row under the four
	# roots whose first cell is bold, whose second cell holds no pipe, and
	# whose third cell opens on Retired or Superseded, and the only rows it
	# matches today are in the workplan's superseded terms table.
	qr/^\|\s*\*\*[^|]+\*\*\s*\|[^|]*\|\s*(?:Retired|Superseded)\b/,
);

my @ROOTS = ('bin', 'lib', 'docs/ci', 'workplans');

# A root that is missing narrows the sweep without saying so, because the
# other three still fill the list and the walk only warns on standard error.
# Each one is asked for by name, so a root that moves or is renamed stops the
# run rather than quietly shrinking what it reads.
for my $root (@ROOTS) {
	BAIL_OUT("root $root is missing") unless -d $root;
}

my @files;
File::Find::find({
	no_chdir => 1,
	wanted   => sub {
		return unless -f $File::Find::name;
		return if -B $File::Find::name;
		push @files, $File::Find::name;
	},
}, @ROOTS);

# A run from anywhere but the repository root reads nothing and passes, which
# is a green that proves nothing.  pod-complete.t guards its own walk the same
# way.
BAIL_OUT("no files found under " . join(', ', @ROOTS)) unless @files;

my @offences;
for my $file (sort @files) {
	# A file that will not open is an ordinary failure of this check alone,
	# so it fails here and the sweep carries on.  The guards above earn
	# their BAIL_OUT, because a walk that stood in the wrong place makes
	# every later result in the run suspect.
	my $fh;
	unless (open $fh, '<', $file) {
		fail("$file could not be read: $!");
		next;
	}
	my @lines = <$fh>;
	close $fh;

	for my $i (0 .. $#lines) {
		next unless $lines[$i] =~ $TERM;
		next if grep {$lines[$i] =~ $_} @ORDINARY;

		my $from = $i - 3 < 0 ? 0 : $i - 3;
		my $to   = $i + 3 > $#lines ? $#lines : $i + 3;
		my $window = join('', @lines[$from .. $to]);
		next unless grep {$window =~ $_} @ROUTING;

		push @offences, {
			file => $file,
			line => $i + 1,
			text => ($lines[$i] =~ s/^\s+|\s+$//gr),
		};
	}
}

ok(!@offences, 'no file under bin/, lib/, docs/ci, or workplans/ carries the retired routing sense')
	or diag(
		sprintf("Found %d line(s) using the retired routing sense.\n", scalar @offences) .
		"The term named the output of a computation the design removed.  The\n" .
		"walk visits every environment and each control commit is delivered or\n" .
		"held with a reason, so write what the line means: delivered without an\n" .
		"ancestor hold, or an environment with no prior_env.\n\n" .
		join("\n", map {sprintf("  %s:%d\n      %s", $_->{file}, $_->{line}, $_->{text})} @offences)
	);

done_testing();
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
