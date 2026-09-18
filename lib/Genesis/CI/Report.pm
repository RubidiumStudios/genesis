package Genesis::CI::Report;
# The propagate run's report.  Every word an operator reads about an outcome
# is composed here, and pipeline-status renders the same record through the
# same helpers, so the two outputs cannot disagree about a phrase.  I8 is the
# rule the file exists for: nothing is silently omitted.
#
# The report stands on three axes, and every one of them is exhaustive.  Each
# environment in scope carries exactly one outcome, each control commit the
# walk routed to an environment carries one of its own, and each file the
# writer overwrote a hand edit on carries a third.  An environment with
# nothing due reads idempotent rather than being left out, which is the whole
# of I8: a quiet run and a blocked one have to read differently.
use strict;
use warnings;

use Exporter qw/import/;
use Genesis qw/info warning bug/;

our @EXPORT_OK = qw/
	held_qualifier hold_reason hold_detail note_detail
	render_run render_preview
	ENV_OUTCOMES COMMIT_OUTCOMES FILE_OUTCOME AWAITING_APPLY
/;

# I8's three axes, as Publish and outcomes fixes the words.  The enum is
# declared here rather than in the walk, because the walk, the delivery, the
# abort, and M11's publish all write into one field and a word spelled in
# four places is a word the four drift apart on.
use constant ENV_OUTCOMES => (
	'propagated', 'idempotent', 'failed', 'not attempted',
	'held', 'publish rejected', 'not published',
);
use constant COMMIT_OUTCOMES => ('delivered', 'held');
use constant FILE_OUTCOME    => 'overwrote-hand-edit';

# D54's qualifier for an environment the pipeline has never been applied to.
# It is declared here because this module owns every word an operator reads
# about an outcome, and the command that meets the same state before the walk
# has anything to say writes the record's detail through this name rather than
# spelling the phrase a second time.
use constant AWAITING_APPLY => 'awaiting pipeline-apply';

# The two verbs a preview changes, which are the only words that differ
# between what a run did and what a preview says would happen.  They are
# named rather than spelled where they are wanted, because the environment's
# verb is written in one sub and read in another and a phrase spelled twice
# is a phrase the two spellings drift apart on.
#
# The environment's verb is written into the record by render_preview, since
# the preview is the only thing that knows the run did not happen, and the
# commit's is composed at print time, since nothing writes a per-commit
# outcome until the publish does.
use constant WOULD_PROPAGATE => 'would propagate';
use constant WOULD_DELIVER   => 'would deliver';

# The colour each outcome is printed in, so an operator reads a blocked run
# off the shape of the output before they read a word of it.
my %COLOUR = (
	'propagated'       => 'G',
	'idempotent'       => 'Gi',
	'failed'           => 'R',
	'not attempted'    => 'Y',
	'held'             => 'Y',
	'publish rejected' => 'R',
	'not published'    => 'Y',
	# A preview's propagating environment reads as the run's would, because
	# the shape of the output is what an operator takes a blocked run off
	# and a preview that greyed its good news would read as a blocked one.
	WOULD_PROPAGATE() => 'G',
);

### The words {{{

# hold_reason - one held commit's reason, in the form the design fixes {{{
#
# Publish and outcomes spells these exactly, so that genesis propagate, its
# dry run, and the routing column of genesis pipeline-status can never
# disagree about a word.  The overlap form carries the ancestor's own state
# under D72 and the never-certified form carries no such clause, an
# environment that has never deployed being already clear about why.  The
# frozen form names the pull request an operator merges to release the commit,
# because a number is what they act on.
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

	# D50: the environment's own hold is what holds this commit, and what an
	# operator has to do about it is the reason somebody wrote on the record,
	# so the line carries that rather than the word on-hold.
	return sprintf('held (%s)', $held->{hold_reason})
		if $reason eq 'on-hold' && defined $held->{hold_reason};

	# D51: an approved pull request is frozen, so what holds this commit is
	# the merge nobody has made yet, and the number is what an operator acts
	# on.  The enum already carries the reason and this is its wording.
	#
	# An entry carrying the reason and no number falls through to the bare
	# wording at the foot of the sub, which reads held (awaiting-merge),
	# rather than printing an empty number under a warning.  Nothing in the
	# tree writes one: Genesis::CI::PullRequest::freeze is the only producer
	# of this reason and it always writes the pull request's number.
	return sprintf('awaiting merge (#%d)', $held->{number})
		if $reason eq 'awaiting-merge' && defined $held->{number};

	return sprintf('held (%s)', $reason);
}

# }}}
# held_qualifier - what one held environment waits for, or undef {{{
#
# D54's qualifier, which says what the environment waits for rather than why
# any one commit is held.  An environment the pipeline was never applied to
# waits for that command, one whose environment the run could not read has
# failed instead, and one holding commits behind an ancestor waits for that
# ancestor to certify the commit it has not deployed.  One whose pull request
# a reviewer approved waits for that merge and for nothing else.
#
# It answers the qualifier alone and not the whole phrase, because ruling 22
# puts the bare enum word in the record's outcome and the qualifier beside it
# in outcome_detail, and the renderer reads the two back into one line.  So
# the word held is written once, where the outcome is decided.
sub held_qualifier {
	my ($record) = @_;

	my $certified = $record->{certified} // {};
	return AWAITING_APPLY
		if ($certified->{state} // '') eq 'never-applied';

	# D50: a hold is a decision somebody made for a reason the pipeline
	# cannot see, and only a human clears it, so it outranks whatever the
	# commits underneath it happen to be waiting for.
	return sprintf('needs clearing (%s)',
		$record->{hold}{reason} // 'no reason given')
		if $record->{hold};

	my ($first) = @{$record->{held} || []};
	return undef unless $first;

	# The same fact on the environment axis.  An environment whose pull
	# request is approved waits for the merge rather than for an ancestor to
	# certify anything, so it outranks the ancestor wording below.
	#
	# The entry is picked out by its reason and not off the front of the
	# list, because the walk sends every commit from the first hold backwards
	# to held, so an environment with a gate or an ancestor hold in range
	# arrives here with that list already full and the freeze's own entries
	# appended behind it.  Reading the front would then name a deployment and
	# send an operator to certify something, while what releases the
	# environment is the merge nobody has made.
	#
	# An entry carrying the reason and no number falls through to the wording
	# below rather than printing an empty number under a warning.  Nothing in
	# the tree writes one: Genesis::CI::PullRequest::freeze is the only
	# producer of this reason and it always writes the pull request's number.
	my ($frozen) = grep {($_->{reason} // '') eq 'awaiting-merge'}
		@{$record->{held}};
	return sprintf('awaiting merge (#%d)', $frozen->{number})
		if $frozen && defined $frozen->{number};

	# The environment named is whoever has to certify, which is the ancestor
	# where an ancestor holds the commit and the environment itself where a
	# gate does, and the commit named is the one that certification has to
	# reach, which is the gate itself rather than the commit it holds.
	return sprintf('awaiting deployment (%s at control@%s)',
		$first->{ancestor} // $record->{env},
		substr($first->{gate} // $first->{control_commit}, 0, 7));
}

# }}}
# hold_detail - what the standing hold is holding, in D56's three wordings {{{
#
# D56 makes a hold outrank idempotent, so an environment with one standing
# never reads as though it were fine, and this is the line that says which of
# three situations it is in: a known number of commits are waiting on the
# hold itself, or something else is holding commits and the hold stands over
# them, or nothing at all is waiting.
#
# The count is of the commits the hold itself took, and not of everything
# held, because a commit a gate or an ancestor had already stopped is
# reported under that reason and counting it here would name it twice and
# send the operator to the wrong command.
#
# The nothing-due wording is answered only where nothing is held either.
# The report prints this line directly above the commit lines, so an
# environment whose commits a gate is holding would otherwise read that
# nothing is due and then read the commits that are, which is the one thing
# the line exists to stop.
sub hold_detail {
	my ($record) = @_;

	return undef unless $record->{hold};

	my @held = @{$record->{held} || []};
	my $blocked = grep {($_->{reason} // '') eq 'on-hold'} @held;

	return sprintf('%d commit%s %s blocked until this hold is released',
		$blocked, $blocked == 1 ? '' : 's', $blocked == 1 ? 'is' : 'are')
		if $blocked;

	return 'nothing is due now, and anything that becomes due stays blocked'
		unless @held;

	# Everything held here is held for a reason of its own, and the hold
	# stands over all of it, so the line says both: clearing what those
	# commits wait for releases nothing while the hold is still standing.
	return sprintf(
		'%d commit%s %s blocked for %s own, and %s blocked while this hold stands',
		scalar(@held), @held == 1 ? '' : 's',
		@held == 1 ? 'is' : 'are',
		@held == 1 ? 'a reason of its' : 'reasons of their',
		@held == 1 ? 'stays' : 'stay');
}

# }}}
# note_detail - add one qualifier to an environment's outcome_detail {{{
#
# I8 puts the bare enum word in outcome and everything qualifying it in
# outcome_detail, and more than one writer has something to say there on one
# run.  The delivery writes what the rebuild discarded, and the publish writes
# what the remote made of the push, and both land on one record.  The
# qualifiers are appended rather than assigned, so a run with two of them says
# both rather than dropping whichever was written first.
#
# It lives here rather than beside either writer, because render_run is what
# reads the field and a rule about how the field is filled belongs next to the
# thing that prints it.
sub note_detail {
	my ($record, $line) = @_;
	return $record unless defined $line && length $line;
	$record->{outcome_detail} = join('; ',
		grep {defined && length} $record->{outcome_detail}, $line);
	return $record;
}

# }}}
# }}}
### The report {{{

# render_run - the run's report, one block per environment {{{
#
# Every environment in scope gets exactly one outcome line, every routed
# control commit beneath it gets one of its own, and every overwritten hand
# edit gets a third.  An environment with nothing due reads idempotent rather
# than being left out, which is the whole of I8.
#
# Ruling 12 puts the default here rather than in the walk.  The walk's record
# is computed from durable state alone and leaves the outcome null, so where
# a hold stands the renderer reads the qualifier that says what the
# environment waits for, and where nothing stands at all it reads idempotent.
# One line of code composes the held phrase for the run and for the preview
# alike, which is the whole reason this module exists rather than each output
# spelling the words itself.
#
# outcomes_only is the abort's shape.  A run that ended early published
# nothing, so the commit axis has nothing true to say and printing a pending
# commit under it would name a delivery that never happened.
#
# preview is what L</render_preview> hands down, and it does two things.  It
# lets the guard below take the one word a preview adds to the environment
# axis, and it turns the commit axis's own verb over.  Everything else reads
# the same either way, because a preview differs from a run in two verbs and
# in nothing at all besides.
sub render_run {
	my ($record, %opts) = @_;

	my $git     = $opts{git};
	my $preview = $opts{preview} ? 1 : 0;
	my %known   = map {$_ => 1} ENV_OUTCOMES;
	$known{+WOULD_PROPAGATE} = 1 if $preview;

	info "";
	for my $env (@{$record->{environments} || []}) {
		_settle($env);
		bug("Genesis::CI::Report::render_run was handed the outcome '%s' for ".
			"%s, which is not one of the words I8 fixes", $env->{outcome},
			$env->{env}) unless $known{$env->{outcome}};

		my $colour = $COLOUR{$env->{outcome}} // 'Y';
		info "  #%s{%s}: %s", $colour, $env->{env},
			join(', ', grep {defined && length}
				$env->{outcome}, $env->{outcome_detail});

		# The label is coloured and the message is not.  csprintf tolerates
		# one level of balanced braces inside a colour span, and an
		# unbalanced brace in a YAML reader's complaint ends the span early
		# and moves the characters after it, so the operator reads a message
		# that is not the one the reader wrote.
		info "    #R{error}: %s", $env->{error} if $env->{error};
		next if $opts{outcomes_only};

		if (my $detail = hold_detail($env)) {
			info "    #Y{%s}", $detail;
			info "    Release it with #C{genesis %s pipeline-release}",
				$env->{env};
		}

		# The commit axis, in control order: what the environment received
		# first, and then what it is holding behind it.
		for my $pending (@{$env->{pending} || []}) {
			info "    #Gi{control\@%s} %s  %s",
				substr($pending->{control_commit}, 0, 7),
				$pending->{subject},
				_commit_word($pending->{outcome} // 'delivered', $preview);
			info "      #G{M} %s", $_ for _paths($git, $pending->{delivered});
			info "      #R{D} %s", $_ for _paths($git, $pending->{removed});

			# D33: an overwrite is never silent, and it is named per file,
			# because the branch was carrying a hand edit that the mirror has
			# just taken back off it.  It is the report's third axis rather
			# than a warning beside it, since a warning is not an outcome and
			# I8 asks for one per file.
			info "      #Y{%s} %s", FILE_OUTCOME, $_
				for _paths($git, $pending->{overwrote});
		}
		for my $held (@{$env->{held} || []}) {
			info "    #Yi{control\@%s} %s  %s",
				substr($held->{control_commit}, 0, 7), $held->{subject},
				_commit_word($held->{outcome} // 'held', $preview);
			info "      #Y{H} %s", hold_reason($held);
		}
	}

	return 1;
}

# }}}
# render_preview - the preview's report, which is the run's own {{{
#
# D44 leaves --dry-run as the only preview, and it reports, per environment
# and per control commit, the files that would land and whether each commit
# would be delivered or held and why, and writes nothing.  It is the same
# record and the same renderer the run uses, because two renderers drift and
# the held forms have to read word for word as pipeline-status's do under
# D54.
#
# One verb is written here rather than composed by the renderer.  An
# environment with commits due would have propagated had this been a run, and
# the preview is the only thing that knows it was not, so the word goes in
# where that is known.  Ruling 12 leaves the rest with render_run: a hold
# that stands and an environment with nothing at all to show are both settled
# out of the record there, so the run and the preview say those words in one
# place.
sub render_preview {
	my ($record, %opts) = @_;

	# Said before a line of the report, because an operator who reads the
	# report first and the banner afterwards has already believed it.
	info "\n#Yi{This is a preview.  Nothing will be written.}";

	# Said under the banner and above the first environment, because a
	# caveat printed beneath the whole report is one the operator reads
	# after they have already believed the report.
	preview_warnings($record);

	for my $env (@{$record->{environments} || []}) {
		$env->{outcome} //= WOULD_PROPAGATE if @{$env->{pending} || []};
	}

	return render_run($record, %opts, preview => 1);
}

# }}}
# preview_warnings - the two cases a preview's answer rests on {{{
#
# D44 gives the preview two loud warnings, because in each case its answer
# rests on something the preview deliberately did not do.  A control branch
# that is ahead of its remote is refused by a real run under D30 until it has
# been pushed, and a deployment branch whose local commits all carry a marker
# is reset to the remote by the pre-flight under D32 before the walk begins.
#
# The warnings are read off the record rather than worked out here, counts
# and all.  The run has already asked git both questions, once to decide
# whether to refuse and once to decide whether to reset, and a renderer that
# asked them again would be a second reader of a fact the run has settled.
#
# Each caveat names how many commits it is about, and the number governs the
# noun and the verb, because the only other place either count is said is the
# pre-flight's event line, which stands above the banner where an operator has
# not yet been told they are reading a preview.
#
# Neither warning says anything about the files the report goes on to name.
# A preview threads each delivery's tree forward into the next, so the file
# lists are true of the branch as the reset would leave it, and a caveat over
# them would teach an operator to distrust a correct answer.
sub preview_warnings {
	my ($record) = @_;

	for my $caveat (@{$record->{warnings} || []}) {
		my $kind = $caveat->{kind} // '';

		if ($kind eq 'unpushed-control') {
			my $n = $caveat->{commits} // 1;
			warning(
				"#Y{This preview assumes %s on }#C{%s}#Y{ %s pushed.}\n".
				"It is ahead of #C{%s/%s}, and a real run refuses to propagate ".
				"until you push %s, so what follows is what would happen once ".
				"you have.",
				$n == 1 ? 'the commit' : sprintf('the %d commits', $n),
				$caveat->{branch},
				$n == 1 ? 'is' : 'are',
				$caveat->{remote}, $caveat->{branch},
				$n == 1 ? 'it' : 'them'
			);
			next;
		}

		if ($kind eq 'unreset-branch') {
			warning(
				"#Y{This preview assumes }#C{%s}#Y{ is reset first.}\n".
				"A real run resets it to #C{%s/%s} before it walks, ".
				"discarding %s, so what follows is what would happen once ".
				"that reset has run.",
				$caveat->{branch}, $caveat->{remote}, $caveat->{branch},
				_commits($caveat->{commits} // 1)
			);
			next;
		}

		bug("Genesis::CI::Report::preview_warnings was handed the warning ".
			"'%s', which is neither of the two D44 names", $kind);
	}

	return 1;
}

# }}}
# }}}
### Internals {{{

# _settle - fill the outcome the record left null {{{
#
# Ruling 12 and ruling 22 together: a hold that stands writes the bare word
# held with its qualifier beside it, and an environment with nothing at all
# to show writes idempotent.  Everything else was decided by whoever knew,
# which is the walk for a failure and the run for a delivery.
#
# The qualifier is assigned here rather than appended through note_detail,
# and that is right: nothing an environment reaching this sub can be carrying
# was written into the field already.  The one writer that appends before the
# report runs is the pull request arm's discard region, and an environment
# that reaches it has an outcome by the time the arm returns, while a freeze
# returns above the discard region and writes nothing there at all.
sub _settle {
	my ($env) = @_;

	return $env if defined $env->{outcome};

	if (my $qualifier = held_qualifier($env)) {
		$env->{outcome}        = 'held';
		$env->{outcome_detail} = $qualifier;
	} else {
		$env->{outcome} = 'idempotent';
	}
	return $env;
}

# }}}
# _commit_word - one routed commit's outcome, checked against the enum {{{
#
# The commit axis reads its words out of COMMIT_OUTCOMES the way the
# environment axis reads its own out of ENV_OUTCOMES, so the enum is
# load-bearing on all three axes rather than on one of them.  A word from
# outside it is a defect in whoever wrote the record, and the guard says so by
# name rather than printing it.
#
# The word is taken off the record with a default beside it, because nothing
# writes one yet and the axis still has to have a reader that can be handed
# the wrong thing.  The default is the caller's rather than this sub's, and
# there are two of them: a commit under pending reads delivered and one under
# held reads held.  Both go once the publish stage writes a word per commit.
sub _commit_word {
	my ($outcome, $preview) = @_;

	my %known = map {$_ => 1} COMMIT_OUTCOMES;
	bug("Genesis::CI::Report::render_run was handed the commit outcome ".
		"'%s', which is not one of the words I8 fixes", $outcome)
		unless defined $outcome && $known{$outcome};

	return WOULD_DELIVER if $preview && $outcome eq 'delivered';
	return $outcome;
}

# }}}
# _commits - a count of commits with the noun agreeing {{{
#
# Genesis::CI::Preflight carries the same three lines for its refusals and its
# event lines.  The shape is mirrored rather than shared, because the one that
# is there is private to that module and a renderer reaching across for it
# would be reading another stage's internals to print a noun.
sub _commits {
	my ($n) = @_;

	return sprintf('%d commit%s', $n, $n == 1 ? '' : 's');
}

# }}}
# _paths - one delivery's paths as the operator wrote them {{{
#
# The writer records repository paths, which carry the deployment root a
# repository may have been laid out under, and an operator reads the paths
# they committed.  A caller with no git handle gets them as they stand.
sub _paths {
	my ($git, $paths) = @_;

	return () unless $paths && @$paths;
	return $git ? $git->unprefixed(@$paths) : @$paths;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=0:noet
