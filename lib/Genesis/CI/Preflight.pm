package Genesis::CI::Preflight;
# The propagate run's first stage under D96, which settles what the run is
# allowed to find before it writes anything.  Everything here reads the
# refresh and the divergence query and refuses; the one thing it writes is
# the reset D32 permits, and the fast-forward D5 permits.
use strict;
use warnings;

use Genesis;
use Genesis::CI::Marker;

# The three codes D97 gives this stage's refusals to spend.  They are
# imported rather than named in full, because Genesis::Exit exports nothing
# by default and a fully qualified constant in a package nobody has loaded
# is a bareword that dies where it stands.
use Genesis::Exit qw/CONFIG DATAERR TEMPFAIL/;

# local_only_commits - the commits a branch holds and no remote has {{{
#
#   my @commits = Genesis::CI::Preflight::local_only_commits($git, $branch);
#
# Runs `git log <branch> --not --remotes`, which is the query FWT-963 named
# and which must run before any prune, since a prune deletes the very
# tracking refs it reads.  Each commit comes back as
#
#   { sha => $sha, short => $short, subject => $subject, marker => $control }
#
# where marker is the control commit that commit's marker names, or undef
# for a hand edit.  One commit is classified by asking the marker reader for
# the newest marker within a walk of one, so this module carries no second
# reader of its own.
sub local_only_commits {
	my ($git, $branch) = @_;

	my ($out) = run({dir => $git->root, onfailure => "Failed to list local-only commits on '$branch'"},
		'git', 'log', '--format=%H%x00%h%x00%s', $branch, '--not', '--remotes');

	my @commits;
	for my $line (grep { /\S/ } split /\n/, ($out // '')) {
		my ($sha, $short, $subject) = split /\0/, $line, 3;
		push @commits, {
			sha     => $sha,
			short   => $short,
			subject => $subject // '',
			marker  => Genesis::CI::Marker::newest($git, $sha, limit => 1),
		};
	}
	return @commits;
}

# }}}
1;

# vim: fdm=marker:foldlevel=0:noet
