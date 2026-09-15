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
# in_text - the control sha of the newest marker in one commit message {{{
#
# The one regex.  It anchors to the start of a line, so a subject that
# mentions a short sha in passing can never match, which is the coincidental
# half of H7, and it runs over a whole message rather than a subject, so a
# squash merge that pushed the marker into the body still answers, which is
# D49.  The sha comes back exactly as the marker carries it, because only a
# caller with a git handle can resolve an abbreviation.
sub in_text {
	my ($text) = @_;
	return undef unless defined $text;
	return $1 if $text =~ /^[ \t]*\Q$PREFIX\E([0-9a-f]{4,40})\b/m;
	return undef;
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

	my @records = $git->log_subjects($ref,
		body => 1,
		($opts{limit} ? (limit => $opts{limit}) : ()),
		($opts{paths} ? (paths => $opts{paths}) : ()),
	);

	my $depth = 0;
	for my $record (@records) {
		my $written = in_text($record->{message});
		unless (defined $written) {
			$depth++;
			next;
		}
		my $sha = _resolved($git, $written);
		return wantarray ? ($sha, $depth, 'branch') : $sha;
	}

	return wantarray ? (undef, $depth, undef) : undef;
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
