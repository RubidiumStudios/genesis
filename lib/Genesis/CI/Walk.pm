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
use Genesis::CI::Marker;

our @EXPORT_OK = qw/
	plan changed_set route_commit undeployed_set overlap
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

# control_commits - the control commits after a base, oldest first {{{
#
# Control is linear under D31, so first-parent order is control order and
# --reverse gives us the oldest due commit first.  An undefined base means
# the whole of control, which only happens for an unseeded branch whose E
# the caller has not resolved yet.
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
# without meaning that.  A commit whose content here is only non-triggering
# is not routed at all, and its content arrives in the next delivery's
# snapshot, since a delivery is a mirror and control is linear.
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
	# how the dev kit and the reaction scripts join the set, so a path is
	# in the set where the set names it or where the set names a directory
	# it lies in.  Without that a commit touching the kit routes to nobody,
	# and the kit is the one kind a pipeline exists to prove in lab first.
	my @dirs = grep {m{/$}} keys %$kinds;

	my (@hit, @carried_hit);
	for my $path (split /\n/, $out) {
		next unless $path =~ /\S/;
		my $mark = $kinds->{$path};
		unless (defined $mark) {
			my ($dir) = grep {index($path, $_) == 0} @dirs;
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
# D68: only triggering content routes a commit.  A commit whose content for
# this deployment is only non-triggering is skipped exactly as one that
# touches nothing in the set is, and it records no outcome, because the next
# delivery's mirror already carries it.  That holds behind a hold as well as
# in front of one, so a config change standing behind a held commit is not
# reported as waiting on anything.  The carried list travels with the routed
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
	return () if $rc || !$out;

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

		my $env = eval {$top->load_env($name)};
		unless ($env) {
			$env_record->{error} = _load_error($@);
			next;
		}

		# The certified commit, which is the control commit the environment's
		# last successful deployment was made from.  A vault this run cannot
		# reach leaves it null, and the reading says so rather than claiming
		# the branch is deployed.
		my $deployed = eval {
			my $with = $env->with_vault or return undef;
			my $dep  = $with->deployments->latest_successful or return undef;
			return {
				control_commit => $dep->lookup('git.control_commit'),
				commit         => $dep->lookup('git.commit'),
				at             => $dep->lookup('dated'),
			};
		};
		$env_record->{deployed} = $deployed;

		# Under D2 the base is the local ref, which the pre-flight has just
		# settled, and under a dry run it is the ref a real run would have
		# moved that branch to.
		my $ref  = $settled->{assumed} // $settled->{branch};
		my $base = Genesis::CI::Marker::newest($git, $ref);
		$env_record->{merged}  = $base;
		$env_record->{reading} = _reading($base, $deployed);

		walk_env(
			git        => $git,
			env        => $env,
			record     => $env_record,
			control    => $control_sha,
			base       => $base,
			# The one place walk_env's positional question meets the hold
			# readers.  Nothing holds a commit yet, so every due commit is
			# pending and the run delivers all of it.
			hold_check => sub {undef},
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
