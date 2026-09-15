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
	# The remote's own name and the words that stand in for it are kept apart,
	# because a repository with no remote configured has no name to print and
	# the words belong in prose rather than inside a command the operator is
	# told to run.
	my $remote  = $git->default_remote;
	my $named   = $remote // 'the remote';
	my $action  = $opts{action}  // sprintf('run #C{genesis %s}', $opts{command} // 'propagate');
	my $outcome = $opts{outcome} // 'Nothing was written.';

	my @events;
	push @events, sprintf('created control from %s/%s', $named, $control)
		if grep {$_ eq $control} @{($opts{refreshed} || {})->{created} || []};

	my $div = $git->resolve_branch($control,
		unverifiable => ($opts{unverifiable} ? 1 : 0));

	bail({exitcode => CONFIG},
		"Refusing to %s.  The control branch #C{%s} exists neither on #C{%s} ".
		"nor locally, and the environment files live on it, so nothing can ".
		"read the topology.  Create it by hand, with the repository scaffold ".
		"for a new repository or as the migration describes for a move to v3, ".
		"push it, then run the command again.  %s",
		$action, $control, $named, $outcome
	) unless defined $div;

	my $state = {divergence => $div, events => \@events};
	return $state if ($opts{on_divergence} // 'refuse') eq 'report';
	return $state if $div->{state} eq 'in-sync';

	if ($div->{state} eq 'no-remote') {
		# A repository with no remote configured has nothing to name in a push,
		# so the remedy asks for the remote first rather than printing a command
		# with prose standing where the remote's name should be.
		my $publish = defined $remote
			? sprintf("Push it with #C{git push -u %s %s}", $remote, $control)
			: "Give the repository a remote and push it there";
		bail({exitcode => DATAERR},
			"Refusing to %s.  The control branch #C{%s} exists here and not on ".
			"#C{%s}, so nothing it holds can be read by a deploy on another ".
			"machine.  %s, then run the command again.  %s",
			$action, $control, $named, $publish, $outcome
		);
	}

	# The remote has control and this clone does not, which is the one case
	# D65 asks the refresh to close by writing the local ref.  The refresh gives
	# the branch the working tree stands on the tracking refspec and nothing
	# else, so a tree standing on an unborn control leaves the ref unwritten and
	# the query answers here.  The refusal says the creation did not happen,
	# rather than reading a staleness out of two counts that are both zero.
	bail({exitcode => DATAERR},
		"Refusing to %s.  The control branch #C{%s} is on #C{%s/%s} and not in ".
		"this clone.  The refresh writes the local ref for a branch the remote ".
		"has and this clone lacks, so something stopped it here, and a working ".
		"tree standing on #C{%s} with no commit on it is what usually does.  ".
		"Write the ref with #C{git checkout -B %s %s/%s}, then run the command ".
		"again.  %s",
		$action, $control, $named, $control, $control, $control, $named, $control,
		$outcome
	) if $div->{state} eq 'no-local';

	# The number governs the verb in every one of these, because a refusal
	# that reads "by 1 commit, which are unpublished" is read past rather
	# than read.
	my $counts = $div->{state} eq 'diverged'
		? sprintf("is ahead of #C{%s/%s} by %s and behind it by %s, so it is ".
		          "both unpublished and stale",
		          $named, $control, _commits($div->{ahead}), _commits($div->{behind}))
		: $div->{state} eq 'ahead'
		? sprintf("is ahead of #C{%s/%s} by %s, which %s unpublished.  A ".
		          "propagation marker names a control commit by its sha alone, ".
		          "so a deploy on another machine can read only a commit the ".
		          "remote has",
		          $named, $control, _commits($div->{ahead}),
		          $div->{ahead} == 1 ? 'is' : 'are')
		: sprintf("is behind #C{%s/%s} by %s, so it is stale and propagating ".
		          "from it would deliver state a teammate has already moved past",
		          $named, $control, _commits($div->{behind}));

	# Every arm below names the remote inside a command, and every one of them
	# is reached only through a tracking ref, which no repository has without a
	# remote to have written it, so the remote is named here and not stood in
	# for.
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
# initial_state - the whole first stage of a propagation run {{{
#
#   my $state = Genesis::CI::Preflight::initial_state($top, $git,
#       envs => \@scope, refreshed => $result, control => $control_state);
#
# Runs in the order the design fixes.  The refresh has already happened and
# control is already settled when the caller passes them in.  Then every
# deployment branch in scope is classified, every refusal is collected before
# anything is written, and only after that does the run touch a ref.  A
# violation is an illegal initial state under D96, so the run stops before it
# writes and the refusal states the corrective measure beside the branch.
#
# The whole DAG is classified rather than the cascade's scope, because the
# initial state is a property of the repository rather than of the run: a
# hand-made branch anywhere in the pipeline is a defect the operator should
# hear about before any run writes anything.
#
# Returns:
#
#   { refreshed => 1,
#     control   => $div,
#     branches  => { $env => { branch, state, ahead, behind, reset,
#                              fast_forwarded } },
#     events    => \@lines }
sub initial_state {
	my ($top, $git, %opts) = @_;

	my %pass = map {$_ => $opts{$_}} grep {defined $opts{$_}}
		qw/command action outcome/;

	my $refreshed = $opts{refreshed} // $top->fetch_pipeline_envs($git, %pass);
	my $control   = $opts{control}
		// require_control($top, $git, refreshed => $refreshed, %pass);

	my $state = {
		refreshed => 1,
		control   => $control->{divergence},
		branches  => {},
		events    => [@{$control->{events}}],
	};

	my $remote  = $git->default_remote // 'the remote';
	# The act the refusal opens with, spelled the way require_control spells
	# it, so every refusal this stage raises names the run the same way.
	my $action  = $opts{action}  // sprintf('run #C{genesis %s}', $opts{command} // 'propagate');
	my $outcome = $opts{outcome} // 'Nothing was written.';

	my (@local_only, @unrelated);
	for my $env (@{$opts{envs} // []}) {
		my $branch = $top->branch_for($env);
		my $div    = $git->resolve_branch($branch);

		# Neither side has it: the environment is awaiting pipeline-apply
		# under D43, which is the walk's outcome and not a refusal here.
		next unless defined $div;

		$state->{branches}{$env} = {
			branch         => $branch,
			state          => $div->{state},
			ahead          => $div->{ahead},
			behind         => $div->{behind},
			reset          => 0,
			fast_forwarded => 0,
		};

		# The refusal below is correct and the creation guard further down
		# genesis propagate is what changes: _create_missing_branches still
		# makes a deployment branch through prepare_branch and never
		# publishes it, which is exactly the shape refused here.  The guard
		# retires with prepare_branch, and until it does this stage runs
		# ahead of it and pushes nothing the guard made.
		push(@local_only, {env => $env, branch => $branch}), next
			if $div->{state} eq 'no-remote';
		push @unrelated, $branch
			unless _shares_history($git, $branch, $remote);
	}

	# Both refusals hand a composed string to a '%s' format, because bail
	# reads its argument as a format and a commit subject can carry a
	# percent sign.
	bail({exitcode => DATAERR}, '%s',
		_local_only_refusal($action, $outcome, $remote, \@local_only))
		if @local_only;

	bail({exitcode => DATAERR}, '%s',
		_unrelated_refusal($action, $outcome, $remote, \@unrelated))
		if @unrelated;

	return $state;
}

# }}}
# _shares_history - has this branch a commit in common with its counterpart {{{
#
# Asked through run with passfail on and stderr off rather than through
# Service::Git::merge_base, which folds git's stderr into the value it
# answers with.  A ref that is not there makes merge-base print to stderr and
# exit non-zero, and a folded message is a truthy string, so the stage would
# read a missing ref as a shared ancestor and let the branch through.  The
# status is the whole answer here, and both of the states that answer no,
# which are a pair with no common commit and a ref this clone cannot resolve,
# are states this stage refuses rather than passes over.
sub _shares_history {
	my ($git, $branch, $remote) = @_;
	return run({dir => $git->root, passfail => 1, stderr => 0},
		'git', 'merge-base', "refs/heads/$branch",
		"refs/remotes/$remote/$branch") ? 1 : 0;
}

# }}}
# _local_only_refusal - D48's text for a branch the remote has never had {{{
#
# One paragraph per branch, so the single-branch case reads exactly as the
# design quotes it and a run with several names them all.  M13 raises the
# same two texts in their deploy form, which is why the act and the closing
# sentence are arguments.
sub _local_only_refusal {
	my ($action, $outcome, $remote, $offenders) = @_;
	return sprintf("Refusing to %s.  %s  %s", $action,
		join('  ', map {
			sprintf(
				"The local branch #C{%s} has no counterpart on #C{%s}.  A ".
				"deployment branch is derived from control and never ".
				"originates locally, so this branch is a legacy checkout or ".
				"was created by hand.  Genesis deletes nothing.  Inspect the ".
				"branch for anything that should live on control and move it ".
				"there through a commit or a pull request, then delete the ".
				"branch with #C{git branch -D %s}, then run ".
				"#C{genesis pipeline-apply} if the environment #C{%s} is meant ".
				"to exist.",
				$_->{branch}, $remote, $_->{branch}, $_->{env})
		} @$offenders),
		$outcome);
}

# }}}
# _unrelated_refusal - D48's text for a branch that shares no ancestor {{{
sub _unrelated_refusal {
	my ($action, $outcome, $remote, $branches) = @_;
	return sprintf("Refusing to %s.  %s  %s", $action,
		join('  ', map {
			sprintf(
				"The local branch #C{%s} shares no ancestor with #C{%s/%s}, ".
				"which #C{pipeline-apply} created.  The marker-only reset ".
				"never applies across unrelated histories, whatever the local ".
				"commits carry, and Genesis deletes nothing.  Inspect the ".
				"local branch for anything that should live on control and ".
				"move it there through a commit or a pull request, then delete ".
				"the local branch with #C{git branch -D %s}, then run ".
				"#C{genesis propagate} again.",
				$_, $remote, $_, $_)
		} @$branches),
		$outcome);
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
