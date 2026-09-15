package Genesis::CI::Marker;

use strict;
use warnings;

use Genesis qw/bug run/;

# The propagation marker, in one place.  D34 fixes it as the subject
# "[pipeline] control@<sha> -> <env>" on a deployment-branch commit, naming
# the control commit the branch now holds and the receiving environment, and
# the routing contract's provenance rules make it the only claim a branch
# makes about what it carries.  Everything that writes or reads that string
# goes through this module.
our $PREFIX = '[pipeline] control@';

# build - render the marker subject for one delivery {{{
#
# The sha is written exactly as it is handed over, because only the caller
# has a git handle and knows which abbreviation git resolved for it, and the
# environment is its own name rather than the deployment slug, which is the
# fourth provenance rule under D66.
sub build {
	my ($control_sha, $env) = @_;

	bug("Genesis::CI::Marker::build needs a control sha, got %s",
		defined $control_sha ? "'$control_sha'" : 'undef')
		unless defined $control_sha && $control_sha =~ /^[0-9a-f]{4,40}$/;
	bug("Genesis::CI::Marker::build needs an environment name")
		unless defined $env && length $env;

	return sprintf('%s%s -> %s', $PREFIX, $control_sha, $env);
}

# }}}
# in_text - the control shas the markers in one commit message name {{{
#
# The one regex.  It anchors to the start of a line, so a subject that
# mentions a short sha in passing can never match, which is the coincidental
# half of H7, and it runs over a whole message rather than a subject, so a
# squash merge that pushed the marker into the body still answers, which is
# D49.  One list bullet may stand between the anchor and the prefix, because
# a squash that collects several commit subjects writes each of them as a
# bulleted line and the marker is still the marker with a bullet in front of
# it.  The literal prefix rather than the anchor is what defeats a
# coincidental short sha, so the bullet costs nothing.
#
# A sha comes back exactly as its marker carries it, because only a caller
# with a git handle can resolve an abbreviation.  In list context every
# marker in the text answers, in the order the text lists them, which is what
# lets a caller holding that handle weigh several against each other; in
# scalar context the first one does.
sub in_text {
	my ($text) = @_;
	return wantarray ? () : undef unless defined $text;

	my @written;
	while ($text =~ /^[ \t]*(?:[-*][ \t]+)?\Q$PREFIX\E([0-9a-f]{4,40})\b/mg) {
		push @written, $1;
	}
	return wantarray ? @written : $written[0];
}

# }}}
# newest - the control commit the ref's newest marker names {{{
#
# Walks the ref newest first and returns the control commit of the first
# marker it meets, skipping every commit above it that carries none, which is
# D33's hand-commit skip: a hotfix pushed onto a deployment branch is legal
# and temporary, and it must not move what the branch is certified to hold.
# There is no fallback to a control tip.  A branch with no marker anywhere
# has been delivered nothing, and saying so is the point.
#
# In list context the walk also reports the number of markerless commits it
# passed, which is what the propagate base warns about, and where the answer
# came from.
sub newest {
	my ($git, $ref, %opts) = @_;

	# A cap of nothing caps the walk at nothing, so there is no commit to
	# read and no marker to find.  The guard asks whether the caller set a
	# cap rather than whether the cap is true, because a caller that said
	# zero meant zero and a truth test hands it an uncapped walk instead.
	return wantarray ? (undef, 0, undef) : undef
		if defined $opts{limit} && $opts{limit} < 1;

	my @records = $git->log_subjects($ref,
		body => 1,
		(defined $opts{limit} ? (limit => $opts{limit}) : ()),
		($opts{paths} ? (paths => $opts{paths}) : ()),
	);

	my $depth = 0;
	for my $record (@records) {
		my @written = in_text($record->{message});
		unless (@written) {
			$depth++;
			next;
		}
		my $sha = _newest_of($git, @written);
		return wantarray ? ($sha, $depth, 'branch') : $sha;
	}

	return wantarray ? (undef, $depth, undef) : undef;
}

# }}}
# _newest_of - the newest of the markers one message carries {{{
#
# A squash leaves every delivery's marker in one message, and the two tools
# that write those messages disagree about the order.  Git's own squash lists
# the newest commit first and indents each subject, and GitHub's lists the
# newest last and bullets each subject, so where a marker sits in the text
# says nothing about how new it is.  The markers are weighed by ancestry
# instead, which is a question this repository can answer because the reader
# holds a git handle, and a marker whose commit the repository cannot reach
# simply never displaces one it can.  Where nothing can be weighed the first
# marker stands, which is the order the text gave.
sub _newest_of {
	my ($git, @written) = @_;

	my @resolved = map {_resolved($git, $_)} @written;
	my $newest = shift @resolved;
	for my $candidate (@resolved) {
		next if $candidate eq $newest;
		$newest = $candidate if $git->is_ancestor($newest, $candidate);
	}
	return $newest;
}
# }}}

# The two trailers D49 gives a control commit, and the keys we answer them
# under.  Genesis-Stage makes the commit a gate and carries the reason, whose
# hold form reads "hold: <reason>", and Genesis-Release-Stage releases a gate
# by naming its control commit.
my %TRAILERS = (
	stage         => 'Genesis-Stage',
	release_stage => 'Genesis-Release-Stage',
);

# trailers - the two Genesis trailers one commit carries {{{
#
# Git parses the trailer block, through the %(trailers) format atom, so the
# rules about where a trailer may sit and how a folded value unfolds stay
# git's rather than becoming ours.  Only the keys the commit actually carries
# come back, so a commit carrying neither gives an empty hashref, and what
# the value means is left to the walk that acts on it.
sub trailers {
	my ($git, $commit) = @_;

	my %found;
	for my $key (sort keys %TRAILERS) {
		my ($value) = $git->log_subjects($commit,
			limit  => 1,
			format => sprintf('%%(trailers:key=%s,valueonly,unfold,separator=%%x2c)',
				$TRAILERS{$key}),
		);
		next unless defined $value;
		$value =~ s/\A\s+//;
		$value =~ s/\s+\z//;
		next unless length $value;
		$found{$key} = $value;
	}

	return \%found;
}

# }}}
# _resolved - expand a marker's sha where this repository holds the commit {{{
#
# A marker is meaningful only where its commit is fetchable, which is the
# seventh provenance rule, and a repository that cannot reach it yet still
# has to hand the caller what the marker actually says.
#
# The question is asked of rev-parse rather than of Service::Git's sha,
# because sha echoes an abbreviation this repository cannot reach straight
# back with git's complaint on stderr, and the answer wanted here is whether
# the commit is present at all.
sub _resolved {
	my ($git, $written) = @_;

	my ($full, $rc) = run({dir => $git->root, passfail => 0},
		'git', 'rev-parse', '--verify', '--quiet', "$written^{commit}");
	return $written if $rc;
	chomp $full if defined $full;
	return $written unless defined $full && $full =~ /^[0-9a-f]{40}$/;
	return $full;
}

# }}}

1;
