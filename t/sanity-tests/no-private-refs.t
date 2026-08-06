#!perl
#
# Guards against references to private, non-public resources reaching this
# repository -- issue-tracker identifiers, internal URLs, and the like.
#
# Genesis is public.  A reference to something only the authoring team can
# open hands a reader a dead end in place of the explanation they needed, so
# the remedy is never to delete the sentence: write down what the reference
# was standing in for -- the defect, the regression a test guards, the reason
# the code is shaped the way it is -- and drop the identifier.
#
# The patterns themselves are deliberately NOT held here.  Publishing the
# shape of an organisation's internal identifiers in the repository the check
# protects would defeat the point of the check.  They are supplied at run
# time:
#
#   GENESIS_PRIVATE_REF_PATTERNS   newline-separated Perl regexes.
#                                  Blank lines and #-comments are ignored.
#                                  Case sensitivity is the pattern's own
#                                  business -- use (?i) where wanted, and
#                                  leave it off where a lowercase spelling
#                                  is legitimate vocabulary elsewhere in
#                                  the tree.
#
# Unset, the check skips.  That is intentional: an outside contributor has
# no such resources to leak and should not be made to configure anything.
# In our own pipeline the value is credential-backed, so a missing value
# fails the task rather than quietly skipping this.
#
use strict;
use warnings;
use Test::More;

my $raw = $ENV{GENESIS_PRIVATE_REF_PATTERNS};
plan skip_all => 'GENESIS_PRIVATE_REF_PATTERNS not set -- nothing to check against'
	unless defined($raw) && $raw =~ /\S/;

my @patterns;
for my $line (split /\n/, $raw) {
	$line =~ s/^\s+|\s+$//g;
	next if $line eq '' || $line =~ /^#/;
	my $re = eval { qr/$line/ };
	if ($@) {
		fail("pattern '$line' does not compile");
		diag($@);
		next;
	}
	push @patterns, { src => $line, re => $re };
}

plan skip_all => 'GENESIS_PRIVATE_REF_PATTERNS held no usable patterns'
	unless @patterns;

# The index is exactly the set of files that ship, and excludes build output,
# editor droppings and anything else untracked.
my @files = grep { length } split /\n/, `git ls-files 2>/dev/null`;
unless (@files) {
	require File::Find;
	my @found;
	File::Find::find({
		no_chdir => 1,
		wanted   => sub {
			return if $File::Find::name =~ m{(^|/)\.git(/|$)};
			push @found, $File::Find::name if -f $File::Find::name;
		},
	}, '.');
	@files = map { s{^\./}{}r } @found;
}

# This file names the variable and would otherwise match any pattern written
# to catch the variable's own documentation.  Nothing else is exempt.
my $self = __FILE__ =~ s{^\./}{}r;

my @offences;
for my $file (@files) {
	next if $file eq $self;
	next unless -f $file;
	next if -B $file;

	open my $fh, '<', $file or next;
	my $lineno = 0;
	while (defined(my $line = <$fh>)) {
		$lineno++;
		for my $p (@patterns) {
			next unless $line =~ $p->{re};
			push @offences, {
				file => $file,
				line => $lineno,
				text => ($line =~ s/^\s+|\s+$//gr),
			};
		}
	}
	close $fh;
}

ok(!@offences, 'no references to private resources in the source tree')
	or diag(
		sprintf("Found %d reference(s) to private resources.\n", scalar @offences) .
		"This repository is public.  Replace each one with what it was\n" .
		"standing in for, then remove the identifier.\n\n" .
		join("\n", map { sprintf("  %s:%d\n      %s", $_->{file}, $_->{line}, $_->{text}) } @offences)
	);

done_testing();
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
