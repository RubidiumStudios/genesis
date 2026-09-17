package Genesis::BranchClass;

use strict;
use warnings;

use Genesis;
use Genesis::Exit qw/CONFIG DATAERR TEMPFAIL/;

### Branch naming {{{

# artifacts_branch_for - the artifacts branch of a deployment {{{
#
# D63 names it artifacts/<env>/<type>, so it is the deployment slug with one
# fixed prefix in front of it.  It is composed here rather than in Top,
# because nothing writes to it and only this gate reads it.
sub artifacts_branch_for {
	my ($top, $env_name) = @_;
	return 'artifacts/' . $top->branch_for($env_name);
}

# }}}
# classify_branch - which class of branch a name belongs to {{{
#
# Returns one of control, deployment, pr, artifacts, or feature.  The three
# derived classes are computed from the environments the repository knows
# about, because under D66 the branch is per deployment and its name is the
# deployment slug, so there is nothing to pattern-match against.
sub classify_branch {
	my ($top, $branch) = @_;
	return 'feature' unless defined $branch;
	return 'control' if $branch eq $top->control_branch;

	# The names are read once and the three branches are composed from that
	# one list.  pr_branch_for reads the same list again on every call, and
	# the list is rebuilt from the environment files each time it is asked
	# for, so calling it per environment walked the deployment root once per
	# environment to answer one question about one branch.
	#
	# The prefix is joined here rather than through pr_branch_for for that
	# reason alone.  What pr_branch_for adds beyond the join is a refusal of
	# a prefix that collides with a deployment branch or with control, and
	# that refusal belongs to the commands that create the branch, not to a
	# classification that only wants to know what it is looking at.  The
	# artifacts branch still goes through its own composer, which reads the
	# list nowhere and costs nothing.
	my $pr_prefix = $top->pr_prefix;
	for my $env ($top->pipeline_env_names) {
		my $slug = $top->branch_for($env);
		return 'deployment' if $branch eq $slug;
		return 'pr'         if $branch eq $pr_prefix . $slug;
		return 'artifacts'  if $branch eq artifacts_branch_for($top, $env);
	}

	return 'feature';
}

# }}}
# }}}

### The refresh {{{

# refresh_control - bring control from R into T before the ancestry check {{{
#
# D40 has every pipeline command refresh unconditionally and fail loudly at
# pre-flight when it cannot, and it amends D41 so that genesis new refreshes
# control and nothing else, because its ancestry check has to run against R's
# tip.  Only the control branch is named: a deployment branch's tip answers a
# question no pre-deploy command asks, and fetching it was what let the
# branch-exists check read a ref that is now derived.
sub refresh_control {
	my ($top, $git) = @_;

	my $remote = $git->default_remote or return 1;
	my $control = $top->control_branch;

	# A clone that has lost its control branch is the pre-flight's to
	# repair, and it reports the creation as it makes it.  A fetch here
	# would materialise the branch first and silently, so the operator
	# would be told nothing about a ref that appeared under them.  One
	# state, one owner, the same rule that keeps the detached HEAD below
	# out of this assertion.
	return 1 unless $git->branch_exists('refs/heads/' . $control);

	my (undef, $result) = $git->fetch_branches([$control], $remote);
	return 1 if $result->{ok};

	# The result says which class of failure it was, and the three of them
	# ask different things of the operator.  One sentence for all of them
	# told somebody whose credentials had expired to go and check their
	# network.  The kinds are the ones _classify_remote_error fills.
	#
	# Every kind exits TEMPFAIL, which is what fetch_pipeline_envs does
	# with the same three in Genesis::Top.  A remote that will not answer
	# is a condition a re-run fixes once the operator has dealt with it,
	# rather than input they have to correct.
	my $kind = $result->{kind} // 'unknown';
	my ($because, $remedy) =
		  $kind eq 'network' ? (
			'the network or the remote is unreachable',
			'Check the network and try again.'
		) : $kind eq 'auth' ? (
			'the remote rejected our credentials',
			sprintf('Restore your access to #C{%s} and try again.', $remote)
		) : (
			'the remote failed the request',
			'Try again, and read what the remote said below.'
		);

	# The remote's own words come back under err, which is the key
	# fetch_branches fills.  There is no message key, so a caller reading one
	# would print nothing and the operator would be told the fetch failed
	# without being told why.
	bail({exitcode => TEMPFAIL},
		"Could not reach #C{%s} to refresh the #C{%s} branch, because %s.".
		"\n\n".
		"This command reads control's tip to decide whether the branch you ".
		"are on carries every environment, so it cannot run against stale ".
		"refs.  %s\n\n%s",
		$remote, $control, $because, $remedy, $result->{err} // ''
	);
}

# }}}
# }}}

### The pre-deploy assertion {{{

# permitted_feature_branch - the three conditions of D81 {{{
#
# Returns a true first value when all three hold.  Otherwise it returns
# false with the condition that failed and the fix for it, so the caller
# writes one bail and the reasons stay here.  The one option is `adding`,
# the environment name the command is about to create, because a branch may
# collide with a name that does not exist yet.
sub permitted_feature_branch {
	my ($top, $git, $branch, %opts) = @_;

	my $remote = $git->default_remote;
	my $control_ref = $remote
		? 'refs/remotes/' . $remote . '/' . $top->control_branch
		: $top->control_branch;

	# The tip is read off a ref, and a clone that has never fetched control
	# holds none.  Left unchecked, the descent question below is asked of
	# nothing, answered no, and the operator is told to rebase onto a tip
	# that does not exist here.  The refresh above stands aside for a clone
	# with no local control branch, because materialising one is the
	# pre-flight's repair to make and to report, so the ref really can
	# still be missing by now.
	#
	# A missing ref is two states, and they want different exits.  Control
	# may be somewhere and not here, which a fetch fixes, or it may be
	# nowhere at all, which nothing but creating it fixes.
	#
	# resolve_branch answers first, exactly as
	# Genesis::CI::Preflight::require_control asks it, and that is where
	# the twin of the CONFIG sentence below lives.  The two are composed
	# apart because this one is raised before a command names itself, so
	# it carries neither require_control's "Refusing to ..." opening nor
	# its closing sentence about what was written.
	#
	# Where it answers nothing the remote is asked as well, because
	# resolve_branch reads local refs alone and a single-branch clone
	# holds neither ref for a control the remote has.  Told "exists
	# neither" it would be told to create a branch that is already there.
	# Only a remote that lacks control too earns that sentence, and a
	# repository with no remote configured gets it because
	# remote_branch_exists answers 0 for one.  An ls-remote that fails
	# bails in remote_branch_exists' own words, which is left alone: a
	# remote nobody can reach is not a remote that lacks the branch, and
	# the refresh above has already tolerated whatever it was.
	unless ($git->branch_exists($control_ref)) {
		my $named = $remote // 'the remote';
		my $elsewhere = defined $git->resolve_branch($top->control_branch)
			|| $git->remote_branch_exists($top->control_branch, $remote);

		bail({exitcode => CONFIG},
			"The control branch #C{%s} exists neither on #C{%s} nor ".
			"locally, and the environment files live on it, so nothing can ".
			"read the topology.\n\n".
			"Create it by hand, with the repository scaffold for a new ".
			"repository or as the migration describes for a move to v3, ".
			"push it, then run the command again.",
			$top->control_branch, $named
		) unless $elsewhere;

		# Control is here or on the remote, so the remedy is a fetch.
		return (
			0,
			sprintf(
				"#C{%s} has not been fetched from #C{%s}, so there is no ".
				"tip for #C{%s} to be measured against",
				$top->control_branch, $named, $branch
			),
			sprintf(
				"Fetch it, and cut the branch from what arrives:\n\n".
				"    git fetch %s %s\n",
				$named, $top->control_branch
			)
		);
	}

	# It descends from control's tip as observed through T after a refresh,
	# so it carries every environment file control has and a check for an
	# existing environment is sound.  The tip is measured against the branch
	# the caller named rather than against HEAD, because that branch is the
	# one the refusals below speak of and the two are only the same while
	# the caller is asking about the branch it is standing on.
	my $control_tip = $git->sha($control_ref);
	return (
		0,
		sprintf(
			"#C{%s} does not descend from the tip of #C{%s}",
			$branch, $top->control_branch
		),
		sprintf(
			"Rebase it onto the refreshed tip:\n\n    git rebase %s/%s\n",
			$remote // 'origin', $top->control_branch
		)
	) unless $git->is_ancestor($control_tip, $branch);

	# Its name is not an environment's name, existing or being added, since
	# a branch named prod2 occupies refs/heads/prod2 and pipeline-apply
	# could then never create prod2/bosh (D66).
	#
	# The lookup is what finds the collision, and the key it matches on is
	# an environment name, so the name handed to deployment_slug_for comes
	# out of the lookup rather than out of the branch.  The two happen to
	# be the same string in this one case, but the accessor takes an
	# environment name and bugs out on anything else, so it is handed one
	# by name and not by coincidence.
	my %names = map {($_ => 1)} $top->pipeline_env_names;
	$names{$opts{adding}} = 1 if defined($opts{adding}) && length($opts{adding});
	if ($names{$branch}) {
		my $env_name = $branch;
		return (
			0,
			sprintf(
				"#C{%s} is named for an environment, so #C{%s} could never be ".
				"created beside it",
				$branch, $top->deployment_slug_for($env_name)
			),
			sprintf(
				"Rename the feature branch:\n\n    git branch -m %s add-%s\n",
				$branch, $branch
			)
		);
	}

	return (1);
}

# }}}
# assert_pre_deploy - refuse a pre-deploy command off a permitted branch {{{
#
# D81: a pre-deploy command runs on control or on a permitted feature
# branch, refuses elsewhere naming the condition it failed, and switches
# nothing, because the operator chose the branch and the fix is theirs.
sub assert_pre_deploy {
	my ($top, $git, %opts) = @_;

	# The refresh runs above the classification, because the descent
	# condition the class check grows reads the remote-tracking ref, and a
	# stale one answers for a control tip nobody has any more.  It runs on a
	# branch the gate is about to refuse as well as on one it permits, so
	# where a command ends says nothing about whether it refreshed.
	#
	# The caller passes refresh => 0 for the two commands that promise no
	# network call, which are pipeline-status under --no-refresh (D40) and
	# pipeline-describe, which answers from the repository's own files.
	refresh_control($top, $git)
		unless defined($opts{refresh}) && !$opts{refresh};

	# A detached HEAD is neither control nor derived, so it is allowed
	# through here.  The repository that has lost control is the pre-flight's
	# to repair, since it re-creates the branch from the remote, and the
	# clone that never had it is the apply's to refuse at CONFIG.  A refusal
	# raised here would speak before either of them and say less.
	my $branch = $git->current_branch;
	my $class = classify_branch($top, $branch);
	if ($class eq 'control') {
		# D45: where control requires a pull request, a command that
		# commits on control expects a feature branch instead, because a
		# commit made here has no way to reach control through a pull
		# request.  The expectation follows the key that already decides
		# the protection, so there is no second key to set.
		#
		# It is asked of the command and not of the class.  D45 is about
		# a commit, and most pre-deploy commands make none on control:
		# pipeline-apply is the command that applies the very protection
		# this key derives, and refusing it here would leave an operator
		# no way to turn the protection on.  The caller passes commits
		# from the registration, and create is the only command that
		# declares it today.
		bail({exitcode => DATAERR},
			"#C{%s} requires a pull request, so this command expects to run ".
			"on a feature branch.\n\n".
			"#C{pipeline.source_control.control_requires_pr} is set, and the ".
			"branch protection it derives blocks a direct push.  Cut a ".
			"feature branch and open a pull request:\n\n".
			"    git checkout -b add-<something> %s\n",
			$top->control_branch, $top->control_branch
		) if $opts{commits} && $top->control_requires_pr;

		return 1;
	}

	my %derived = (
		deployment => "a deployment branch, which holds what was delivered",
		pr         => "a pull request branch, which a propagate run rewrites",
		artifacts  => "an artifacts branch, which a deploy writes to",
	);

	bail({exitcode => DATAERR},
		"#C{%s} is %s, and this command changes what will be delivered.\n\n".
		"Derived branches never carry a hand commit.  Move to the control ".
		"branch, or to a feature branch cut from it:\n\n".
		"    git checkout %s\n",
		$branch, $derived{$class}, $top->control_branch
	) if exists $derived{$class};

	# The detached HEAD the comment above let through is let through here
	# too.  It is no branch, so neither remedy the predicate offers can be
	# carried out on it, and the two landed behaviours that own the state
	# still speak for it.
	return 1 if !defined($branch) || $branch eq 'HEAD';

	my ($ok, $reason, $remedy) = permitted_feature_branch(
		$top, $git, $branch, adding => $opts{adding}
	);
	return 1 if $ok;

	bail({exitcode => DATAERR},
		"%s, and this command changes what will be delivered.\n\n%s",
		$reason, $remedy
	);
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=0:noet
