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
			# scalar, because the last element of a hash constructor is
			# in list context and newest answers its depth and where it
			# read the marker from as well, which would land on every
			# record as a fifth key named after the depth.
			marker  => scalar Genesis::CI::Marker::newest($git, $sha, limit => 1),
		};
	}
	return @commits;
}

# }}}
# require_control - control exists, and it is in step with the remote {{{
#
#   my $state = Genesis::CI::Preflight::require_control($top, $git,
#       refreshed => $result, command => 'propagate');
#
# Returns { divergence => $div, events => \@lines }.
#
# Three cases, and D65 settles all three.  Where the remote has control and
# this clone does not, the refresh has already created the local ref, and the
# creation is reported as an event line rather than passed over in silence.
# Where control exists nowhere, every pipeline command refuses, because the
# environment files live on control and nothing can read the topology without
# it, and no command creates it, since cutting the branch that becomes the
# source of truth is the operator's act.  Where both have it, D30 requires
# in-sync and refuses either way, naming ahead as unpushed and behind as
# stale, because a marker names a control commit by its sha alone and a
# deploy on another machine can only read what the remote has.
#
# on_divergence => 'report' is for `genesis pipeline-status`, which reports
# every state and resolves none.
sub require_control {
	my ($top, $git, %opts) = @_;

	my $control = $top->control_branch;
	my $remote  = $git->default_remote // 'the remote';
	my $action  = $opts{action}  // sprintf('run #C{genesis %s}', $opts{command} // 'propagate');
	my $outcome = $opts{outcome} // 'Nothing was written.';

	my @events;
	push @events, sprintf('created control from %s/%s', $remote, $control)
		if grep {$_ eq $control} @{($opts{refreshed} || {})->{created} || []};

	my $div = $git->resolve_branch($control,
		unverifiable => ($opts{unverifiable} ? 1 : 0));

	bail({exitcode => CONFIG},
		"Refusing to %s.  The control branch #C{%s} exists neither on #C{%s} ".
		"nor locally, and the environment files live on it, so nothing can ".
		"read the topology.  Create it by hand, with the repository scaffold ".
		"for a new repository or as the migration describes for a move to v3, ".
		"push it, then run the command again.  %s",
		$action, $control, $remote, $outcome
	) unless defined $div;

	my $state = {divergence => $div, events => \@events};
	return $state if ($opts{on_divergence} // 'refuse') eq 'report';
	return $state if $div->{state} eq 'in-sync';

	bail({exitcode => DATAERR},
		"Refusing to %s.  The control branch #C{%s} exists here and not on ".
		"#C{%s}, so nothing it holds can be read by a deploy on another ".
		"machine.  Push it with #C{git push -u %s %s}, then run the command ".
		"again.  %s",
		$action, $control, $remote, $remote, $control, $outcome
	) if $div->{state} eq 'no-remote';

	# The number governs the verb in every one of these, because a refusal
	# that reads "by 1 commit, which are unpublished" is read past rather
	# than read.
	my $counts = $div->{state} eq 'diverged'
		? sprintf("is ahead of #C{%s/%s} by %s and behind it by %s, so it is ".
		          "both unpublished and stale",
		          $remote, $control, _commits($div->{ahead}), _commits($div->{behind}))
		: $div->{state} eq 'ahead'
		? sprintf("is ahead of #C{%s/%s} by %s, which %s unpublished.  A ".
		          "propagation marker names a control commit by its sha alone, ".
		          "so a deploy on another machine can read only a commit the ".
		          "remote has",
		          $remote, $control, _commits($div->{ahead}),
		          $div->{ahead} == 1 ? 'is' : 'are')
		: sprintf("is behind #C{%s/%s} by %s, so it is stale and propagating ".
		          "from it would deliver state a teammate has already moved past",
		          $remote, $control, _commits($div->{behind}));

	my $remedy = $div->{state} eq 'behind'
		? sprintf("Rebase it with #C{git pull --rebase %s %s}", $remote, $control)
		: $div->{state} eq 'ahead'
		? sprintf("%s with #C{git push %s %s}",
		          $div->{ahead} == 1 ? 'Push it' : 'Push them', $remote, $control)
		: sprintf("Rebase with #C{git pull --rebase %s %s} and push with ".
		          "#C{git push %s %s}", $remote, $control, $remote, $control);

	bail({exitcode => DATAERR},
		"Refusing to %s.  The control branch #C{%s} %s.  Genesis never moves ".
		"control.  %s, then run the command again.  %s",
		$action, $control, $counts, $remedy, $outcome
	);
}

# }}}
# _commits - "1 commit" or "4 commits", so a count reads as English {{{
sub _commits {
	my ($n) = @_;
	return sprintf('%d commit%s', $n, $n == 1 ? '' : 's');
}

# }}}
1;

# vim: fdm=marker:foldlevel=0:noet
