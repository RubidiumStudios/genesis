package Genesis::BranchClass;

use strict;
use warnings;

use Genesis;
use Genesis::Exit;

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

	for my $env ($top->pipeline_env_names) {
		return 'deployment' if $branch eq $top->branch_for($env);
		return 'pr'         if $branch eq $top->pr_branch_for($env);
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

	# The remote's own words come back under err, which is the key
	# fetch_branches fills.  There is no message key, so a caller reading one
	# would print nothing and the operator would be told the fetch failed
	# without being told why.
	bail({exitcode => Genesis::Exit::TEMPFAIL()},
		"Could not reach #C{%s} to refresh the #C{%s} branch.\n\n".
		"This command reads control's tip to decide whether the branch you ".
		"are on carries every environment, so it cannot run against stale ".
		"refs.  Check the network and try again.\n\n%s",
		$remote, $control, $result->{err} // ''
	);
}

# }}}
# }}}

### The pre-deploy assertion {{{

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
	# The caller passes refresh => 0 for the one command that promises no
	# network call, which is pipeline-status under --no-refresh (D40).
	refresh_control($top, $git)
		unless defined($opts{refresh}) && !$opts{refresh};

	# A detached HEAD is neither control nor derived, so it is allowed
	# through here.  The repository that has lost control is the pre-flight's
	# to repair, since it re-creates the branch from the remote, and the
	# clone that never had it is the apply's to refuse at CONFIG.  A refusal
	# raised here would speak before either of them and say less.
	my $branch = $git->current_branch;
	my $class = classify_branch($top, $branch);
	return 1 if $class eq 'control';

	my %derived = (
		deployment => "a deployment branch, which holds what was delivered",
		pr         => "a pull request branch, which a propagate run rewrites",
		artifacts  => "an artifacts branch, which a deploy writes to",
	);

	bail({exitcode => Genesis::Exit::DATAERR()},
		"#C{%s} is %s, and this command changes what will be delivered.\n\n".
		"Derived branches never carry a hand commit.  Move to the control ".
		"branch, or to a feature branch cut from it:\n\n".
		"    git checkout %s\n",
		$branch, $derived{$class}, $top->control_branch
	) if exists $derived{$class};

	return 1;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=0:noet
