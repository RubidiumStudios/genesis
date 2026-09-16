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
use Genesis qw/run bug/;
use Genesis::CI::Marker qw/STAGE RELEASE_STAGE/;
use Genesis::CI::RunFailure;

our @EXPORT_OK = qw/
	plan changed_set route_commit undeployed_set overlap
	certified_for hold_for hold_reason held_qualifier
	gate_state released_gates
	introducing_commit walk_base
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
sub introducing_commit {
	my ($git, $control, $env_file) = @_;

	my ($out, $rc) = run(
		{dir => $git->root, stderr => 0},
		'git', 'log', '--first-parent', '--diff-filter=A', '--format=%H',
		$control, '--', $env_file
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

	my $e = introducing_commit($git, $args{control}, $args{env_file});
	return (undef, 'unseeded') unless defined $e;

	# A root commit has no parent, and the whole of control is then what the
	# walk wants, because control's first commit is where E already is.
	my ($parent, $rc) = run(
		{dir => $git->root, stderr => 0},
		'git', 'rev-parse', "$e^"
	);
	$parent = '' unless defined $parent;
	$parent =~ s/\s+//g;
	return ((!$rc && length $parent) ? $parent : undef, 'unseeded');
}

# }}}
# control_commits - the control commits after a base, oldest first {{{
#
# Control is linear under D31, so first-parent order is control order and
# --reverse gives us the oldest due commit first.  An undefined base means
# the whole of control, which is what walk_base answers for a branch with no
# marker whose environment was introduced on control's own first commit,
# since there is no commit before that one to start after.
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
		my $automated = defined $provider && $provider ne 'manual';
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
sub released_gates {
	my ($git, @commits) = @_;

	my %released;
	for my $commit (@commits) {
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
			$released{$full} = 1;
		}
	}
	return \%released;
}

# }}}
# }}}
### The words {{{

# hold_reason - one held commit's reason, in the form the design fixes {{{
#
# Publish and outcomes spells these exactly, so that genesis propagate, its
# dry run, and the routing column of genesis pipeline-status can never
# disagree about a word.  The overlap form carries the ancestor's own state
# under D72 and the never-certified form carries no such clause, an
# environment that has never deployed being already clear about why.
sub hold_reason {
	my ($held) = @_;

	my $reason = $held->{reason} // '';

	return sprintf('held by %s (%s), %s %s',
		$held->{ancestor}, join(', ', @{$held->{ancestor_files} || []}),
		$held->{ancestor}, $held->{ancestor_state})
		if $reason eq 'ancestor-overlap';

	if ($reason eq 'ancestor-uncertified') {
		# An ancestor the run could not read at all is neither certified nor
		# uncertified, and saying it had never certified a commit would be
		# stating something no record said.
		return sprintf('held by %s, which could not be read', $held->{ancestor})
			if ($held->{ancestor_state} // '') eq 'unreadable';
		return sprintf('held by %s, which has never certified a commit',
			$held->{ancestor});
	}

	# The gate's form carries the trailer's own text and no held prefix,
	# because the gate is a step somebody has to take rather than a state
	# the pipeline works its own way out of.
	return sprintf('gate: %s', $held->{gate_reason})
		if $reason eq 'gate-ahead';

	return sprintf('held behind control@%s',
		substr($held->{behind}, 0, 7)) if $reason eq 'behind-held-commit';

	return sprintf('held (%s)', $reason);
}

# }}}
# held_qualifier - one environment's own held phrase, or undef {{{
#
# D54's qualifier, which says what the environment waits for rather than why
# any one commit is held.  An environment the pipeline was never applied to
# waits for that command, one whose environment the run could not read has
# failed instead, and one holding commits behind an ancestor waits for that
# ancestor to certify the commit it has not deployed.
sub held_qualifier {
	my ($record) = @_;

	my $certified = $record->{certified} // {};
	return 'held, awaiting pipeline-apply'
		if ($certified->{state} // '') eq 'never-applied';

	my ($first) = @{$record->{held} || []};
	return undef unless $first;

	# The environment named is whoever has to certify, which is the ancestor
	# where an ancestor holds the commit and the environment itself where a
	# gate does, and the commit named is the one that certification has to
	# reach, which is the gate itself rather than the commit it holds.
	return sprintf('held, awaiting deployment (%s at control@%s)',
		$first->{ancestor} // $record->{env},
		substr($first->{gate} // $first->{control_commit}, 0, 7));
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

		push @{$record->{pending}}, {
			control_commit => $commit->{sha},
			subject        => $commit->{subject},
			files          => $files,
			carried        => $routed->{carried},
		};
	}

	return $record;
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

	my $control     = $top->control_branch;
	my $control_sha = $git->sha($control);

	# The pipeline's own facts.  A repository whose vault this run cannot
	# reach leaves the field null rather than ending the run, because every
	# environment below still has a branch, a marker, and a set, and the
	# applied record decides nothing the walk routes on.
	my $applied = eval {$top->applied_record};

	my $topo  = $top->pipeline_topology;
	my @order = @{$topo->{order}};

	my %in_scope = map {$_ => 1} @{$opts{scope} || \@order};

	# The depth each environment sits at, taken from the whole topology and
	# not from the scope, so an environment named on its own still reads the
	# depth the pipeline gives it.
	my %depth;
	for my $name (@order) {
		my $parent = $topo->{parent_of}{$name};
		$depth{$name} = defined $parent ? ($depth{$parent} // 0) + 1 : 0;
	}

	my $branches = $opts{branches} || {};

	# An environment is loaded and its certified commit read at most once a
	# run, because an ancestor outside the scope is still asked for both and
	# a topology of any depth would otherwise read the same record once per
	# descendant.  The load error is kept beside the environment, since the
	# reader below may ask long after the eval that raised it.
	my (%env_of, %load_error, %certified_of);
	my $env_for = sub {
		my ($name) = @_;
		unless (exists $env_of{$name}) {
			$env_of{$name} = eval {$top->load_env($name)};
			$load_error{$name} = _load_error($@) unless $env_of{$name};
		}
		return $env_of{$name};
	};
	my $certified_for_env = sub {
		my ($name) = @_;
		unless (exists $certified_of{$name}) {
			my $env = $env_for->($name);
			$certified_of{$name} = $env ? certified_for($env)
				: {state => 'unreadable', error => $load_error{$name}};
		}
		return $certified_of{$name};
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
				certified => $certified_for_env->($up),
			};
			$up = $topo->{parent_of}{$up};
		}
		return \@chain;
	};

	my $record = {
		# The pipeline's own label, which is the name the configuration
		# gives it and not the deployment type.  A repository that names
		# none leaves it null, and the renderer falls back to the type.
		pipeline     => $top->config->get('pipeline.name'),
		provider     => $opts{provider} // $top->pipeline_provider_type,
		control      => {branch => $control, commit => $control_sha},
		applied      => $applied,
		refreshed    => $opts{refreshed} // 1,
		environments => [],
	};

	for my $name (@order) {
		next unless $in_scope{$name};

		my $settled = $branches->{$name};
		my $env_record = {
			env            => $name,
			type           => $top->type,
			branch         => $settled ? $settled->{branch} : $top->branch_for($name),
			prior_env      => $topo->{parent_of}{$name},
			depth          => $depth{$name},
			reading        => 'not-propagated',
			merged         => undef,
			deployed       => undef,
			certified      => undef,
			pending        => [],
			held           => [],
			proposed       => undef,
			hold           => undef,
			drifted        => undef,
			pr             => undef,
			manual         => undef,
			divergence     => $settled ? {
				state  => $settled->{state},
				ahead  => $settled->{ahead},
				behind => $settled->{behind},
			} : undef,
			discovery      => undef,
			error          => undef,
			outcome        => undef,
			outcome_detail => undef,
		};
		push @{$record->{environments}}, $env_record;

		# An environment the pre-flight has no branch record for has no
		# deployment branch on either side, which is D43's awaiting outcome
		# and nothing this walk can route a commit onto.
		next unless $settled;

		my $env = $env_for->($name);
		unless ($env) {
			$env_record->{error} = $load_error{$name};
			next;
		}

		# The certified commit, which is the control commit the environment's
		# last successful deployment was made from.  A vault this run cannot
		# reach makes the environment failed rather than deployed, and the
		# two states with no certified commit are kept apart, because one of
		# them is an environment the pipeline was never applied to.
		my $certified = $certified_for_env->($name);
		$env_record->{certified} = $certified;
		if ($certified->{state} eq 'unreadable') {
			$env_record->{error} = $certified->{error};
			next;
		}

		my $deployed = $certified->{state} eq 'certified' ? {
			control_commit => $certified->{control_commit},
			commit         => $certified->{commit},
			at             => $certified->{at},
		} : undef;
		$env_record->{deployed} = $deployed;

		# Under D2 the base is the local ref, which the pre-flight has just
		# settled, and under a dry run it is the ref a real run would have
		# moved that branch to.  What the walk starts from is the marker that
		# ref carries, or, where it carries none, the commit before the one
		# that introduced the environment (D61).
		#
		# The marker is taken back out of the answer rather than read a
		# second time, because an unseeded branch's base is a commit on
		# control and merged is a fact about what the branch has received.
		my $ref = $settled->{assumed} // $settled->{branch};
		my ($base, $seeding) = walk_base(
			git      => $git,
			ref      => $ref,
			control  => $control_sha,
			# In list context, because prefixed answers a list and asking it
			# for one path in scalar context answers how many it has.
			env_file => ($git->prefixed($env->file))[0],
		);
		my $marker = $seeding eq 'seeded' ? $base : undef;
		$env_record->{merged}  = $marker;
		$env_record->{reading} = _reading($marker, $deployed);

		# D60: an environment whose record carries no certified commit is one
		# the pipeline was never applied to, and nothing may be delivered to
		# it until genesis pipeline-apply has run.  It is held rather than
		# walked, so nothing stands pending for it, and it holds everything
		# below it through the same reading its descendants take.
		next if $certified->{state} eq 'never-applied';

		# The one place walk_env's positional question meets the hold
		# readers.  The ancestors are read once for the environment and the
		# closure asks them of every commit, because the undeployed set is
		# the ancestor's set between its certified commit and this one and
		# so moves with the commit rather than with the environment.
		my $ancestors = $ancestors_of->($name);

		# D49: the gate this environment has not passed, read over the range
		# from its own certified commit to control's tip rather than over the
		# walk's own range.  A branch already delivered up to a gate is
		# walked from the gate itself, so a gate read over the due commits
		# alone would fall behind the base on the very next run and stop
		# holding anything, and the environment still waits for the deploy
		# that certifies it.
		my $since = $deployed
			&& $git->is_ancestor($deployed->{control_commit}, $control_sha)
			? $deployed->{control_commit} : $base;
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
		);
		$pending->{commit}    = $result->{commit};
		$pending->{delivered} = $result->{delivered};
		$pending->{removed}   = $result->{removed};
		$pending->{overwrote} = $result->{overwrote};
		push @overwrote, @{$result->{overwrote} || []};
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
