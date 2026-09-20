#!perl
#
# Proves T296: no file under lib/, docs/ci, or workplans/ uses the retired
# routing sense of "entry point", while the ordinary meaning of a command's
# CLI entry is left untouched.
#
# D89 retired the term in its routing sense, because it named the output of a
# computation the design removed.  The walk visits every environment and each
# control commit is either delivered or held with a reason, so there is no set
# of environments picked out ahead of the walk for the term to name.
#
# The two senses are told apart by the company the term keeps.  The routing
# sense always travels with the propagation vocabulary, and the ordinary sense
# never does, so a hit counts only when one of the routing words stands within
# three lines of it.  A line that names a command's own entry in a code span
# is allowed outright, which is what keeps the check from banning a word.
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
);

my @files;
File::Find::find({
	no_chdir => 1,
	wanted   => sub {
		return unless -f $File::Find::name;
		return if -B $File::Find::name;
		push @files, ($File::Find::name =~ s{^\./}{}r);
	},
}, 'lib', 'docs/ci', 'workplans');

my @offences;
for my $file (sort @files) {
	open my $fh, '<', $file or next;
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

ok(!@offences, 'no file under lib/, docs/ci, or workplans/ carries the retired routing sense')
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
