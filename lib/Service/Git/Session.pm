package Service::Git::Session;

# The branch session: one object owns "leave the current branch, do work,
# come back", and nothing outside it switches branches.  It belongs to one
# Service::Git handle and so to one working tree, which is what keys I9.

use strict;
use warnings;

use Genesis qw/bail run trace/;
use Genesis::CI::RunFailure;
use Genesis::Exit qw/TEMPFAIL DATAERR SOFTWARE/;
use Cwd qw/getcwd/;
use Fcntl qw/:flock/;
use IO::Handle;

### Constructor {{{

# new - build a session on one handle, without opening it {{{
#
# The control option is the branch abort never resets, which is I2 as D32
# revised it.  The session is told the name rather than reading it, because
# the accessor that knows it lands at M4 and the session is built at M5.
sub new {
	my ($class, $git, %opts) = @_;
	bail("A branch session needs a Service::Git handle") unless $git;
	return bless {
		git       => $git,
		control   => $opts{control},
		active    => 0,
		finished  => 0,
		origin    => undef,
		on        => undef,
		switched  => {},
		committed => {},
		lock      => undef,
	}, $class;
}

# }}}
# }}}

### Accessors {{{

# git - the handle this session was built on {{{
#
# The writer that lands at M8 already holds the session, and reaching git
# through it keeps that writer from building a second handle for the same
# working tree, which would key a second session and break I9.
sub git { $_[0]->{git} }

# }}}
# active - is this session open {{{
sub active { $_[0]->{active} }

# }}}
# finished - did finish complete its clean path {{{
#
# D84 makes a finished session the precondition for the post-deploy child of
# M15, so a session that went out through abort answers false here and the
# child is never spawned behind a run that failed.
sub finished { $_[0]->{finished} ? 1 : 0 }

# }}}
# origin - the branch, the HEAD sha, and the cwd begin recorded {{{
sub origin { $_[0]->{origin} }

# }}}
# on - the branch or commit the session last switched to {{{
sub on { $_[0]->{on} }

# }}}
# modified_paths - the tracked paths that are modified or staged now {{{
#
# The words are git's own, out of `git status --porcelain`, so a caller
# naming them to an operator names what the operator would see.  Untracked
# files are left out, because D84 says they block nothing, and this is the
# one reader the three verbs and the deploy of M13 all ask, so the list an
# operator is shown is the same list wherever they are shown it.
sub modified_paths {
	my ($self) = @_;
	my $status = $self->{git}->status;
	return [sort grep {($status->{$_} // '') !~ /^\?\?/} keys %$status];
}

# }}}
# committed_branches - the branches this session committed to {{{
#
# The writer lands at M8, so the session works out for itself what it wrote
# rather than being told.  A branch whose tip differs from the tip recorded
# at switch is one this session committed to, which is exactly the set D32
# has abort reset back to T, and a branch the writer recorded outright joins
# it, because a commit can leave a tip where it was.
#
# Control is filtered out of both halves.  I2 keeps committed work on control
# whole, so control is never in the set the abort resets, however it got
# there.
sub committed_branches {
	my ($self) = @_;
	my $git = $self->{git};
	my $control = $self->{control} // '';

	my %moved = map {($_ => 1)} grep {
		my $now = eval { $git->sha($_) } // '';
		$now && $now ne ($self->{switched}{$_} // '');
	} keys %{$self->{switched}};

	return grep {$_ ne $control}
		sort keys %{{%{$self->{committed}}, %moved}};
}

# }}}
# }}}

### The verbs {{{

# begin - the pre-flight, the clean assertion, and the record {{{
#
# No lock is taken here.  The lock guards switching and switch takes it, so
# a command that opens a session and never switches never touches it.
sub begin {
	my ($self) = @_;
	my $git = $self->{git};

	# I9: within one working tree sessions are sequential and never nested.
	# A command that needs control after a deployment branch finishes the
	# first session before it begins the second.
	bail(
		"A branch session is already open in #C{%s}.\n\n".
		"Sessions are sequential and are never nested, so a command that ".
		"needs another branch finishes the open session first.",
		$git->root
	) if $self->{active};

	$git->preflight;

	# Clean means what is_clean means under D84: no tracked modification and
	# nothing staged, with untracked files ignored.  An operator's scratch
	# file blocks no session, and no session removes one.
	unless ($git->is_clean) {
		my @dirty = @{$self->modified_paths};
		bail(
			"Working tree has uncommitted changes, and this command switches ".
			"branches.\n\nCommit or stash them first:\n%s",
			join("", map {"  - $_\n"} @dirty)
		);
	}

	$self->{origin} = {
		branch => $git->current_branch,
		head   => $git->sha('HEAD'),
		cwd    => getcwd(),
	};
	# Everything the last session recorded is cleared here rather than at
	# finish, because the handle hands out one session and a caller that
	# opens a second one would otherwise read the first one's answers: a
	# session still open would say it had finished, one that had not
	# switched would name the branch the last one stood on, and an abort
	# would reset a branch an earlier session wrote.
	$self->{active}    = 1;
	$self->{finished}  = 0;
	$self->{on}        = undef;
	$self->{switched}  = {};
	$self->{committed} = {};
	$self->_register_net;

	trace("Service::Git::Session: began on %s", $self->{origin}{branch});
	return $self;
}

# }}}
# switch - change to a branch or stand on a commit {{{
#
# Runs from the repository root, because the branch being checked out may
# not carry the directory we are standing in, and returns to that directory
# only if the checkout kept it.
#
# The lock is taken here and nowhere else, because D46 has it guard
# switching alone: a command that never switches never touches it, so a kit
# hook that shells out to genesis inside a deploy is unaffected while one
# that tries to switch under that deploy is refused by name.  The directory
# we came from is handed along, so a refusal stands us back where we were
# rather than leaving us at the root.
#
# D94 has both flags of D87 share this one path: --redeploy checks the
# deployed commit out and deploys it, --as-deployed checks the same commit
# out for a secrets command, and finish restores the branch begin recorded
# either way, so a detached HEAD never outlives the session.  Standing on a
# commit is safe because begin asserted the tree clean and finish catches
# anything that wrote into it.
#
# The tip is recorded for a branch and not for a commit, because the record
# is what committed_branches reads to say which branches this session moved
# and a commit is not one of them.
sub switch {
	my ($self, $target, %opts) = @_;
	my $git = $self->{git};
	bail("A branch change was attempted with no session open in %s.",
		$git->root) unless $self->{active};

	# Asked before anything moves, so a record naming a commit this
	# repository does not have is refused with the working tree still
	# exactly as the operator left it.
	my $is_branch = $self->_is_branch($target);
	$self->_verify_reachable($target, $opts{record}) unless $is_branch;

	my $cwd = getcwd();
	chdir($git->root)
		or bail("Unable to enter git root %s: %s", $git->root, $!);

	$self->_take_lock($cwd);
	$self->_through_the_door(sub {
		$is_branch ? $git->checkout($target) : $git->checkout_detached($target);
	});
	chdir($cwd) if -d $cwd;

	$self->{on} = $target;
	$self->{switched}{$target} //= eval { $git->sha($target) } if $is_branch;
	return $self;
}

# }}}
# finish - re-read, restore, verify, and release {{{
#
# Re-reads the branch and the cleanliness rather than assuming them, which
# is the restore clause of I7.  A tracked modification here is a defect and
# not a by-product under D84, because the deploy writes no git and the
# exodus store's own cleanup hands the tree back as it found it, so what is
# left is a kit hook that wrote into the repository or a deploy that died
# before cleaning up.  It takes the abort path, which names the files.
sub finish {
	my ($self) = @_;
	my $git = $self->{git};
	return $self unless $self->{active};

	unless ($git->is_clean) {
		my @modified = @{$self->modified_paths};

		# The files are named here, in the error the caller is handed, and
		# abort is told so: one list, in the message that carries the whole
		# story, rather than the same list twice under two headings.
		return $self->abort(sprintf(
			"Something wrote into the repository during this command, which ".
			"it should not have done:\n%s\nThese changes are being discarded.",
			join("", map {"  - $_\n"} @modified)
		), named => 1);
	}

	$self->_restore;
	$self->_release_lock;
	$self->{active}   = 0;
	$self->{finished} = 1;
	return $self;
}

# }}}
# finish_if_clean - finish, or decline and leave the session open {{{
#
# M13's deploy wants to name the modified files in its own words before it
# decides what to do, so it asks for the finish and is given a false back
# rather than a death.  The session stays open, so the caller can name the
# files through modified_paths and then abort.
#
# The answer is read back off the session rather than assumed from the clean
# tree, so that a true answer means what it says.  finish is a no-op on a
# session that never opened and on one that went out through abort, and
# either of those would otherwise be reported as a finish that happened.
sub finish_if_clean {
	my ($self) = @_;
	return 0 if @{$self->modified_paths};
	$self->finish;
	return $self->finished;
}

# }}}
# abort - discard, reset, restore, verify, and die {{{
#
# D32 fixes what it reaches: every deployment branch this session committed
# to goes back to T, and control is never touched, because committed work on
# control in L is never discarded.  The discard reaches the index as well as
# the tree, which is H1, and it names the modified files before it throws
# them away so the evidence reaches the operator.  Nothing here removes an
# untracked file, so an operator's scratch file survives under D84.
sub abort {
	my ($self, $error, %opts) = @_;
	my $git = $self->{git};
	$error = 'the session was aborted' unless defined $error && length $error;
	$error =~ s/\s+$//;

	unless ($self->{active}) {
		bail("%s", $error);
	}
	$self->{active} = 0;

	# Name what is about to go, before it goes, unless the caller has named
	# it already in the error it handed us, which finish does.
	my @modified = @{$self->modified_paths};
	Genesis::error("Discarding uncommitted changes in #C{%s}:\n%s",
		$git->root, join("", map {"  - $_\n"} @modified))
		if @modified && !$opts{named};

	my @reset = $self->committed_branches;
	my $discard_error;
	my $restore_error;
	eval {
		chdir($git->root)
			or die sprintf("unable to enter the git root %s: %s\n",
				$git->root, $!);

		# The tree and the index both, which is the half the baseline
		# cleanup missed.  The answer is read rather than dropped: a
		# discard that failed leaves those changes in the tree, every
		# reset and checkout below would fail over them, and carrying on
		# in silence would either stand the operator back on control with
		# somebody else's changes or leave them the failed checkout to
		# puzzle out.
		unless (run({ dir => $git->root, passfail => 1 },
			'git', 'reset', '--hard', 'HEAD')) {
			$discard_error = 1;
			die "the discard failed\n";
		}

		$self->_reset_to_remote($_) for @reset;
		$self->_restore;
		1;
	} or do {
		$restore_error = $@ || 'the restore failed for an unknown reason';
		$restore_error =~ s/\s+$//;
	};

	$self->_release_lock;

	# Said before the restore failure below, because where both are true
	# this one is why: nothing could be put back over changes that could
	# not be thrown away.  It is a defect rather than a condition an
	# operator caused, so it exits SOFTWARE.
	bail({exitcode => SOFTWARE},
		"%s\n\n".
		"The uncommitted changes in #C{%s} could not be discarded, so the ".
		"working tree still holds them and we have left it standing on ".
		"#C{%s}.\n\n".
		"Put the working tree back by hand before running anything else ".
		"here.",
		$error, $git->root, $self->_standing_on
	) if $discard_error;

	# H2: a restore that fails is loud.  We are on the wrong branch, and
	# nothing a retry does moves us, so the operator is told all three
	# facts at once rather than discovering them one command later.
	bail(
		"%s\n\n".
		"We then failed to return to #C{%s}: %s\n\n".
		"You are standing on #C{%s}.  Put the working tree back by hand ".
		"before running anything else here.",
		$error, $self->{origin}{branch}, $restore_error,
		$self->_standing_on
	) if $restore_error;

	bail("%s", $error);
}

# }}}
# }}}

### The writer {{{

# apply_files - deliver one control commit onto this session's branch {{{
#
# The single writer.  D69 makes a delivery a mirror and not an overlay, so the
# postcondition is that the branch's tree equals the propagation set as it
# stood at the delivered control commit, which is I7 stated as this method's
# contract.  The changed and deleted lists a caller passes are the diff it has
# already computed, and they are there to skip blobs the delivery cannot have
# moved and to name files in the run's report.  They never decide what is
# delivered, and changed is read only to keep the paths the delivery was
# asked to move out of overwrote.
#
# The set is still read off the tree the session is standing on, which is the
# deployment branch, and only the membership is resolved at the source commit.
# The step that adds the at-commit reader moves the first read too, and until
# it lands a repository that restructured between the two would be read wrong.
sub apply_files {
	my ($self, $source_sha, %opts) = @_;

	my $env = $opts{env}
		or bail("apply_files needs the environment whose set it delivers");
	my $message = $opts{message}
		or bail("apply_files needs its caller's commit message, since it builds none");

	my $git = $self->git;

	# An empty set is refused before anything is read off the index, because
	# every path the branch holds is outside an empty set and the mirror would
	# strip the branch bare.  The postcondition would still hold afterwards,
	# so the check that runs before the commit would not fire either, and the
	# run would report a success over a branch with nothing on it.  No
	# environment has a legitimately empty set, so an empty one is a reader
	# that could not answer rather than an answer, which is D82's system
	# failure and not this environment's.
	my @set = $env->propagation_files;
	bail({exitcode => SOFTWARE},
		"The propagation set of #C{%s} is empty, so there is nothing to ".
		"deliver onto #C{%s}.\n\n".
		"A delivery is a mirror, so delivering an empty set would take ".
		"every file off that branch.  Nothing has been written.",
		$env->name, $git->current_branch
	) unless @set;

	# The second door onto the same ending.  A set that is full but whose
	# paths the source tree holds none of leaves every path on the branch
	# outside the membership, so the whole branch is staged for removal, the
	# commit succeeds because a removal is something to commit, and the
	# postcondition holds over the emptied branch so nothing downstream fires
	# either.  It is what a handle carrying the wrong prefix produces, since
	# the set then comes back deployment-root-relative and matches nothing at
	# the commit.  No real control commit holds none of an environment's set,
	# so this says the set and the commit do not describe one repository.
	my %in_set = map { $_ => 1 } $self->_members_at($source_sha, @set);
	bail({exitcode => SOFTWARE},
		"None of the %d paths in the propagation set of #C{%s} is in the tree ".
		"of #C{%s}, so there is nothing to deliver onto #C{%s}.\n\n".
		"A delivery is a mirror, so delivering nothing would take every file ".
		"off that branch.  Nothing has been written.\n\n".
		"The set and the commit do not describe the same repository.",
		scalar(@set), $env->name, $source_sha, $git->current_branch
	) unless %in_set;

	# The mirror's removing half.  Every path the branch holds that the set no
	# longer holds goes, which is how a leftover init, a root-level file after
	# a restructure, and a path that dropped out of track_additional_files
	# leave the branch.  Under D66 the branch belongs to one deployment root,
	# so nothing else on it is anybody's to keep.
	#
	# A removal git refuses is silent, because rm runs under passfail and
	# hands the handle back whatever git made of it, so nothing here notices a
	# path that stayed.  A refused removal is caught by the check below
	# instead, which is the design's own argument for asserting the
	# postcondition rather than trusting the sequence.
	my @on_branch = $git->ls_files;
	my @stale     = grep { !$in_set{$_} } @on_branch;

	# The diff against the source is the optimisation, so the writer touches
	# only the paths whose blob differs or that the branch does not hold.
	my %differs = map { $_ => 1 } $git->diff_names('HEAD', $source_sha, @set);
	my @to_write = grep { $differs{$_} } sort keys %in_set;

	# D33 says an overwrite is never silent.  A path the mirror overwrote that
	# differed from the source although the delivered commit did not change it
	# is a hand edit the branch was carrying, so it is named per file.  A path
	# the branch does not hold at all is not an edit, it is an addition.
	#
	# The report is worked out here, above the first write, because afterwards
	# the branch holds the source and nothing on disk still says what it held
	# before.
	my %held    = map {$_ => 1} @on_branch;
	my %changed = map {$_ => 1} @{$opts{changed} || []};
	my @overwrote = grep {$held{$_} && !$changed{$_}} @to_write;

	# D44 makes the dry run the one preview, and it writes nothing at all, so
	# nothing is staged, no commit is made, and D82's two assertions never run,
	# because the sub returns before either is reached with nothing staged
	# for them to read.  The preview still reports
	# what would land and what would go, since the mirror is the only thing
	# that knows either list, and the run's report names both per environment
	# and per control commit.
	#
	# The return sits here rather than at the top of the sub, because the
	# three lists it carries are worked out above it and the first write is
	# the line below it.
	if ($opts{dry_run}) {
		return {
			commit    => undef,
			dry_run   => 1,
			delivered => [@to_write],
			removed   => [@stale],
			overwrote => [@overwrote],
		};
	}

	$git->rm(@stale) if @stale;
	$git->checkout_file($source_sha, $_) for @to_write;

	# D82 checks the postcondition on the index, before the commit, so a
	# failed check never becomes a commit.  It is two assertions and not one,
	# because the source tree carries every environment's files and no
	# whole-tree comparison is possible.
	#
	# The first is that the index matches the source over the set's own
	# paths, which catches a file the delivery could not write and a blob
	# somebody else staged in front of it.
	my $branch = $git->current_branch;
	unless ($git->diff_cached_quiet($source_sha, @set)) {
		die Genesis::CI::RunFailure->fatal(
			message => 'the staged propagation set does not match its source',
			branch  => $branch,
			source  => $source_sha,
			paths   => [$git->diff_cached_names($source_sha, @set)],
		);
	}

	# The second is that the index holds nothing outside the set, and it is
	# the half that fires in practice, because a removal git refuses is
	# silent and nothing in the sequence above would notice a path that
	# stayed.  A leftover init, a root-level file after a restructure, and a
	# path that dropped out of track_additional_files all arrive here.
	my @outside = grep {!$in_set{$_}} $git->ls_files;
	if (@outside) {
		die Genesis::CI::RunFailure->fatal(
			message => 'the index holds paths outside the propagation set',
			branch  => $branch,
			source  => $source_sha,
			paths   => [@outside],
		);
	}

	# D32 has abort reset every deployment branch the session committed to,
	# and the writer is the one method that commits, so it is the one caller
	# that can tell the session.  Without this line the abort resets only the
	# branches whose tips moved, and a commit that left a tip where it was
	# survives it.
	$git->commit($message);
	$self->_record_commit($branch);

	return {
		commit    => $git->sha('HEAD'),
		delivered => [@to_write],
		removed   => [@stale],
		overwrote => [@overwrote],
	};
}

# }}}
# }}}

### Internals {{{

# _members_at - the set's pathspecs as paths one commit's tree holds {{{
#
# The set is a list of pathspecs and not a list of files.  A dev kit's source
# is the directory entry dev/, and a fragment the blueprint names is in the
# set whether or not anybody has written it yet, so a membership built from
# the set as it stands would read every real file under dev/ as a path outside
# the set and would ask git to check out a file the source does not carry.
#
# Resolving the pathspecs against the source tree answers both at once, and it
# is the same expansion the suite's own reader makes before it compares the
# two.  One listing is read rather than one per entry, because the set is
# small and a git process per path is not.
sub _members_at {
	my ($self, $commit, @set) = @_;
	# The whole tree is asked for as '.', which is git's own spelling for it,
	# because ls_tree passes its path straight through and git refuses an
	# empty pathspec by name rather than reading it as no pathspec at all.
	my @tracked = $self->git->ls_tree($commit, '.');

	my %covered;
	for my $entry (@set) {
		if ($entry =~ m{/$}) {
			$covered{$_} = 1 for grep { index($_, $entry) == 0 } @tracked;
		} else {
			$covered{$entry} = 1 if grep { $_ eq $entry } @tracked;
		}
	}
	return sort keys %covered;
}

# }}}

# _record_commit - remember a branch this session committed to {{{
#
# committed_branches works the set out for itself by comparing tips, and this
# is the writer of M8 saying so outright, which covers the one case the
# comparison cannot see, a commit that leaves the tip where it was.
sub _record_commit {
	my ($self, $branch) = @_;
	$self->{committed}{$branch} = 1 if defined $branch && length $branch;
	return $self;
}

# }}}
# _through_the_door - let the handle's guarded subs run, briefly {{{
#
# The handle refuses a checkout or a detached checkout from outside a
# session, and this is what a session is from the handle's side: the
# door is open for exactly as long as one of the verbs is running, and it
# closes again however that verb ends, because the flag is localised
# rather than set and cleared.
sub _through_the_door {
	my ($self, $code) = @_;
	my $git = $self->{git};
	local $git->{_in_session} = 1;
	return $code->();
}

# }}}
# _is_branch - is this target a branch, or a commit {{{
#
# A narrower question than branch_exists answers, and it is asked here rather
# than by narrowing that reader, because branch_exists cannot be narrowed
# under its callers.  It runs `git rev-parse --verify <name>`, which resolves
# a sha and a tag as readily as a branch name, and resolve_branch and the
# propagation both lean on exactly that looseness to answer "is this thing
# here at all".  switch needs the strict question instead, because the whole
# of D94 turns on telling a branch from a commit, and show-ref --verify
# answers about a named ref and nothing else.
#
# Both halves are asked, because git's own checkout knows a branch it has
# only fetched and this has to know it too.  `git checkout qa/bosh` against a
# repository holding refs/remotes/origin/qa/bosh alone cuts the local branch
# and tracks it, which rev-parse will not do and which the caller means, so a
# name matched only by the remote-tracking half is a branch here as well.
# Reading it as a commit would stand us on a detached HEAD, and a commit made
# there afterwards would belong to no branch at all.
sub _is_branch {
	my ($self, $name) = @_;
	return 0 unless defined $name && length $name;
	my $git = $self->{git};

	return 1 if run({ dir => $git->root, passfail => 1 },
		'git', 'show-ref', '--verify', '--quiet', "refs/heads/$name");

	my $remote = $git->default_remote or return 0;
	return run({ dir => $git->root, passfail => 1 },
		'git', 'show-ref', '--verify', '--quiet',
		"refs/remotes/$remote/$name") ? 1 : 0;
}

# }}}
# _verify_reachable - a recorded commit the repository no longer has {{{
#
# D31's append-only protection makes this rare rather than impossible: a
# branch rewritten on the remote can leave a commit a record still names.
# D94 refuses it by name at DATAERR, because the record is the input and
# the operator needs to know which record is wrong.
sub _verify_reachable {
	my ($self, $commit, $record) = @_;
	my $git = $self->{git};

	# The status is read as well as the output, because run folds git's
	# stderr into the first slot and a complaint read as an answer would
	# let a commit we do not have through.
	my ($found, $rc) = run({ dir => $git->root, passfail => 0 },
		'git', 'rev-parse', '--verify', '--quiet', "$commit^{commit}");
	chomp $found if defined $found;
	return $self if !$rc && $found;

	bail({exitcode => DATAERR},
		"The commit #C{%s} is not in this repository.\n\n".
		"It is named by %s, and the branch it sat on has been rewritten or ".
		"removed on the remote since it was recorded.\n\n".
		"Deploy from the branch tip instead, or restore the commit on the ".
		"remote and refresh.",
		$commit, ($record ? "#C{$record}" : 'the record we were given')
	);
}

# }}}
# _standing_on - what to call the place a failed restore left us {{{
#
# current_branch runs `git rev-parse --abbrev-ref HEAD`, which answers the
# literal string HEAD on a detached HEAD rather than answering undefined, so
# a fallback behind it can never fire and an operator whose restore failed is
# told they are standing on "HEAD", which names nothing they can act on.
#
# Since D94 a detached HEAD is a designed state rather than an accident, so
# the question is asked here instead.  The commit is the thing the operator
# can act on, and the target the session last switched to is named beside it
# where the two are not the same, because that is the target they asked for.
sub _standing_on {
	my ($self) = @_;
	my $git    = $self->{git};

	my $branch = $git->current_branch;
	return $branch if defined $branch && length $branch && $branch ne 'HEAD';

	my $head = eval { $git->sha('HEAD') };
	return 'a detached HEAD' unless $head;

	my $on = $self->{on};
	return sprintf("a detached HEAD at %s, which we switched to as %s",
		$head, $on) if defined $on && length $on && $on ne $head;

	return sprintf("a detached HEAD at %s", $head);
}

# }}}
# _register_net - the last-resort abort, from an END block {{{
#
# RF12 put this here rather than in DESTROY.  bail exits when it is not
# inside an eval, Perl runs END before global destruction, and the order of
# destruction after that is undefined, so a net hung on DESTROY fires late
# or never.  at_exit hooks run from END, which is early enough to still
# have a working tree to put back.
#
# The hook is registered once per session and is a no-op on a session that
# finished, so an ordinary run pays nothing for it.
sub _register_net {
	my ($self) = @_;
	return $self if $self->{net};

	require Genesis::Commands;
	my $me = $self;
	Genesis::Commands::at_exit(sub {
		return unless $me->{active};

		# The hooks run from END with $? already holding the code the
		# command chose, and the process exits on whatever $? reads once
		# they are done.  The abort shells out to git several times, so
		# without this the net would hand every refusal git's nought and a
		# caller waiting on a switch would be told it succeeded.  It is
		# saved and put back by hand because the obvious localisation,
		# local $? = $?, loses the value: assigning a magic variable to its
		# own freshly localised self does not preserve it.  An explicit save
		# says what it does at the one point where getting it wrong is
		# invisible.
		my $status = $?;

		# Inside an END block there is nobody left to catch a die, so the
		# abort is wrapped and whatever it could not do is printed here.
		eval {
			$me->abort("the process exited with a branch session still open");
			1;
		} or do {
			my $err = $@ || 'the restore failed';
			$err =~ s/\s+$//;
			print STDERR "\n$err\n";
		};

		$? = $status;
	});

	$self->{net} = 1;
	return $self;
}

# }}}
# _take_lock - the flock D46 fixes, on genesis-session.lock {{{
#
# Per working tree, because git_dir resolves under .git/worktrees/<name>/
# in a linked working tree.  The pid and the command go inside so that the
# refusal can name a live holder, and there is no break-lock option: the
# kernel drops the flock when the holder dies, so an abandoned lock cannot
# arise and a refusal always names somebody who is still running.
#
# The pid is the first line and the command the second, which is the form
# every reader of this file already agrees on, so a command carrying spaces
# or a colon cannot be mistaken for part of the pid.
sub _take_lock {
	my ($self, $restore) = @_;
	return $self if $self->{lock};

	my $path = $self->{git}->git_dir . '/genesis-session.lock';
	open(my $fh, '+>>', $path)
		or bail("Unable to open the session lock at %s: %s", $path, $!);

	unless (flock($fh, LOCK_EX | LOCK_NB)) {
		my $holder = do { seek($fh, 0, 0); local $/; <$fh> } // '';
		close $fh;
		my ($pid, $command) = split /\n/, $holder, 2;
		chomp $command if defined $command;
		$pid = 'unknown' unless defined $pid && $pid =~ /^\d+$/;
		$command = 'an unknown command'
			unless defined $command && $command =~ /\S/;

		# I1 promises the directory we exit in is the one we came in on,
		# and a refusal is an exit, so we stand back where switch found us
		# before we say anything.
		chdir($restore) if defined $restore && -d $restore;

		bail({exitcode => TEMPFAIL},
			"Another Genesis process is using this working tree.\n\n".
			"  process %s is running: %s\n\n".
			"Only one session may switch branches in #C{%s} at a time.  Wait ".
			"for that command to finish and run this one again.",
			$pid, $command, $self->{git}->root);
	}

	truncate($fh, 0);
	seek($fh, 0, 0);
	print $fh sprintf("%d\n%s\n", $$, _command_line());
	$fh->flush;

	$self->{lock} = $fh;
	trace("Service::Git::Session: took the switch lock at %s", $path);
	return $self;
}

# }}}
# _release_lock - finish lets go, and nothing else does {{{
sub _release_lock {
	my ($self) = @_;
	my $fh = delete $self->{lock} or return $self;
	flock($fh, LOCK_UN);
	close $fh;
	return $self;
}

# }}}
# _command_line - what the refusal names the holder as {{{
sub _command_line {
	require Genesis::Commands;
	my $command = eval { Genesis::Commands::current_command() };
	return join(' ', 'genesis', grep {defined && length} ($command))
		if $command;
	return join(' ', $0, @ARGV);
}

# }}}
# _reset_to_remote - put one branch back at T {{{
#
# A ref write rather than a switch, so it takes no lock and needs no
# checkout.  The control branch never reaches here, because
# committed_branches is the set this session moved and it filters that name
# out of it.
sub _reset_to_remote {
	my ($self, $branch) = @_;
	my $git    = $self->{git};
	my $remote = $git->default_remote or return $self;
	my $t      = "refs/remotes/$remote/$branch";

	my ($tip) = run({ dir => $git->root, passfail => 0 },
		'git', 'rev-parse', '--verify', '--quiet', $t);
	chomp $tip if defined $tip;
	return $self unless $tip;

	# On the branch itself a ref write alone would leave the tree ahead of
	# HEAD, so a hard reset is what puts the two back together.
	if (($git->current_branch // '') eq $branch) {
		run({ dir => $git->root, onfailure => "Failed to reset $branch" },
			'git', 'reset', '--hard', $tip);
	} else {
		run({ dir => $git->root, onfailure => "Failed to reset $branch" },
			'git', 'update-ref', "refs/heads/$branch", $tip);
	}
	trace("Service::Git::Session: reset %s to %s", $branch, $t);
	return $self;
}

# }}}
# _restore - return to the branch begin recorded, from the root {{{
sub _restore {
	my ($self) = @_;
	my $git    = $self->{git};
	my $origin = $self->{origin} or return $self;

	chdir($git->root)
		or bail("Unable to enter git root %s: %s", $git->root, $!);
	$self->_through_the_door(sub {
		$git->checkout($origin->{branch});
	}) unless ($git->current_branch // '') eq $origin->{branch};

	# The directory begin recorded may not exist on the branch we came back
	# to, and saying so beats landing somewhere the caller did not choose.
	if (-d $origin->{cwd}) {
		chdir($origin->{cwd})
			or bail("Unable to return to %s: %s", $origin->{cwd}, $!);
	} else {
		Genesis::info("The directory #C{%s} is gone, so we are at #C{%s}.",
			$origin->{cwd}, $git->root);
	}

	bail("Failed to return to #C{%s}: we are on #C{%s}.",
		$origin->{branch}, $self->_standing_on)
		unless ($git->current_branch // '') eq $origin->{branch};

	return $self;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=0:noet
