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

# The two trailers D49 gives a control commit, and the keys we answer them
# under.  Genesis-Stage makes the commit a gate and carries the reason, whose
# hold form reads "hold: <reason>", and Genesis-Release-Stage releases a gate
# by naming its control commit.  It sits here beside the prefix, because both
# are module-level constants and a reader of this file looks for them in one
# place.
my %TRAILERS = (
	stage         => 'Genesis-Stage',
	release_stage => 'Genesis-Release-Stage',
);

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
#
# A caller that names an environment is answered by the markers addressed to
# that environment alone.  The name is the marker's own second half, so the
# one regex reads it rather than a second regex reading it afterwards, and a
# caller that names nothing gets the pattern it has always got.
sub in_text {
	my ($text, $env) = @_;
	return wantarray ? () : undef unless defined $text;

	my $tail = defined $env ? qr/[ \t]+->[ \t]+\Q$env\E[ \t]*$/ : qr/\b/;

	my @written;
	while ($text =~ /^[ \t]*(?:[-*][ \t]+)?\Q$PREFIX\E([0-9a-f]{4,40})$tail/mg) {
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
#
# D52's recovery is the one arm that answers from anywhere but the ref, and
# it stands at the end of the walk so the branch is always asked first.
sub newest {
	my ($git, $ref, %opts) = @_;

	# A cap of nothing caps the walk at nothing, so there is no commit to
	# read and no marker to find.  The guard asks whether the caller set a
	# cap rather than whether the cap is true, because a caller that said
	# zero meant zero and a truth test hands it an uncapped walk instead.
	#
	# It skips the walk rather than leaving the sub, because a branch the
	# reader never read says no marker exactly as loudly as one it read to
	# the root, and D52's recovery answers for the two of them alike.  A
	# recovery that turned on how far the caller let the walk read would be
	# a recovery about the caller rather than about the branch.
	my $walk = !(defined $opts{limit} && $opts{limit} < 1);

	my @records = $walk ? $git->log_subjects($ref,
		body => 1,
		(defined $opts{limit} ? (limit => $opts{limit}) : ()),
		($opts{paths} ? (paths => $opts{paths}) : ()),
	) : ();

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

	# D52's recovery.  Where a site could not grant the rebase-only merge
	# method, a squash can rewrite the aggregate's one commit and take the
	# marker with it, and the pull request's body still carries what Genesis
	# itself wrote there.  The branch always answers first, so this arm is
	# reached only on a branch that says nothing at all.  A body is weighed
	# exactly as a commit message is, because a squash of several deliveries
	# leaves several markers in the body too.
	#
	# A body is also the one place the reader takes a marker from that is
	# not a commit on the environment's own branch, and a person may edit it
	# after Genesis wrote it.  A caller that names the environment it is
	# asking about is therefore answered by the markers addressed to that
	# environment alone.
	if (defined $opts{recover_from}) {
		my @written = in_text($opts{recover_from}, $opts{env});
		if (@written) {
			my $sha = _newest_of($git, @written);
			return wantarray ? ($sha, $depth, 'pull-request') : $sha;
		}
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
# holds a git handle.
#
# A marker whose commit the repository cannot reach is set aside before the
# weighing rather than during it.  Every ancestry question asked of such a
# sha fails, so a marker left in the comparison and reached first would hold
# the answer and lose each question that followed, and no reachable marker
# under it could ever take the answer back.  Where none of them can be
# reached the first marker stands, which is the order the text gave.
sub _newest_of {
	my ($git, @written) = @_;

	my (@reachable, @unreachable);
	for my $written (@written) {
		my ($sha, $reached) = _resolved($git, $written);
		push @{$reached ? \@reachable : \@unreachable}, $sha;
	}
	return $unreachable[0] unless @reachable;

	my $newest = shift @reachable;
	for my $candidate (@reachable) {
		next if $candidate eq $newest;
		$newest = $candidate if $git->is_ancestor($newest, $candidate);
	}
	return $newest;
}
# }}}

# trailers - the two Genesis trailers one commit carries {{{
#
# Git parses the trailer block, through the %(trailers) format atom, so the
# rules about where a trailer may sit and how a folded value unfolds stay
# git's rather than becoming ours.  One format string carries both keys, with
# a separator of our own between the fields, so git still does every piece of
# key matching and a walk that reads a commit forks git once rather than once
# per key.
#
# Each key is asked for twice, once for the key and once for the value.  The
# value atom prints nothing at all for a trailer written with no reason after
# it, and that is byte for byte what an absent trailer prints, so the key
# atom is what tells presence from absence.  A gate somebody set and left
# blank therefore comes back present and empty rather than vanishing, and the
# caller can refuse it instead of failing open.
#
# The read goes through run rather than through log_subjects, because run
# merges stderr into its output by default and hands back no return code
# there.  A commit this repository cannot resolve would then make git's fatal
# complaint the value of every key, inventing a gate out of an error message.
sub trailers {
	my ($git, $commit) = @_;

	my @keys = sort keys %TRAILERS;
	my $format = join('%x1f', map {(
		sprintf('%%(trailers:key=%s,keyonly,separator=%%x2c)', $TRAILERS{$_}),
		sprintf('%%(trailers:key=%s,valueonly,unfold,separator=%%x2c)', $TRAILERS{$_}),
	)} @keys);

	my ($out, $rc) = run({dir => $git->root, passfail => 0, stderr => 0},
		'git', 'log', '-1', "--format=$format", $commit);
	return {} if $rc || !defined $out;

	# The limit of -1 keeps the trailing empty fields, which Perl drops
	# otherwise, and a commit carrying neither trailer is nothing else.
	my @fields = split /\x1f/, $out, -1;

	my %found;
	for my $i (0 .. $#keys) {
		my ($key, $value) = @fields[2 * $i, 2 * $i + 1];
		next unless defined $key && length $key;
		$value = '' unless defined $value;
		$value =~ s/\A\s+//;
		$value =~ s/\s+\z//;
		$found{$keys[$i]} = $value;
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
#
# That answer is worth more than the sha to a caller weighing several markers
# against each other, because an unreachable sha can be weighed against
# nothing, so list context hands the reach back beside the sha.
sub _resolved {
	my ($git, $written) = @_;

	my ($full, $rc) = run({dir => $git->root, passfail => 0},
		'git', 'rev-parse', '--verify', '--quiet', "$written^{commit}");
	chomp $full if defined $full;
	my $reached = !$rc && defined $full && $full =~ /^[0-9a-f]{40}$/ ? 1 : 0;

	my $sha = $reached ? $full : $written;
	return wantarray ? ($sha, $reached) : $sha;
}

# }}}

1;
