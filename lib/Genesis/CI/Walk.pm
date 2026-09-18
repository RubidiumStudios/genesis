package Genesis::CI::Walk;
# The per-commit walk.  Reads control on R, each branch's newest marker,
# each environment's certified commit, the applied record, and the hold
# record, and returns the canonical record D91 fixes.  It writes nothing:
# the caller delivers what the record says is pending, through the single
# writer.
#
# Every routing question is answered out of a commit's own tree rather than
# out of the tree on disk, which is what makes I11 true.  The topology and
# the environment files are the exception, and they are read off control,
# which the run has stood itself on before it calls in here.
use strict;
use warnings;

use Exporter qw/import/;
use JSON::PP ();
use Scalar::Util ();
use Genesis qw/run bug bail info/;
use Genesis::CI::Marker qw/STAGE RELEASE_STAGE/;
use Genesis::CI::PullRequest;
use Genesis::CI::Report;
use Genesis::CI::RunFailure;
use Genesis::Exit qw/UNAVAILABLE/;

our @EXPORT_OK = qw/
	plan scope_for changed_set route_commit undeployed_set overlap
	read_durable_state env_state
	certified_for hold_for
	apply_hold
	gate_state released_gates
	introducing_commit walk_base
	walk_one is_run_fatal abort_run
	READINGS HOLD_REASONS
/;

# D94 fixes the four readings, and error is the record's own field rather
# than a fifth reading.
use constant READINGS => qw/deployed pending-deploy unseeded not-propagated/;

# D50's five reasons plus the consequence of ordered delivery under D34.
use constant HOLD_REASONS => qw/
	ancestor-overlap ancestor-uncertified gate-ahead
	on-hold awaiting-merge behind-held-commit
/;

### The readings {{{

# read_durable_state - everything the run is allowed to read, read once {{{
#
# I11 names the inputs exactly, and the rule that an input the run cannot
# read makes it refuse rather than guess is D55's.  Reading them here, in
# one place, is what makes the rule checkable: a caller that wanted to guess
# would have to add a reader, and there is only one.
#
# Control is read off the local ref, and that is control on R.  The refresh
# brings R into T for every branch in scope before anything is read, and the
# pre-flight then refuses every state in which the local ref and the tracking
# ref differ, so by the time this runs the two name one commit.  Reading the
# tracking ref here as well would be a second reader of one fact, which is
# the thing this sub exists to remove.
#
# The staleness is not read here.  Ruling 14 takes it out, because reading it
# costs a second read of the applied record and a load of every environment in
# the pipeline, and nothing the walk decides depends on it.  M17 reads it where
# it renders it.
#
# An applied record the vault answers an error for is the whole run's input and
# not one environment's, so under D55 the run refuses naming the path it could
# not read.  An absent record is a different thing and stays a reading: D94
# says the record is legitimately missing until genesis pipeline-apply has run,
# and every environment then takes the not-propagated reading.
sub read_durable_state {
	my (%args) = @_;

	my $top = $args{top}
		or bug("Genesis::CI::Walk::read_durable_state needs a Genesis::Top");
	my $git = $args{git}
		or bug("Genesis::CI::Walk::read_durable_state needs a git handle");

	my $control     = $top->control_branch;
	my $control_sha = $git->sha($control);

	# A caller standing inside a session owes the operator their branch back
	# before it says why the run stopped, so it hands in a closure that closes
	# the session and then refuses.  A caller with no session to close leaves
	# it out and the refusal goes straight out through bail.
	my $refuse = $args{refuse} || \&bail;

	my $applied = eval {$top->applied_record};
	# The reason is taken off $@ on the line after the eval, before anything
	# else runs.  applied_record_path traces through Genesis::Log, whose
	# formatter evals, so a $@ read from inside the same argument list is
	# whatever that logging eval left behind and the refusal named the path
	# with an empty reason beside it.
	my $failure = $@;
	# The closing sentence comes from the caller, because a run that writes
	# and a command that only reports owe the operator different accounts of
	# where they stopped.  "Nothing was written" says nothing to somebody who
	# asked for a report and never expected a write.
	$refuse->(
		{exitcode => UNAVAILABLE},
		"Could not read the applied record at #C{%s}: %s\n\n".
		"The run reads which commit the pipeline was applied from before it ".
		"decides anything, so it will not guess at one.  %s",
		$top->applied_record_path, $failure =~ s/\s+$//r,
		$args{outcome} // 'Nothing was written.'
	) if $failure;

	return {
		# The pipeline's own label, which is the name the configuration
		# gives it, and the deployment type beside it, which is what the
		# applied record is addressed under.  A repository that names no
		# label leaves the first null, and M17's renderer chooses which of
		# the two to print.
		pipeline  => $top->config->get('pipeline.name'),
		type      => $top->type,
		# Defaulted here and nowhere else.  The accessor answers undef for a
		# repository whose pipeline is switched off, and every reader of this
		# field would then have to default it for itself or print a blank
		# where a word belongs.  Manual is what no provider means: nothing
		# triggers a deploy but a person.
		provider  => $args{provider} // $top->pipeline_provider_type // 'manual',
		control   => {branch => $control, commit => $control_sha},
		applied   => $applied,
		refreshed => $args{refreshed} // 1,
	};
}

# }}}
# env_state - one environment's durable state, or the error that ends its turn {{{
#
# D55 and I11: the run names the input it could not read and never guesses a
# value in its place.  D60 decides how far the failure reaches, and this is a
# per-environment read, so it reaches exactly one environment.  The raise is a
# plain die rather than a refusal, because every caller runs inside walk_one,
# which records that environment failed with this message beneath it and walks
# on to the next.  A refusal spelled here could never fire, and one that read
# as though it might would have a reader believe an unreadable hold ends the
# run.
#
# The certified commit and the hold are read together, because they are the
# two durable facts an environment carries and a caller that read one of them
# where it happened to need it would read the other somewhere else.  Reading
# the hold here is also what lets an environment the pipeline was never
# applied to report the hold standing over it, which D56 asks for and which a
# reader placed at the end of the walk never reached.
sub env_state {
	my (%args) = @_;

	my $env = $args{env};

	my $certified = certified_for($env);
	return $certified if $certified->{error};

	my $hold = eval {$env->hold_record};
	# Read off before hold_record_path runs, for the reason
	# read_durable_state's own guard gives: that reader traces, tracing
	# evals, and a $@ read inside the argument list is the tracing's rather
	# than the failure's.
	my $failure = $@;
	die sprintf(
		"Could not read the hold record for %s at %s: %s\n",
		$env->name, $env->hold_record_path, $failure =~ s/\s+$//r
	) if $failure;

	return {%$certified, hold => $hold};
}

# }}}
# introducing_commit - E, the control commit that introduced an env file {{{
#
# Control is linear under D31, so the oldest commit that added the
# environment's own file names E exactly, and --diff-filter=A over that path
# is that question asked directly.  The newest add is not the answer, because
# a file that was added, removed, and added again belongs to the environment
# from the first of the three onward.
#
# An environment control has never carried has no introducing commit, and the
# caller reads that as a branch to walk from the whole of control rather than
# as a failure, because the same answer comes back for an environment whose
# file was introduced on the very first commit.
#
# --follow walks the path back through the renames it has been through, so a
# repository that has moved its deployment root answers the original add
# rather than the restructure, and no routing commit between the two falls
# outside the walk.  Rename detection is git's similarity heuristic rather
# than a recorded fact, and a move that changed nothing about the file's
# content always clears it, which is what a restructure is.
#
# -M100% is what keeps the heuristic to that.  git turns copy detection on
# inside --follow and will not let a caller turn it off, and environment
# files are near enough identical to one another that the default threshold
# reads a brand new one as a copy of the environment beside it and answers
# the commit that added that one instead.  Requiring an exact match leaves
# only the move this is here for.
sub introducing_commit {
	my ($git, $control, $env_file) = @_;

	my ($out, $rc) = run(
		{dir => $git->root, stderr => 0},
		'git', 'log', '--follow', '-M100%', '--first-parent',
		'--diff-filter=A', '--format=%H', $control, '--', $env_file
	);
	return undef if $rc || !defined($out) || !length($out);

	my @adds = grep {/\S/} split /\n/, $out;
	return undef unless @adds;
	return $adds[-1];
}

# }}}
# walk_base - where one environment's walk starts {{{
#
# The newest marker the branch carries, and for a branch that carries none
# the commit before E, so that E is the first commit routed and is holdable
# like any other commit under D61.  An init-only orphan branch shares no
# history with control, so there is nothing on it for the marker walk to
# read, and starting from the tip instead would collapse every commit since
# the environment was added into one baseline and skip all of their holds.
#
# The base and the marker are two different facts and only one of them comes
# back as the base, which is why the reading comes back beside it.  An
# unseeded branch has merged nothing, and a caller that took its base for a
# marker would report a branch standing on a commit it has never carried.
#
# The ref is the one the pre-flight settled rather than a remote-tracking ref
# composed here, because D2 makes the local ref the base every reader takes
# and a dry run hands over the ref a real run would have moved the branch to.
sub walk_base {
	my (%args) = @_;

	my $git = $args{git};

	my $marker = Genesis::CI::Marker::newest($git, $args{ref});
	return ($marker, 'seeded') if defined $marker;

	return (_before_introduction($git, $args{control}, $args{env_file}),
		'unseeded');
}

# }}}
# control_commits - the control commits after a base, oldest first {{{
#
# Control is linear under D31, so first-parent order is control order and
# --reverse gives us the oldest due commit first.  An undefined base means
# the whole of control, which is what walk_base answers for a branch with no
# marker whose environment was introduced on control's own first commit,
# since there is no commit before that one to start after, and for one whose
# environment control has never carried a file for at all.
sub control_commits {
	my ($git, $control, $base) = @_;

	my $range = defined $base ? "$base..$control" : $control;
	my ($out, $rc) = run(
		{dir => $git->root, stderr => 0},
		'git', 'log', '--first-parent', '--reverse',
		'--format=%H%x00%s', $range
	);
	return () if $rc || !$out;

	my @commits;
	for my $line (split /\n/, $out) {
		next unless $line =~ /\S/;
		my ($sha, $subject) = split /\x00/, $line, 2;
		push @commits, {sha => $sha, subject => $subject // ''};
	}
	return @commits;
}

# }}}
# changed_set - one commit's files for one environment, split in two {{{
#
# D69: the set is read from the tree at the commit being delivered and never
# from the working tree, because a restructure moves the prefix that defines
# the set.  D68: the set divides into triggering paths, whose change means
# deploy me, and non-triggering ones, which must be current on the branch
# without meaning that.  What the split then decides is route_commit's to
# say.
#
# The marked set is read once and split here rather than asked for twice,
# because each reading writes the deployment root out into a scratch tree and
# runs the kit's blueprint hook over it, and a walk pays that for every commit
# it routes.
sub changed_set {
	my ($git, $env, $commit) = @_;

	my $kinds = $env->_propagation_file_kinds_at($commit, git => $git);

	# --root, because control's own first commit is a commit like any other
	# and an unseeded branch is walked from there.  Without it git shows a
	# root commit as changing nothing, so the repository whose whole history
	# is one commit routes that commit to nobody.
	my ($out, $rc) = run(
		{dir => $git->root, stderr => 0},
		'git', 'diff-tree', '--no-commit-id', '--name-only', '-r', '--root',
		$commit
	);
	return ([], []) if $rc || !$out;

	# A kind that is a directory stands for everything under it, which is
	# how the dev kit joins the set, so a path is in the set where the set
	# names it or where the set names a directory it lies in.  Without that
	# a commit touching the kit routes to nobody, and the kit is the one
	# kind a pipeline exists to prove in lab first.  A reaction script is
	# not one of these: it joins the set as the explicit path bin/<script>
	# the environment declares.
	#
	# Service::Git::Session::_members_at makes the same expansion from the
	# other end, resolving the set's directory entries against a commit's
	# tree, so a change to either of the two goes looking for its twin.
	my @dirs = grep {m{/$}} keys %$kinds;

	my (@hit, @carried_hit);
	for my $path (split /\n/, $out) {
		next unless $path =~ /\S/;
		my $mark = $kinds->{$path};
		unless (defined $mark) {
			# The longest entry that contains the path, rather than the first
			# a hash happens to answer with, because a set naming both a
			# directory and one below it would otherwise mark a path by
			# whichever of the two came out of the hash first.
			my ($dir) = sort {length($b) <=> length($a)}
				grep {index($path, $_) == 0} @dirs;
			next unless defined $dir;
			$mark = $kinds->{$dir};
		}
		push @{$mark ? \@hit : \@carried_hit}, $path;
	}
	return ([sort @hit], [sort @carried_hit]);
}

# }}}
# route_commit - decide whether one commit belongs to one environment {{{
#
# D68: only triggering content routes a commit.  changed_set makes the split,
# and a commit whose content for this deployment falls wholly on the
# non-triggering side is skipped exactly as one that touches nothing in the
# set is, and it records no outcome, because the next delivery's mirror
# already carries it.  That holds behind a hold as well as in front of one,
# so a config change standing behind a held commit is not reported as
# waiting on anything.  The carried list travels with the routed
# commit for the report alone, so an operator can see that a script or a
# config change rode along.
sub route_commit {
	my ($git, $env, $commit) = @_;

	my ($triggering, $carried) = changed_set($git, $env, $commit);
	return undef unless @$triggering;

	return {triggering => $triggering, carried => $carried};
}

# }}}
# undeployed_set - what an environment holds or is about to hold {{{
#
# Every file in the environment's propagation set that changed on control
# between its certified commit and the commit under consideration.  D43: an
# ancestor that has never certified a commit holds everything below it, so
# with no certified commit the undeployed set is the whole propagation set
# rather than the empty set the baseline's fallback produces, which is H22.
# Nothing here ever falls back to control's tip, which is H29's shape.
sub undeployed_set {
	my ($git, $env, $certified, $upto) = @_;

	my @triggering = $env->propagation_files_at($upto,
		git => $git, triggering => 1);
	return @triggering unless defined $certified && length $certified;

	my %in_set = map {$_ => 1} @triggering;
	my ($out, $rc) = run(
		{dir => $git->root, stderr => 0},
		'git', 'diff', '--name-only', "$certified..$upto"
	);

	# A range git will not resolve is an input this run cannot read, and it
	# is not an ancestor with nothing undeployed.  Answering the empty list
	# drops the hold the range was being read for, and the descendant then
	# receives content nothing above it has ever deployed, so the run ends
	# here and names the range instead.  A clone that never fetched the
	# certified commit and a control branch that was rewritten under one
	# both arrive this way.
	die Genesis::CI::RunFailure->fatal(
		message => sprintf(
			"%s has certified a commit this repository cannot resolve, so ".
			"what it has left undeployed cannot be read over %s..%s",
			$env->name, $certified, $upto)
	) if $rc;
	return () unless defined($out) && length($out);

	return grep {$in_set{$_}} grep {/\S/} split /\n/, $out;
}

# }}}
# overlap - the triggering files an ancestor has not deployed {{{
#
# D68 again: a hold exists to stop unproven content reaching a descendant,
# and a non-triggering path is not content that needs proving, so it never
# counts here.  Without this rule a shared .genesis/config change would hold
# every descendant on the commit that touched it.  Both lists arrive
# triggering already, the commit's from route_commit and the ancestor's from
# undeployed_set, so the rule is kept by what is handed in rather than by a
# second filter of its own.
sub overlap {
	my ($files, $undeployed) = @_;

	my %undeployed = map {$_ => 1} @$undeployed;
	return grep {$undeployed{$_}} @$files;
}

# }}}
# certified_for - one environment's certified commit, or why there is none {{{
#
# D60 gives three ways to fail to read a certified commit and none of them is
# an outage, because an unreachable vault dies at connect_and_validate before
# any walk.  A with_vault failure is a broken environment and the walk records
# it as failed.  A readable record with no git.control_commit is an
# environment the pipeline was never applied to, which is held rather than
# deployed.  And an environment with no successful deployment at all has
# certified nothing, which is the state D43 makes hold everything below it.
#
# Nothing here ever falls back to control's tip, because that asserts a deploy
# that did not happen and empties the set that holds the descendants, which is
# the shape H29 describes.
sub certified_for {
	my ($env) = @_;

	my $with_vault = eval {$env->with_vault};
	return {state => 'unreadable', error => _load_error($@)}
		unless $with_vault;

	my $deployment = eval {$with_vault->deployments->latest_successful};
	return {state => 'never-certified'} unless $deployment;

	my $certified = $deployment->lookup('git.control_commit');
	return {state => 'never-applied'}
		unless defined $certified && length $certified;

	return {
		state          => 'certified',
		control_commit => $certified,
		commit         => $deployment->lookup('git.commit'),
		# An audit records when it completed, and a record written before
		# that field existed says dated instead, so both are read.
		at             => $deployment->lookup('completed')
			// $deployment->lookup('dated'),
	};
}

# }}}
# hold_for - the reason one commit is held for one environment, or undef {{{
#
# D34: an overlap with any ancestor's undeployed set holds the commit.  D43
# and D60: an ancestor that has certified nothing holds everything below it,
# whether or not its own branch already holds the files, which is the closure
# of H22.  D72: where an overlap is what holds it, the reason also carries the
# ancestor's own state, so the operator is not left to infer it from another
# row.  The ancestors are asked nearest first, so the reason names the one
# closest to the environment.
sub hold_for {
	my (%args) = @_;

	my $git      = $args{git};
	my $commit   = $args{commit};
	my $files    = $args{files};
	my $provider = $args{provider};

	for my $ancestor (@{$args{ancestors} || []}) {
		my $certified = $ancestor->{certified};

		unless ($certified->{state} eq 'certified') {
			return {
				reason         => 'ancestor-uncertified',
				ancestor       => $ancestor->{name},
				ancestor_state => $certified->{state},
			};
		}

		my @undeployed = undeployed_set(
			$git, $ancestor->{env}, $certified->{control_commit}, $commit
		);
		my @hit = overlap($files, \@undeployed);
		next unless @hit;

		# The key is inert under the manual provider, where an environment
		# waits for a person rather than for a trigger, so both conditions
		# are required before the reason reads awaiting its trigger.
		my $automated = _automated($provider);
		my $waits_for_trigger = $automated
			&& $ancestor->{env}->lookup('genesis.pipeline.manual', 0);

		return {
			reason         => 'ancestor-overlap',
			ancestor       => $ancestor->{name},
			ancestor_files => [sort @hit],
			ancestor_state => $waits_for_trigger
				? 'awaiting its trigger'
				: 'awaiting deployment',
		};
	}

	return undef;
}

# }}}
# _automated - whether a provider triggers a deploy without a person {{{
#
# One answer, because two readers ask it: the hold reason that says an
# ancestor awaits its trigger, and the row's own manual marker.  A provider
# nobody named is not automated, since nothing then exists to do the
# triggering, and two readers that disagreed about that would put the marker
# on a row whose hold reason beside it said the opposite.
sub _automated {
	my ($provider) = @_;
	return defined $provider && $provider ne 'manual' ? 1 : 0;
}

# }}}
# gate_state - the gate the walk is standing behind, if any {{{
#
# D49: a Genesis-Stage trailer makes a commit a gate.  A gate constrains only
# what follows it, so it travels with the commits already ahead of it and
# ends the delivery.  Three things release it.  The environment's own
# certified commit reaching or passing it releases it; a later commit that
# reverts it, recognised from git's own body line or from an explicit
# Genesis-Release-Stage trailer, releases it with no deploy at all.
#
# The trailer is read under the key Genesis::CI::Marker answers it by rather
# than under its wire name, because the module owns that mapping and a second
# spelling here is how the two come to disagree.
sub gate_state {
	my (%args) = @_;

	my $git       = $args{git};
	my $certified = $args{certified};
	my $released  = $args{released};
	my $commit    = $args{commit};

	my $trailers = Genesis::CI::Marker::trailers($git, $commit);
	my $stage = $trailers->{+STAGE};
	return undef unless defined $stage && length $stage;

	return undef if $released && $released->{$commit};
	return undef if defined $certified && length $certified
		&& $git->is_ancestor($commit, $certified);

	# hold: <reason> is the gate that also sets a propagation hold once the
	# gated commit is deployed, under D50.  The gate half behaves the same.
	my $reason = $stage;
	$reason =~ s/^hold:\s*//;

	return {reason => 'gate-ahead', gate => $commit, gate_reason => $reason};
}

# }}}
# released_gates - the gates a later control commit has released {{{
#
# Read once over the whole walk range, so that a release sitting after the
# gate is visible while the walk is still at the gate.  git's revert body
# line names the full hash, and Genesis-Release-Stage may name a full or an
# unambiguous short hash, so we resolve whatever we find through rev-parse.
#
# Later is what it says and what it means.  A release only ever sits after
# the gate it names, so a commit in the range that names one at or after
# itself releases nothing: a gate constrains what follows it, and a release
# standing in front of the gate would lift it before it was ever set.  A
# commit the range does not hold is older than the range, and the release
# is after that one by the same reading, so it stands.
sub released_gates {
	my ($git, @commits) = @_;

	# Control is linear under D31 and the range comes oldest first, so a
	# commit's place in the list is its place in control order.
	my %at;
	$at{$commits[$_]{sha}} = $_ for 0 .. $#commits;

	my %released;
	for my $n (0 .. $#commits) {
		my $commit = $commits[$n];
		my ($body, $rc) = run(
			{dir => $git->root, passfail => 0, stderr => 0},
			'git', 'log', '--format=%B', '-1', $commit->{sha}
		);
		next if $rc || !defined $body;

		my @named;
		push @named, $1 while $body =~ /This reverts commit ([0-9a-f]{7,40})/g;

		my $trailers = Genesis::CI::Marker::trailers($git, $commit->{sha});
		push @named, $trailers->{+RELEASE_STAGE}
			if defined $trailers->{+RELEASE_STAGE};

		for my $name (@named) {
			my ($full, $frc) = run(
				{dir => $git->root, passfail => 0, stderr => 0},
				'git', 'rev-parse', $name
			);
			next if $frc || !defined $full;
			chomp $full;
			next if defined $at{$full} && $at{$full} >= $n;
			$released{$full} = 1;
		}
	}
	return \%released;
}

# }}}
# }}}
### The walk {{{

# walk_env - one environment's walk, from its newest marker to control {{{
#
# D34: each commit is routed on its own, in control order, and the first
# hold ends the walk for this environment because a mirror at any later
# commit would carry the held one.  Everything after the hold is recorded
# with behind-held-commit so that I8's per-commit axis names every routed
# commit rather than falling silent at the first hold.
sub walk_env {
	my (%args) = @_;

	my $git     = $args{git};
	my $env     = $args{env};
	my $record  = $args{record};
	my $control = $args{control};

	my $base = $args{base};
	my @due  = control_commits($git, $control, $base);
	my $gate = $args{gate};

	my $held_by;
	for my $commit (@due) {
		# The routing question is asked before the hold is, because a commit
		# that routes nowhere records no outcome at all and being behind a
		# hold does not give it one.
		my $routed = route_commit($git, $env, $commit->{sha});
		next unless $routed;
		my $files = $routed->{triggering};

		if ($held_by) {
			push @{$record->{held}}, {
				control_commit => $commit->{sha},
				subject        => $commit->{subject},
				files          => $files,
				reason         => 'behind-held-commit',
				behind         => $held_by,
			};
			next;
		}

		# D49 and D56: the gate travels with the commits already ahead of it,
		# so a commit at or before it is delivered and the delivery ends
		# there.  Everything after it carries the gate's own reason rather
		# than behind-held-commit, because the gate is the one thing an
		# operator can clear and naming the commit in front of it instead
		# would send them to the wrong place.
		if ($gate && !$git->is_ancestor($commit->{sha}, $gate->{gate})) {
			push @{$record->{held}}, {
				%$gate,
				control_commit => $commit->{sha},
				subject        => $commit->{subject},
				files          => $files,
			};
			next;
		}

		my $hold = $args{hold_check}->($commit, $files);
		if ($hold) {
			push @{$record->{held}}, {
				%$hold,
				control_commit => $commit->{sha},
				subject        => $commit->{subject},
				files          => $files,
			};
			$held_by = $commit->{sha};
			next;
		}

		# The gate is delivered, and it is the last commit that is, so its own
		# pending entry says which gate governs it and what the trailer asked
		# for.  A held entry carries the same two keys under the same meaning,
		# and the gate's entry names itself because the gate a commit is
		# governed by, where that commit is the gate, is the commit itself.
		# The arm that composes the aggregate's body reads the reason here
		# rather than parsing the trailer a second time, which is how the walk
		# and the body would come to disagree about what is being waited on.
		my %gated = ($gate && $commit->{sha} eq $gate->{gate})
			? (gate => $gate->{gate}, gate_reason => $gate->{gate_reason})
			: ();

		push @{$record->{pending}}, {
			%gated,
			control_commit => $commit->{sha},
			subject        => $commit->{subject},
			files          => $files,
			carried        => $routed->{carried},
		};
	}

	return $record;
}

# }}}
# apply_hold - stop delivery for a held environment and say why {{{
#
# D50: while the hold stands the run delivers nothing new and opens or
# updates no pull request, in either mode, but the walk still computes what
# is due so that --dry-run can show it.  D56: the hold outranks idempotent,
# because I8 exists so nothing is silently omitted and idempotent reads as
# though the environment were fine.
#
# The pending entries move into the held list rather than being discarded,
# which is what leaves the preview and the report something to list, and the
# environment's own reason travels with each of them so that a commit line
# says what somebody has to clear.  They go on the front of that list,
# because everything the walk had already held stands after the last commit
# that was still pending, and a report whose commits are out of control
# order is one an operator cannot read against the log.
sub apply_hold {
	my ($record, $hold) = @_;

	return $record unless $hold;

	$record->{hold} = $hold;
	unshift @{$record->{held}}, map {{
		%$_,
		reason      => 'on-hold',
		hold_reason => $hold->{reason},
	}} @{$record->{pending}};
	$record->{pending} = [];

	return $record;
}

# }}}
# walk_one - walk and deliver to one environment, ending at its own error {{{
#
# D96's second stage.  An error confined to one environment ends that
# environment and nothing else: its branch goes back to T so that nothing of
# a partial delivery survives in L, it records failed with the error it
# raised, and the run walks on.  This is the closure of H3, where the
# baseline's loop recorded the first error and stopped, leaving every
# environment after it neither attempted nor reported.
#
# One sub stands around both halves of an environment's turn, because D78
# puts a blueprint that raises while the run enumerates one environment's
# fragments in the same class as a delivery that died halfway, and D60 puts
# a with_vault or a load_env failure there too.  An environment that ends
# any of those three ways records the one outcome.
#
# The session is handed in only where something may have been written, and
# what it is asked for is the per-branch discard rather than abort: abort
# ends the session and the run with it, which would leave every environment
# below this one unattempted, which is the shape this sub exists to stop.
# An environment that delivers into a pull request writes on that branch and
# not on the deployment branch, so its pull request branch is put back too,
# because a discard that named the deployment branch alone would put back the
# branch nothing was written to and leave the half-written one standing.  That
# branch goes back through the restore rather than the discard, since the run
# may have cut it and the remote has no tip to put a cut branch back to.
#
# A run-fatal or unsurvivable error is not caught here.  It propagates to
# the caller, which aborts the whole run.
sub walk_one {
	my (%args) = @_;

	my $session = $args{session};
	my $record  = $args{record};

	# A caller that writes hands the session over, because a delivery that
	# died halfway is put back through it and there is no other way to reach
	# the branch.  Taking the session silently would let a caller write
	# without one and leave a partial delivery standing with nothing said, so
	# the omission is refused here rather than discovered on the branch.  A
	# caller that writes nothing, which is plan and a dry run, needs none.
	bug("Genesis::CI::Walk::walk_one was asked to deliver to %s with no ".
		"session, so a delivery that died halfway would leave its partial ".
		"write standing on the branch", $record->{env} // 'an environment')
		if $args{writes} && !$session;

	my $ok = eval {
		$args{deliver}->();
		1;
	};
	return $record if $ok;

	my $error = $@;
	die $error if is_run_fatal($error);
	$error = $error->message
		if Scalar::Util::blessed($error) && $error->can('message');

	# The deployment branch goes back through the discard, which cleans the
	# tree and the index on its way.  The pull request branch goes back
	# through the restore instead, because the discard puts a branch back to
	# the remote's tip and the remote has no tip for a branch this run cut,
	# which is exactly the branch a half-written delivery leaves standing.
	# The restore knows that case and takes such a branch off, stepping the
	# tree off it first.
	#
	# Only a branch this session actually switched to.  The walk composes the
	# pull request branch's name for every environment whose policy asks for
	# one, whether or not the arm ever stood on it, and an environment that
	# died before the switch has that name on its record with nothing of this
	# run's on the branch.  Handing the restore one of those would take off a
	# local branch somebody else made, since the restore's own last arm reads
	# a branch with no remote tip and no recorded tip as one this run cut.
	if ($session) {
		$session->discard($record->{branch});
		$session->restore_branch($record->{pr}{branch})
			if $record->{pr} && $record->{pr}{branch}
			&& $session->switched_to($record->{pr}{branch});
	}
	$record->{error}   = _load_error($error);
	$record->{outcome} = 'failed';
	$record->{pending} = [];
	return $record;
}

# }}}
# is_run_fatal - does this error end the run rather than the environment? {{{
#
# D82's two classes.  Run-fatal is the writer's own failure, where nothing a
# caller could do differently would help.  Unsurvivable is an error no
# environment can survive but a retry may fix, the remote unreachable being
# the case.  Both end the run, and both are raised as Genesis::CI::RunFailure,
# whose two constructors bless one package and tell the two apart through the
# kind they set.  So the kind is what is read here.  A test against a package
# name of each class's own would answer false for every failure the writer
# raises, because no such package exists.
#
# Everything else is confined to the environment that raised it, which is
# what walk_one does with the answer.
sub is_run_fatal {
	my ($error) = @_;

	return 0 unless Scalar::Util::blessed($error)
		&& $error->isa('Genesis::CI::RunFailure');

	my $kind = $error->kind // '';
	return ($kind eq 'run-fatal' || $kind eq 'unsurvivable') ? 1 : 0;
}

# }}}
# abort_run - end the run, reset every committed branch, and say why {{{
#
# D82 and D96: both classes that end a run abort the same way, and they
# differ only in the status they exit with.  Run-fatal is the writer's own
# failure and exits 1, because no retry helps.  Unsurvivable is an error a
# retry may fix, and exits Genesis::Exit::TEMPFAIL, which sysexits calls a
# temporary failure with a failed connection as its example.  The status is
# read off the failure rather than decided here, because Genesis::CI::RunFailure
# already carries the one D82 gives each class.
#
# The outcome words come from that same class, for the reason D54 gives: an
# environment the run had reached records that nothing of its was published
# and one it never reached records that it was not attempted, and a phrase
# living in two places is a phrase the two drift apart on.
#
# The abort is the last thing that happens, because it is what resets every
# branch this session committed to back to T and it ends the process on the
# way out.  The per-environment lines are printed above it, so the operator
# reads what became of each environment before they read why the run
# stopped.
sub abort_run {
	my (%args) = @_;

	my $session = $args{session};
	my $record  = $args{record};
	my $error   = $args{error};

	my @envs = $record ? (map {$_->{env}} @{$record->{environments}})
	                   : @{$args{envs} || []};
	my $fields = Genesis::CI::RunFailure::abort_fields(\@envs, $args{at});

	# A run that died before the walk returned has no record to write into,
	# so one is stood up over the names alone.  The report is rendered from a
	# record either way, because an abort that printed its own lines is an
	# abort whose words drift from every other output's.
	$record ||= {environments => [map {{env => $_}} @envs]};
	for my $env_record (@{$record->{environments}}) {
		my $field = $fields->{$env_record->{env}} || {};
		$env_record->{outcome}        = $field->{outcome};
		$env_record->{outcome_detail} = $field->{detail};
	}

	# One line per environment, which is I8 over the axis this stage owns: a
	# run that ended early still says what became of every environment it had
	# in scope.  Only that axis is printed, because nothing was published and
	# a pending commit listed as delivered would name a delivery that the
	# abort has just undone.
	Genesis::CI::Report::render_run($record, outcomes_only => 1);

	my $failure = Scalar::Util::blessed($error)
		&& $error->isa('Genesis::CI::RunFailure') ? $error : undef;
	my $message = sprintf(
		"%s\n\nNothing was published, and every branch this run committed ".
		"to has been reset.",
		($failure ? $failure->report_line : "$error") =~ s/\s+$//r
	);
	my $status = $failure ? $failure->exit_code : 1;

	$session->abort($message, exitcode => $status)
		if $session && $session->active;

	# No session, or one that has already gone out through its own abort.
	# There is nothing left to reset, and the reason still has to be said.
	bail({exitcode => $status}, "%s", $message);
}

# }}}
# scope_for - the environments this run walks, with their branches {{{
#
# D66: the branch is per deployment, not per environment, so every name here
# is composed through branch_for and two roots sharing an environment name
# never contend on one branch.  Genesis::Top already roots at the deployment
# root the command stands in, so a run walks one root's environments and the
# marker walk needs no pathspec, which closes H32 by construction.
#
# The type is read off the accessor rather than out of the configuration key
# it reads, because one fact answered through two readers is how the two come
# to disagree.
#
# D66 and D71: the pull request branch is the prefix joined onto the same
# deployment slug, so the two names cannot disagree about which deployment a
# branch belongs to.  It is composed here now that the arm that delivers onto
# it exists, and only for an environment whose policy asks for one, because
# composing it rebuilds the unmemoized topology once per environment.  The
# collision pr_branch_for refuses is asked for in the pre-flight, ahead of the
# session, so its CONFIG exit survives rather than dying as a string inside
# the run's own eval.
sub scope_for {
	my ($top, %opts) = @_;

	my $topology = $top->pipeline_topology;
	my @scope;
	my %depth;

	# The walk's scope option narrows which environments come back and
	# nothing else.  Depth and prior_env are computed over the whole
	# topology first, so an environment asked for on its own still reads
	# the ancestor it inherits from, which is what pipeline-status needs.
	my %wanted;
	%wanted = map {$_ => 1} @{$opts{scope}}
		if $opts{scope} && @{$opts{scope}};

	# The names the pull request branch's own refusal compares against, taken
	# from the topology this sub already holds, because composing that name
	# would otherwise build one topology per environment.
	my @names = keys %{$topology->{nodes}};

	for my $name (@{$topology->{order}}) {
		my $prior = $topology->{parent_of}{$name};
		$depth{$name} = defined $prior ? ($depth{$prior} // 0) + 1 : 0;
		next if %wanted && !$wanted{$name};
		push @scope, {
			env       => $name,
			type      => $top->type,
			branch    => $top->branch_for($name),
			pr_branch => $topology->{nodes}{$name}{require_pr}
				? $top->pr_branch_for($name, envs => \@names) : undef,
			prior_env => $prior,
			depth     => $depth{$name},
		};
	}

	return \@scope, $topology;
}

# }}}
# plan - the run's canonical record, computed from durable state alone {{{
#
# The composition.  It reads the applied record, walks the topology in the
# DAG order Genesis::Top::pipeline_topology gives, takes each branch's base
# from the newest marker that branch carries, and routes what stands after it.
# It writes nothing at all, which is what lets genesis pipeline-status and
# genesis propagate --dry-run render one record and never disagree.
#
# The record is held in memory and never persisted (D91).  Fields a later
# stage owns are present and null here, because a renderer that has to ask
# whether a key exists renders two shapes.
sub plan {
	my ($top, %opts) = @_;

	my $git = $opts{git}
		or bug("Genesis::CI::Walk::plan needs a git handle to read through");

	# Everything I11 lets the run read, read once.  A caller that has already
	# read it hands the answer in, because the command prints control's own
	# sha above the walk and a second read there would be a second reader of
	# the fact this sub exists to hold.
	#
	# The two options that shape a read of its own are refused beside a state
	# that was read already, because the state carries its own provider and
	# its own refreshed flag and a caller naming either would have handed in
	# a value this sub then dropped without a word.
	bug("Genesis::CI::Walk::plan was handed a state and a %s, and the state ".
		"already carries one, so the %s would be dropped", $_, $_)
		for grep {exists $opts{$_}} $opts{state} ? qw/provider refreshed/ : ();

	my $state = $opts{state} || read_durable_state(
		top       => $top,
		git       => $git,
		provider  => $opts{provider},
		refreshed => $opts{refreshed},
		outcome   => $opts{outcome},
	);

	my $control     = $state->{control}{branch};
	my $control_sha = $state->{control}{commit};
	my $applied     = $state->{applied};

	# The environments this run walks, each already carrying the branch its
	# own deployment slug names and the place it sits in the DAG.  One sub
	# builds the list and narrows it, so a run that was handed a scope and a
	# run that was not read the same answer over the environments they share.
	my ($scope, $topo) = scope_for($top, scope => $opts{scope});

	my $branches = $opts{branches} || {};

	# An environment is loaded and its certified commit read at most once a
	# run, because an ancestor outside the scope is still asked for both and
	# a topology of any depth would otherwise read the same record once per
	# descendant.  The load error is kept beside the environment, since the
	# reader below may ask long after the eval that raised it.
	my (%env_of, %load_error, %durable_of);
	my $env_for = sub {
		my ($name) = @_;
		unless (exists $env_of{$name}) {
			$env_of{$name} = eval {$top->load_env($name)};
			$load_error{$name} = _load_error($@) unless $env_of{$name};
		}
		return $env_of{$name};
	};
	my $durable_for_env = sub {
		my ($name) = @_;
		unless (exists $durable_of{$name}) {
			my $env = $env_for->($name);
			$durable_of{$name} = $env ? env_state(env => $env)
				: {state => 'unreadable', error => $load_error{$name}};
		}
		return $durable_of{$name};
	};

	# The ancestors of one environment, nearest first, taken from the whole
	# topology rather than from the scope, so an environment named on its own
	# is still held by an ancestor the run was not asked about.  The seen
	# guard is here because a parent map is built from edges and an edge list
	# that closes a loop would otherwise walk for ever.
	my $ancestors_of = sub {
		my ($name) = @_;
		my (@chain, %seen);
		my $up = $topo->{parent_of}{$name};
		while (defined $up && !$seen{$up}++) {
			push @chain, {
				name      => $up,
				env       => $env_for->($up),
				certified => $durable_for_env->($up),
			};
			$up = $topo->{parent_of}{$up};
		}
		return \@chain;
	};

	# The record's head is the durable state itself, so the two cannot
	# describe different repositories.
	my $record = {%$state, environments => []};

	for my $entry (@$scope) {
		my $name = $entry->{env};

		my $settled = $branches->{$name};
		my $env_record = {
			env            => $name,
			type           => $entry->{type},
			branch         => $settled ? $settled->{branch} : $entry->{branch},
			prior_env      => $entry->{prior_env},
			depth          => $entry->{depth},
			reading        => 'not-propagated',
			merged         => undef,
			deployed       => undef,
			certified      => undef,
			pending        => [],
			held           => [],
			proposed       => undef,
			hold           => undef,
			drifted        => undef,
			# Seeded from the scope's own composition rather than carrying
			# a second name for one branch.  The field already stood here
			# and already read null, and seeding it is what lets the arm
			# and the client read which environments would deliver into a
			# pull request without anybody adding a key to the record.
			pr             => $entry->{pr_branch}
				? {branch => $entry->{pr_branch}} : undef,
			manual         => undef,
			divergence     => $settled ? {
				state     => $settled->{state},
				ahead     => $settled->{ahead},
				behind    => $settled->{behind},
				# The pre-flight's own answer, carried across with the rest,
				# because the three states above cannot tell an orphan from
				# an ordinary divergence.  It is the encoder's own boolean,
				# as the manual marker below is, so --json writes true and
				# false for both rather than a word for one and a digit for
				# the other.
				unrelated => $settled->{unrelated}
					? JSON::PP::true() : JSON::PP::false(),
			} : undef,
			discovery      => undef,
			error          => undef,
			outcome        => undef,
			outcome_detail => undef,
		};
		push @{$record->{environments}}, $env_record;

		# D96's second stage stands around the walk as it stands around the
		# delivery, because a blueprint that raises while this environment's
		# fragments are enumerated is D78's error and ends this environment
		# alone.  No session is handed over, since the walk writes nothing
		# and there is no branch to put back.
		walk_one(record => $env_record, deliver => sub {

			# An environment the pre-flight has no branch record for has no
			# deployment branch on either side, which is D43's awaiting
			# outcome and nothing this walk can route a commit onto.
			return unless $settled;

			my $env = $env_for->($name);
			unless ($env) {
				$env_record->{error}   = $load_error{$name};
				$env_record->{outcome} = 'failed';
				return;
			}

			# D77's mark, which says where the apply could not render a
			# manifest for this environment.  It belongs to an environment
			# the applied pipeline knows, and an environment it does not
			# know has no pipeline subpath at all and carries null rather
			# than a mark, because the reading is about discovery and not
			# about membership.
			#
			# It is read here, off the environment already in hand, for the
			# reason the marker below is: a reader that asked later would
			# load every environment a second time and take a second exodus
			# reading for each of them.  A vault this run cannot reach is
			# the certified commit's refusal to raise a few lines down,
			# where the environment ends as failed, so the mark is asked for
			# without a guard of its own.
			my $pipeline_record = eval {$env->pipeline_record};
			$env_record->{discovery} = $pipeline_record
				? $pipeline_record->{discovery} : undef;

			# Whether a person rather than a trigger starts this
			# environment's deploy.  It is read here, off the environment
			# already in hand, because nothing below holds one and a reader
			# that asked later would load every environment a second time.
			# The key is inert under the manual provider, where every deploy
			# waits for a person anyway, and _automated is the one answer to
			# that question, so the marker on the row and the hold reason
			# beside it cannot come to disagree about what it means.
			#
			# It is the encoder's own boolean, so --json writes true and
			# false where the record's other booleans write them, and
			# _jsonable passes it through untouched.
			$env_record->{manual} =
				(_automated($state->{provider})
					&& $env->lookup('genesis.pipeline.manual', 0))
				? JSON::PP::true() : JSON::PP::false();

			# The certified commit, which is the control commit the
			# environment's last successful deployment was made from.  A
			# vault this run cannot reach makes the environment failed
			# rather than deployed, and the two states with no certified
			# commit are kept apart, because one of them is an environment
			# the pipeline was never applied to.
			#
			# This environment's durable state comes through the one reader,
			# so the hold arrives beside the certified commit rather than
			# being fetched again lower down.
			my $certified = $durable_for_env->($name);
			my $hold      = $certified->{hold};
			$env_record->{certified} = $certified;

			# The pull request this environment is already waiting on, which
			# is durable state like the certified commit beside it and is
			# read in the same place for that reason.  The field already
			# stood on the record and already read null.  Nothing the walk
			# decides turns on it; it is what a reader of the record is told
			# about the proposal the environment has open, and it is the
			# second of the two facts client_for_run reads when it is asked
			# whether the run needs the API at all (D57).  Asking for it
			# anywhere else would mean loading every environment again.
			#
			# It costs one vault read per environment in the walk, because the
			# record lives at its own path and nothing above has already
			# fetched it.
			$env_record->{proposed} = $env->proposed_record;

			if ($certified->{state} eq 'unreadable') {
				$env_record->{error}   = $certified->{error};
				$env_record->{outcome} = 'failed';
				return;
			}

			my $deployed = $certified->{state} eq 'certified' ? {
				control_commit => $certified->{control_commit},
				commit         => $certified->{commit},
				at             => $certified->{at},
			} : undef;
			$env_record->{deployed} = $deployed;

			# D60: an environment whose record carries no certified commit
			# is one the pipeline was never applied to, and nothing may be
			# delivered to it until genesis pipeline-apply has run.  It is
			# held rather than walked, so nothing stands pending for it, and
			# it holds everything below it through the same reading its
			# descendants take.  It stands ahead of the base, because
			# reading a base costs a walk of control over the environment's
			# own file and an environment this run will not walk has no use
			# for the answer.
			#
			# The hold is applied before the return, because a hold is
			# durable state like any other and D56 asks that an environment
			# with one standing never read as though it were fine.  Nothing
			# stands pending here, so the hold takes nothing; it says that
			# anything becoming due later stays blocked.
			if ($certified->{state} eq 'never-applied') {
				apply_hold($env_record, $hold);
				return;
			}

			# Under D2 the base is the local ref, which the pre-flight has
			# just settled, and under a dry run it is the ref a real run
			# would have moved that branch to.  What the walk starts from is
			# the marker that ref carries, or, where it carries none, the
			# commit before the one that introduced the environment (D61).
			#
			# The marker is taken back out of the answer rather than read a
			# second time, because an unseeded branch's base is a commit on
			# control and merged is a fact about what the branch has
			# received.
			my $ref = $settled->{assumed} // $settled->{branch};
			my ($base, $seeding) = walk_base(
				git      => $git,
				ref      => $ref,
				control  => $control_sha,
				# In list context, because prefixed answers a list and
				# asking it for one path in scalar context answers how many
				# it has.
				env_file => ($git->prefixed($env->file))[0],
			);
			my $marker = $seeding eq 'seeded' ? $base : undef;

			# D52's recovery, which only an environment in pull request mode
			# can want, because a deployment branch takes a commit it did not
			# write by merge alone and a merge is the one thing that can drop
			# the marker on its way in.  The base moves with the marker, because
			# a run that reported the recovery and then walked from before
			# the environment existed would propose the whole of control
			# again with the marker in its hand.
			if (!$marker && $env_record->{pr}) {
				$marker = Genesis::CI::PullRequest::certified_marker(
					$git, $opts{github}, $env_record,
					($opts{state_of} || {})->{$name}, ref => $ref);
				$base = $marker if $marker;
			}

			$env_record->{merged}  = $marker;
			# A repository with no applied record keeps the not-propagated
			# reading D94 gives it, whatever this branch happens to carry,
			# because nothing has been applied for a marker to be read
			# against.
			$env_record->{reading} = _reading($marker, $deployed) if $applied;

			# The one place walk_env's positional question meets the hold
			# readers.  The ancestors are read once for the environment and
			# the closure asks them of every commit, because the undeployed
			# set is the ancestor's set between its certified commit and
			# this one and so moves with the commit rather than with the
			# environment.
			# Every ancestor's durable state is read here, its hold record
			# included, and nothing below reads that hold: only the
			# ancestor's certified commit is asked for.  An ancestor whose
			# hold raises therefore ends this environment's turn, so the read
			# is a cost this line carries rather than a use.
			my $ancestors = $ancestors_of->($name);

			# D49: the gate this environment has not passed, read over the
			# range from its own certified commit to control's tip rather
			# than over the walk's own range.  A branch already delivered up
			# to a gate is walked from the gate itself, so a gate read over
			# the due commits alone would fall behind the base on the very
			# next run and stop holding anything, and the environment still
			# waits for the deploy that certifies it.
			#
			# An environment that has certified nothing has no such commit
			# to read from, and its marker will not do in place of one: the
			# first run delivers up to the gate and leaves the marker
			# standing on it, so the second run's range would start at the
			# gate and find no gate at all, and the commit D49 holds would
			# go out with nobody having deployed anything between.  Its
			# range starts where its own walk starts on an unseeded branch,
			# at the commit before the one that introduced it, so the gate
			# stands until a certification exists.
			my $since = $deployed
				&& $git->is_ancestor($deployed->{control_commit}, $control_sha)
				? $deployed->{control_commit}
				: $certified->{state} eq 'never-certified'
					? _before_introduction($git, $control_sha,
						($git->prefixed($env->file))[0])
					: $base;
			my @range    = control_commits($git, $control_sha, $since);
			my $released = released_gates($git, @range);

			# The oldest unreleased gate in the range, because a second gate
			# behind the first is reached only once the first is cleared.
			my $gate;
			for my $commit (@range) {
				$gate = gate_state(
					git       => $git,
					commit    => $commit->{sha},
					certified => $deployed ? $deployed->{control_commit} : undef,
					released  => $released,
				);
				last if $gate;
			}

			walk_env(
				git        => $git,
				env        => $env,
				record     => $env_record,
				control    => $control_sha,
				base       => $base,
				gate       => $gate,
				hold_check => sub {
					my ($commit, $files) = @_;
					return hold_for(
						git       => $git,
						commit    => $commit->{sha},
						files     => $files,
						ancestors => $ancestors,
						provider  => $record->{provider},
					);
				},
			);

			# D50: the hold is a fact about the walk and not about the
			# branch, so it is applied once the walk has computed what is
			# due, which is what leaves the preview and the report something
			# to show.  A vault that refuses the read ends this environment
			# rather than answering no hold, because delivering on a hold
			# nobody could read is the one mistake the record exists to stop.
			apply_hold($env_record, $hold);
			return;
		});
	}

	return $record;
}

# }}}
# }}}
### The delivery {{{

# deliver_pending - hand each pending commit to the single writer {{{
#
# One control commit becomes one commit on the deployment branch, carrying
# the marker D34 fixes and mirroring the set at that commit, and the writer
# asserts the snapshot invariant on the index before each commit under D82.
# The assertion therefore runs after every delivery and not once at the end,
# which is the routing half of I7.
sub deliver_pending {
	my (%args) = @_;

	my $session = $args{session};
	my $env     = $args{env};
	my $record  = $args{record};

	# The ref each delivery is worked out against, which advances as the
	# deliveries do.  A writing run leaves it undefined and every delivery
	# reads the branch it has just committed to.  A preview commits nothing,
	# so the branch stands still and the base is carried by hand: it starts
	# at the ref the pre-flight would have moved the branch to, and after
	# each previewed delivery it becomes the tree that delivery would have
	# produced.  Without that the second commit's report is the union of
	# both deliveries and the first commit's files are named twice.
	my $base = $args{base};

	my @overwrote;
	for my $pending (@{$record->{pending}}) {
		my $message = Genesis::CI::Marker::build(
			$pending->{control_commit}, $env->name
		);
		my $result = $session->apply_files(
			$pending->{control_commit},
			env     => $env,
			changed => $pending->{files},
			deleted => [],
			message => $message,
			($args{dry_run} ? (dry_run => 1) : ()),
			($base ? (base => $base) : ()),
		);
		$pending->{commit}    = $result->{commit};
		$pending->{delivered} = $result->{delivered};
		$pending->{removed}   = $result->{removed};
		$pending->{overwrote} = $result->{overwrote};
		push @overwrote, @{$result->{overwrote} || []};
		$base = $result->{tree} if $args{dry_run} && $result->{tree};
	}

	$record->{overwrote} = \@overwrote;

	# The branch's newest marker now names the last commit delivered, so the
	# record says so too.  A preview moved nothing, and merged is a fact
	# about the branch rather than about the run, so it stays where the
	# marker put it.
	$record->{merged} = $record->{pending}[-1]{control_commit}
		if !$args{dry_run} && @{$record->{pending}};

	return $record;
}

# }}}
# }}}
### Internals {{{

# _reading - which of D94's four words describes this branch {{{
#
# A branch with no marker has been cut and never delivered to, which is
# unseeded.  A branch whose marker names the control commit the environment
# last deployed from is deployed, and one whose marker has moved past it is
# pending-deploy.  A branch we could read no deployment for keeps the
# not-propagated reading, because claiming either of the other two would be
# claiming something no durable state said.
sub _reading {
	my ($marker, $deployed) = @_;

	return 'unseeded' unless defined $marker && length $marker;

	my $certified = $deployed ? $deployed->{control_commit} : undef;
	return 'not-propagated' unless defined $certified && length $certified;

	return $marker eq $certified ? 'deployed' : 'pending-deploy';
}

# }}}
# _before_introduction - the commit before E, or the whole of control {{{
#
# The commit a range starts after so that E is the first commit in it.  An
# environment control has never carried a file for, and one whose file was
# introduced on control's own first commit, both answer undefined, which
# control_commits reads as the whole of control.
#
# A root commit has no parent, and the whole of control is then what the
# caller wants, because control's first commit is where E already is.
#
# Two callers ask it.  walk_base asks for a branch that carries no marker,
# and plan asks for an environment that has certified nothing, because a
# gate range taken from that environment's marker instead would start at the
# gate the last run delivered to and so find no gate at all.
sub _before_introduction {
	my ($git, $control, $env_file) = @_;

	my $e = introducing_commit($git, $control, $env_file);
	return undef unless defined $e;

	my ($parent, $rc) = run(
		{dir => $git->root, stderr => 0},
		'git', 'rev-parse', "$e^"
	);
	$parent = '' unless defined $parent;
	chomp $parent;
	# One line and no more.  Stripping every space out of whatever came back
	# would turn a surprising answer, such as the several parents of a merge
	# git was never meant to be asked about here, into one run-on string that
	# reads as a sha and resolves to nothing.
	$parent = '' if $parent =~ /\n/;
	return (!$rc && length $parent) ? $parent : undef;
}

# }}}
# _load_error - a short reason from a load that raised {{{
#
# The record carries one line per environment, because the report prints it
# beside the environment's name and bail's own text is several decorated
# lines of which the first substantive one says what went wrong.
sub _load_error {
	my ($err) = @_;
	return 'unknown reason' unless defined($err) && length($err);
	my ($first) = grep {/\S/} split /\n/, "$err";
	$first //= 'unknown reason';
	$first =~ s/^\s+|\s+$//g;
	return $first;
}

# }}}
# }}}

1;
