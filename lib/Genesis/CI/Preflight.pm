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
use Genesis::Exit qw/ABORTED CONFIG DATAERR NOPERM TEMPFAIL/;

# The gate below asks the operator a question, and the two modules that own
# asking are imported by the names it calls rather than in full, so the
# terminal read can be localised by a row that has no terminal to offer.
use Genesis::Term qw/in_controlling_terminal/;
use Genesis::UI qw/prompt_for_boolean prompt_for_line/;

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

	# D44's preview refuses nothing it can warn about instead, so a caller
	# that is only going to report says so here.  A control branch that is
	# ahead of its remote is the one divergence a preview can still answer,
	# because everything the preview reads is on control itself and all the
	# push settles is whether another machine could resolve the markers a
	# real run would write.  Staleness is not like that, so behind and
	# diverged are refused here as they are for a run that writes.
	return $state if $opts{permit_ahead} && $div->{state} eq 'ahead';

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
# assert_not_disowned - refuse, or warn about, a disowned pipeline {{{
#
#   my $applied = Genesis::CI::Preflight::assert_not_disowned($top,
#       command => "$env_name deploy", outcome => 'Nothing was deployed.',
#       locally => 'warn');
#
# D64: where pipeline-apply has left an applied record while pipeline.enabled
# reads false, the configuration disowns a pipeline that is still live, still
# watching its branches, and still deploying.  The check needs the record and
# not just the key, because a repository that never had a pipeline has
# neither and is not disowning anything: it falls through to the pre-flight,
# which has its own words for a repository with no pipeline at all.
#
# Two callers want the same state answered two ways, so the check lives here
# rather than beside either of them.  The propagate run is about to write, so
# it refuses.  A deploy is about to read what is already there, and an
# operator mid-teardown has a reason to be here, so it warns and carries on.
# Inside the pipeline's own job the answer is a refusal whatever the caller
# asked for, because nobody there reads a warning and a job never deploys
# what its own configuration disowns (D27).
#
# command, outcome, and in_job give the refusal the caller's own words, so
# one state is described in one sentence however the operator arrived at it.
# in_job is the caller's alone, because only the caller knows what it was
# about to do, and a propagate run told that a job never deploys is being
# told about a command it is not.  Its default says neither.
sub assert_not_disowned {
	my ($top, %opts) = @_;

	return 1 if $top->pipeline_enabled;
	my $applied = $top->applied_record or return 1;

	my $command = $opts{command} // 'propagate';
	my $outcome = $opts{outcome} // 'Nothing was written.';
	my $in_job  = $opts{in_job}
		// 'A job never acts on what its own configuration disowns.';
	my $sha     = $applied->{control_commit} // '<unknown>';
	my $at      = $applied->{at} // '<unknown>';

	bail({exitcode => CONFIG},
		"Refusing to run #C{genesis %s}.  #C{GENESIS_PIPELINE_TASK} is set, so ".
		"this runs inside the pipeline's own job, and the pipeline is disabled ".
		"in #C{.genesis/config} while the applied record says ".
		"#C{pipeline-apply} applied it from control\@%s at %s.  %s  Set ".
		"#C{pipeline.enabled: true} again, or tear the pipeline down by hand, ".
		"which has no command yet.  %s",
		$command, $sha, $at, $in_job, $outcome
	) if $ENV{GENESIS_PIPELINE_TASK};

	bail({exitcode => CONFIG},
		"Refusing to run #C{genesis %s}.  The pipeline is disabled in ".
		"#C{.genesis/config}, but the applied record says ".
		"#C{pipeline-apply} applied it from control\@%s at %s, so the ".
		"configuration disowns a pipeline that is still live, still ".
		"watching its branches, and still deploying.  Set ".
		"#C{pipeline.enabled: true} again, or tear the pipeline down by ".
		"hand, which has no command yet.  %s",
		$command, $sha, $at, $outcome
	) unless ($opts{locally} // 'refuse') eq 'warn';

	warning(
		"Warning: the pipeline is disabled in #C{.genesis/config}, but the ".
		"applied record says #C{pipeline-apply} applied it from control\@%s at ".
		"%s.  Set #C{pipeline.enabled: true} again, or tear the pipeline down ".
		"by hand, which has no command yet.",
		$sha, $at
	);
	return $applied;
}

# }}}
# assert_provider_gate - the break-glass past a pipeline that owns the work {{{
#
#   Genesis::CI::Preflight::assert_provider_gate($top, $options,
#       owns        => 'deploys of this environment',
#       outcome     => 'Nothing was deployed.',
#       acknowledge => 'I accept the risk');
#
# D95 for the propagate run and D73 for the deploy, which are one rule with
# two sentences.  Under an automated provider the pipeline owns the work, so
# a bare command refuses and --force is the only way past.  With the flag at
# a terminal the operator acknowledges once; outside a terminal the refusal
# stands, because an acknowledgement nobody reads is not one and the
# pipeline's own job sets GENESIS_PIPELINE_TASK and never reaches here.  -y
# answers no part of this, which is why nothing below reads it.
#
# Three things come from the caller.  owns is the sentence about what the
# pipeline owns, outcome is the closing words, and acknowledge is the phrase
# an operator types.  A caller that names no phrase is asked a yes-or-no
# question instead, which is what the propagate run has always asked.
# dry_run passes with the warning alone, which the propagate run uses because
# a preview writes nothing.
#
# H33 closes here rather than with a lock, and H34 is named rather than
# closed: nothing in the tree is a locker client, and the acknowledgement
# says outright that no shuttle event is written for this command, so an
# operator who takes the break-glass knows the dependents are not woken.
sub assert_provider_gate {
	my ($top, $opts, %how) = @_;

	my $provider = $top->pipeline_provider_type;
	return 1 unless defined $provider && $provider ne 'manual';
	return 1 if $ENV{GENESIS_PIPELINE_TASK};

	my $owns    = $how{owns}    // 'propagation for this repository';
	my $outcome = $how{outcome} // 'Nothing was written.';
	my $warning = sprintf(
		"The #C{%s} pipeline owns %s.  Running it by hand does the pipeline's ".
		"work without taking any of the pipeline's locks, so the pipeline has ".
		"no way to see you.",
		$provider, $owns
	);

	if ($how{dry_run}) {
		warning($warning);
		return 1;
	}

	bail({exitcode => NOPERM},
		"%s\n\nRun it with #C{--force} at a terminal if you mean to.  %s",
		$warning, $outcome
	) unless $opts->{force};

	bail({exitcode => NOPERM},
		"%s\n\n#C{--force} needs a terminal, because the acknowledgement ".
		"cannot be given without one.  %s",
		$warning, $outcome
	) unless in_controlling_terminal();

	warning($warning);

	unless ($how{acknowledge}) {
		bail({exitcode => ABORTED}, "Aborted at your request.  %s", $outcome)
			unless prompt_for_boolean("Proceed anyway? [y|n]", 0);
		return 1;
	}

	# The phrase is typed rather than answered, because a question that takes
	# a keystroke is one an operator can answer without having read it.  The
	# default is the empty string, which is what makes a bare Enter an answer
	# the gate can refuse rather than a prompt that asks again.
	my $answer = prompt_for_line(
		"\nPause the pipeline and wait for quiescence before continuing.\n".
		"The environment being deployed, its director, and every pipeline\n".
		"that deploys to that director should all be quiet first.  Note\n".
		"that no shuttle event is written for this command, so nothing\n".
		"fans out to the deployments that read this one.",
		sprintf("Type '%s' to continue", $how{acknowledge}), ''
	);
	bail({exitcode => ABORTED}, "Aborted.  %s", $outcome)
		unless ($answer // '') eq $how{acknowledge};

	return 1;
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
# writes and the refusal states the corrective measure beside the branch.  A
# caller that passes read_only is reporting rather than running, and it is
# given the classification without the refusal, because there is no write in
# front of it for the gate to stand before.  Each branch record then carries
# what its class was, so the report can say it.
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

	# Two callers want the stage to move nothing, and they want it for two
	# different reasons.  A preview holds its writes back because the operator
	# asked to be shown a run rather than given one, and it says so in the
	# caveats D44 fixes.  A report holds them back because reporting is all it
	# ever does, and a caveat about a run nobody is about to make would be a
	# sentence it has no business printing.  So the assumption is one flag and
	# the preview's wording stays on the other.
	my $assume = $opts{dry_run} || $opts{read_only};

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
			# The ref a dry run would have moved the branch to, and undef
			# under a real run, which has moved it already, with the name
			# of the move beside it.  The stage makes two, and they differ
			# in what they cost the branch, so a reader that cares which
			# one it was asks rather than inferring it from the counts.
			# The reset's own count rides with them, because the caveat the
			# preview says about it names the number and the only other
			# place that number is said is above the banner.
			assumed         => undef,
			assumed_move    => undef,
			assumed_commits => undef,
			# Whether this branch and the remote's of the same name share a
			# commit.  The divergence states cannot tell an orphan from an
			# ordinary divergence, because both sides hold the name and both
			# sides are ahead of nothing, so the answer is recorded here for
			# the reader that has to tell them apart.
			unrelated       => 0,
		};

		# Nothing downstream of this stage makes a deployment branch any
		# more, so a branch this clone holds and the remote has never had
		# is one a person cut, which is what the refusal below says it is.
		# genesis pipeline-apply is the one command that cuts a deployment
		# branch, and it publishes what it cuts, so a branch the remote has
		# never had did not come from there.
		push(@local_only, {env => $env, branch => $branch}), next
			if $div->{state} eq 'no-remote';

		# A branch the remote has and this clone lacks is never asked the
		# ancestry question.  There is no refs/heads/<branch> for git to
		# answer it with, and _shares_history reads a ref it cannot resolve
		# as no shared history, so the branch would be refused with a text
		# written for a different fault.  Nothing reaches here in that state
		# today, because the refresh creates the local ref from the tracking
		# ref before this stage runs, and the refresh is the assumption.
		# The one command allowed to skip it is `genesis pipeline-status`,
		# so the step that hands this stage to that command is the step that
		# has to say what a branch in this state means there.
		next if $div->{state} eq 'no-local';

		next if _shares_history($git, $branch, $remote);
		push @unrelated, $branch;
		$state->{branches}{$env}{unrelated} = 1;
	}

	# Each branch's local-only commits, classified.  A marker means the walk
	# reproduces the commit, so the branch may be reset; no marker means a
	# hand edit that belongs on control, so the whole run refuses (D32, D33).
	#
	# A branch already refused for its origin is not asked.  Every commit on
	# a branch the remote has never had is local-only by construction, and so
	# is every commit on an orphan, so asking would name each of them a hand
	# edit as well and say the same branch twice in one refusal under two
	# headings.  What such a branch needs is the remedy its own class gives.
	my %illegitimate = map {($_ => 1)}
		(map {$_->{branch}} @local_only), @unrelated;

	my (@reset, @hand);
	for my $env (@{$opts{envs} // []}) {
		my $record = $state->{branches}{$env} or next;
		my $branch = $record->{branch};
		next if $record->{state} eq 'no-local';
		next if $illegitimate{$branch};

		my @commits = local_only_commits($git, $branch);
		next unless @commits;

		if (grep {!defined $_->{marker}} @commits) {
			push @hand, {branch  => $branch,
			             ahead   => $record->{ahead},
			             behind  => $record->{behind},
			             commits => [grep {!defined $_->{marker}} @commits]};
			next;
		}
		push @reset, {env => $env, branch => $branch, commits => \@commits};
	}

	# One refusal for every class, because a repository can hold a branch of
	# each and an operator who fixes one class only to meet the next on the
	# following run has been told a third of what the stage already knew.
	# The composed text goes through a '%s' format, because bail reads its
	# argument as a format and a branch name or a commit subject can carry a
	# percent sign.
	#
	# A caller that only ever reports is not refused.  D96 frames the illegal
	# initial state as a gate in front of the propagate run's first write, and
	# the refusal's own closing sentence says what was not written, so a
	# command that was never going to write anything has nothing for the gate
	# to stop.  Commands and flags gives the status one refusal, the disowned
	# pipeline of D64, and this is not it.
	#
	# What the suppression admits is worth naming exactly, because it is not
	# D33's hatch.  D33 gives a hand commit two fates, and the legal one is
	# the commit pushed to the remote, which no branch here is ever refused
	# over: an in-sync branch has no local-only commit for the classification
	# to find.  What reaches a report through this arm is the unpushed hand
	# commit, the branch the remote has never had, and the branch that shares
	# no ancestor with the remote's, and D33 calls the first of those a state
	# that refuses a run.  So the report describes all three and names the
	# remedy beside each, rather than refusing to describe the repository at
	# all because one branch in it is in a state no run may start from.
	#
	# A preview is refused all the same, because a preview stands for a run
	# that would be refused and showing that run would be a lie about what
	# happens next.
	bail({exitcode => DATAERR}, '%s',
		_illegal_state_refusal($action, $outcome, $remote,
			\@local_only, \@unrelated, \@hand))
		if (@local_only || @unrelated || @hand) && !$opts{read_only};

	# The first write of the run, and the one forced write onto a deployment
	# branch that rule 3 of the class table admits beside the session's abort.
	for my $r (@reset) {
		my $tracking = sprintf('refs/remotes/%s/%s', $remote, $r->{branch});
		my $line = sprintf('reset %s to %s/%s, discarding %s that the walk reproduces',
			$r->{branch}, $remote, $r->{branch}, _commits(scalar @{$r->{commits}}));

		# The assumption is recorded rather than warned about here, because
		# D44 says it under the preview's own banner and a caveat printed
		# above that banner is one the operator meets before they have been
		# told they are reading a preview.  The event line below is printed
		# either way, so nothing about the reset goes unsaid.
		if ($assume) {
			# Nothing moved, so the record keeps the state the
			# classification gave it and names the ref a real run would
			# have moved the branch to.  A reader that wants the diff base
			# takes that ref, and the report then says what a real run
			# would say rather than what this un-moved branch would.  The
			# move's name goes with it, because the caveat the report says
			# is about the reset and the fast-forward below sets assumed
			# without discarding anything, and the count goes with both,
			# because the caveat names it.
			$state->{branches}{$r->{env}}{assumed}         = $tracking;
			$state->{branches}{$r->{env}}{assumed_move}    = 'reset';
			$state->{branches}{$r->{env}}{assumed_commits} =
				scalar @{$r->{commits}};
		} else {
			$git->set_branch_ref($r->{branch}, $tracking);
			# The branch stands on its tracking ref now, so the record is
			# settled with it.  A caller reading state or either count off
			# a record the stage has written would otherwise get the value
			# the classification wrote, which is no longer true.
			my $record = $state->{branches}{$r->{env}};
			$record->{reset}  = 1;
			$record->{state}  = 'in-sync';
			$record->{ahead}  = 0;
			$record->{behind} = 0;
		}
		push @{$state->{events}}, $line;
	}

	# Last, a branch that is merely behind moves by fast-forward, which
	# resolves nothing a human would decide and which the deploy's own
	# --ff-only is the precedent for (D5).  After this a deployment branch
	# is in-sync or it has no local ref at all, which is what lets the diff
	# base stay the local ref under D2.
	#
	# The divergence is asked again rather than read off the record, because
	# a branch this stage has just reset stands where its tracking ref does
	# and the record was written before that move.
	for my $env (@{$opts{envs} // []}) {
		my $record = $state->{branches}{$env} or next;
		my $branch = $record->{branch};

		my $div = $git->resolve_branch($branch);
		next unless $div && $div->{state} eq 'behind';

		my $line = sprintf('fast-forwarded %s to %s/%s, %s behind',
			$branch, $remote, $branch, _commits($div->{behind}));

		my $tracking = sprintf('refs/remotes/%s/%s', $remote, $branch);

		# The warning says only that the fast-forward is assumed, because
		# the event line below is the one record of what would be done and
		# the caller prints it either way.
		#
		# It is said here rather than under the preview's banner, where the
		# reset's caveat moved to, because D44 names two caveats and a
		# fast-forward is neither.  It takes their sentence shape all the
		# same, so an operator who meets all three reads one kind of
		# sentence rather than two.
		if ($assume) {
			warning(
				"#Y{This preview assumes }#C{%s}#Y{ is fast-forwarded first.}",
				$branch) if $opts{dry_run};
			$record->{assumed}      = $tracking;
			$record->{assumed_move} = 'fast-forward';
		} else {
			$git->set_branch_ref($branch, $tracking);
			$record->{fast_forwarded} = 1;
			$record->{state}  = 'in-sync';
			$record->{behind} = 0;
		}
		push @{$state->{events}}, $line;
	}

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
# _illegal_state_refusal - one refusal for every illegal initial state {{{
#
# The stage raises at most one refusal, so the act is named once, the
# closing sentence is said once, and an operator holding a branch of each
# class hears about all of them at the same time.  The three classes come in
# the order the stage asks about them, which is the branch the remote has
# never had, the branch that shares no ancestor with the remote's, and then
# the branch carrying a commit no marker accounts for.  M13 raises the same
# text in its deploy form, which is why the act and the closing sentence are
# arguments.
#
# It was named for the two origin classes when it carried only those.  The
# hand commit is not a question about where a branch came from, so the name
# moved to what the three have in common, which is that each is an initial
# state D96 calls illegal.
sub _illegal_state_refusal {
	my ($action, $outcome, $remote, $local_only, $unrelated, $hand) = @_;
	return sprintf("Refusing to %s.  %s  %s", $action,
		join('  ',
			_local_only_refusal($remote, $local_only),
			_unrelated_refusal($remote, $unrelated),
			_hand_commit_refusal($remote, $hand)),
		$outcome);
}

# }}}
# _local_only_refusal - D48's text for a branch the remote has never had {{{
#
# One paragraph per branch, so the single-branch case reads exactly as the
# design quotes it and a run with several names them all.  The act and the
# closing sentence belong to _illegal_state_refusal, which frames whichever
# classes the stage found.
sub _local_only_refusal {
	my ($remote, $offenders) = @_;
	return map {
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
		} @{$offenders || []};
}

# }}}
# _unrelated_refusal - D48's text for a branch that shares no ancestor {{{
#
# One paragraph per branch, framed by _illegal_state_refusal like its
# neighbour.
sub _unrelated_refusal {
	my ($remote, $branches) = @_;
	return map {
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
		} @{$branches || []};
}

# }}}
# _hand_commit_refusal - D33's paragraphs for a branch carrying a hand edit {{{
#
# Names each branch, each commit, and the two ways out with the command for
# each, which is what D96 asks of an illegal initial state.  No flag does the
# operator's half, because under D38 the right friction is to undo by hand.
#
# One block rather than one paragraph per branch, because the opening
# sentence and the indented list are shared and a per-branch block would say
# the opening once for every offender.  The act and the closing sentence
# belong to _illegal_state_refusal, which frames whichever classes the stage
# found.
#
# The counts are the branch's and the list is not.  A branch carrying a
# marker commit beside a hand commit reads as ahead by two over a list of
# one, which is right, because the counts say how the branch stands against
# the remote and the list says what has to be dealt with.  The review that
# found this asked only that it be recorded, so the text is unchanged and
# the distinction is written here for the next reader of it.
sub _hand_commit_refusal {
	my ($remote, $offenders) = @_;
	return () unless @{$offenders || []};

	return sprintf(
		"%s\n\n%s\n\n%s",
		"These branches carry a commit the remote does not have and that ".
		"carries no propagation marker, so it is a hand edit that belongs on ".
		"control.",
		join("\n", map {
			my $branch = $_->{branch};
			map {sprintf('    %s  %s  %s', $branch, $_->{short}, $_->{subject})}
				@{$_->{commits}}
		} @$offenders),
		join('  ', map {
			sprintf(
				"#C{%s} is ahead of #C{%s/%s} by %s and behind it by %s.  Push ".
				"it with #C{git push %s %s} if it is meant, or move the change ".
				"to control and reset the branch with ".
				"#C{git branch -f %s %s/%s} if it is not.",
				$_->{branch}, $remote, $_->{branch},
				_commits($_->{ahead}), _commits($_->{behind}),
				$remote, $_->{branch}, $_->{branch}, $remote, $_->{branch})
		} @$offenders));
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
