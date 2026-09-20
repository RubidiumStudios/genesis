package Genesis::CI::Publish;
# The run's third stage.  The walk decides what is due and the delivery writes
# it onto the deployment branches in L, and everything here is about getting
# what L now holds onto R and saying, per environment, what the remote made of
# it.
#
# One push per branch, because D83 has a rejection on one branch cost one
# environment one run and nothing else.  No push's result withholds another's,
# which is the third stage of D96, and each result is that branch's outcome
# rather than a warning printed beside a success.
#
# The push set is the deployment branches alone.  Control is the run's input
# and never its output, so what the stage does with control is read it once
# more before the first push, and a control that has moved refuses the whole
# publish.
#
# Everything the push would carry is shown before it goes, and the showing is
# not conditional on anyone being there to read it.  D83 computes once,
# verifies, shows, and asks, because a dry run followed by a real run computes
# everything twice and control or exodus can move between the two, so the
# second run may deliver what the operator never previewed.  At a terminal the
# showing comes before the ask, and where there is no terminal it goes to the
# log, so the pipeline's job and the propagate child print the delta an
# operator would have seen.  -y answers the ask and nothing else.
use strict;
use warnings;

use Exporter qw/import/;
use Genesis qw/bug info warning/;
use Genesis::CI::Report qw/note_detail/;
use Genesis::Term qw/in_controlling_terminal/;
use Genesis::UI qw/prompt_for_boolean/;

our @EXPORT_OK = qw/publish_run confirm_publish publish_delta/;

### The stage {{{

# publish_run - push every branch the run committed to, one at a time {{{
#
# Control is re-checked before the first push, and a control that has moved
# refuses the publish, puts every branch the run committed to back where the
# remote has it, and answers the refusal as a sentence for the command to
# speak.
#
# A branch the remote refuses records the rejection as that environment's one
# outcome and goes straight back to where T has it, so the run ends with no
# local commit nobody else can see, and every other branch is published
# regardless of where the refusal fell.
#
# The bare enum word goes into outcome and everything qualifying it into
# outcome_detail, because the run's status and the report both match the whole
# of that field against the seven words I8 fixes.
#
# The delta every push would carry is shown before the first one goes out, and
# an operator at a terminal is then asked.  A run that is declined pushes
# nothing, puts every branch it committed to back where the remote has it,
# records each environment as not published with the decline beside the word,
# and says so on declined.
#
# Returns { published => \@branches, rejected => \@branches, declined => 0,
# results => \@results }, with refused carrying the sentence where control
# moved and nothing was pushed at all.
sub publish_run {
	my (%args) = @_;
	my $git     = $args{git};
	my $session = $args{session};
	my $remote  = $args{remote} || ($git ? $git->default_remote : undef);
	my $records = $args{records} || [];
	my @specs   = @{$args{specs} || []};

	my $result = {
		published => [], rejected => [], declined => 0, results => [],
	};
	return $result unless @specs && $remote;

	# D30's in-sync rule, asked a second time.  The pre-flight asked it once
	# before the walk, and a walk takes long enough for a teammate to push
	# through the middle of it, so the last thing the run does before its
	# first push is ask again.  A control that has moved refuses, and the
	# refusal comes back as a sentence rather than as an exit, because the
	# command owes the operator their branch back before it says why the run
	# stopped.
	if (my $refused = _recheck_control($git, $args{control}, $remote)) {
		$result->{refused} = $refused;
		_reset_publish_set($session);
		return $result;
	}

	# D83's ask, and the showing that does not wait on it.  The delta is
	# read from git rather than recomposed from the walk's record, so what
	# an operator is shown is what the push sends and not what the run
	# meant to send.  A decline pushes nothing, and the status the run
	# exits with is the caller's to decide.
	#
	# A run the operator declines takes the path a refused control takes,
	# because a branch carrying a commit the remote has never seen is the
	# illegal initial state D96 names and a run the operator stopped must
	# not leave one behind.  Each environment then says it was written,
	# verified, and not published, with the reason beside the word rather
	# than inside it.
	unless (confirm_publish($git, $remote, \@specs, yes => $args{yes})) {
		$result->{declined} = 1;
		_reset_publish_set($session);
		for my $spec (@specs) {
			my $rec = _record_for($records, $spec->{env}) or next;
			$rec->{outcome} = 'not published';
			# Appended, because the delivery may already have written what
			# the rebuild discarded on this environment and a decline that
			# assigned the field would take that sentence down with it.
			note_detail($rec, 'operator declined');
		}
		return $result;
	}

	info "\n#G{Publishing} to #C{%s}...", $remote;

	# A death out of the push itself is the whole command failing rather than
	# one ref being turned down, and D82 answers it with the same abort a
	# remote that answered nothing earns, so it is caught here and handed to
	# the caller's own classifier with everything else.
	my $pushes = eval {$git->push(remote => $remote, refs => \@specs)};
	my $died   = $@;
	$pushes ||= [];
	$result->{results} = $pushes;

	# D82's unsurvivable remote.  A push the remote answered about on no ref
	# at all is the remote being gone rather than any branch's own quarrel
	# with it, so nothing below runs.  No environment is given an outcome it
	# would have to take back, and the run as a whole ends instead.  The
	# classifier that turns git's words into a remedy belongs beside the run,
	# so the caller raises it and this stage only says which reason to raise
	# it on.
	#
	# What is read is whether git named a ref, because a ref is filled in
	# from git's own porcelain line and a push that never reached the remote
	# prints none.  Reading whether any ref landed instead would make a
	# remote that refused every branch indistinguishable from one nobody
	# could reach, and the two earn different answers.  That matters all the
	# more now that the push set is the deployment branches alone, because a
	# run with one environment in it has a single ref to land, and the only
	# ref there was is then the refused one.
	unless (grep {$_->{ok} || defined $_->{ref}} @$pushes) {
		my ($reason, $stderr) = ($died, '');
		# The first ref that said anything, since the classifier reads one
		# line, and both of the things it said, because the phrases that name
		# a class live in git's hint text rather than in the short phrase the
		# porcelain line carries.  A result that said nothing at all is read
		# for what it is rather than warned about, because the warning would
		# land on the same stream the run's own report is read from.
		unless (defined $reason && length "$reason") {
			my ($said) = grep {
				(defined $_->{stderr} && length $_->{stderr}) ||
				(defined $_->{reason} && length $_->{reason})
			} @$pushes;
			($reason, $stderr) = ($said->{reason}, $said->{stderr}) if $said;
		}
		$args{unsurvivable}->($reason, $stderr) if $args{unsurvivable};
		return $result;
	}

	for my $pushed (@$pushes) {
		my $spec = _spec_for(\@specs, $pushed->{branch});
		my $rec  = _record_for($records, $spec->{env});

		if ($pushed->{ok}) {
			push @{$result->{published}}, $pushed->{branch};
			info "  #G{%s}: published", $pushed->{branch};
			_mark_delivered($rec);
			next;
		}

		# The ref in the outcome is the one git named in its porcelain line,
		# and not one composed here out of the branch we asked for.
		my $moved = $pushed->{ref} // $pushed->{branch};
		$moved =~ s{^refs/heads/}{};

		if ($rec) {
			$rec->{outcome} = 'publish rejected';
			# Appended, for the reason the decline above gives.  This is the
			# run that follows a hand push, which is exactly the run whose
			# delivery has a discard sentence standing in the field already.
			note_detail($rec, sprintf('%s moved on R', $moved));
		}

		# At once, rather than at the end of the run, because everything
		# after this point can still fail and a branch put back only on the
		# way out is a branch left standing wherever the run stopped.
		$session->reset_branch($pushed->{branch}) if $session;

		push @{$result->{rejected}}, $pushed->{branch};
		warning("  #R{%s}: publish rejected, %s moved on R (%s)",
			$pushed->{branch}, $moved,
			length($pushed->{reason} // '') ? $pushed->{reason}
			                                : 'refused by the remote');
	}

	return $result;
}

# }}}
# confirm_publish - show every branch's verified delta, then ask {{{
#
# D83 has the showing unconditional and the ask conditional.  At a terminal the
# delta comes first and the operator answers for it, and where there is no
# controlling terminal the same delta goes to the log and the run goes on, so
# the pipeline's job and the propagate child print what an operator would have
# been shown.  -y suppresses the ask and nothing else, which is why it is read
# before the terminal is consulted at all.
sub confirm_publish {
	my ($git, $remote, $specs, %opts) = @_;

	info "\n#G{This run wrote} #C{%d} branch%s:",
		scalar(@$specs), @$specs == 1 ? '' : 'es';
	for my $spec (@$specs) {
		my $delta = publish_delta($git, $remote, $spec);
		if ($delta->{removal}) {
			info "\n  #C{%s}: to be removed from #C{%s}, nothing is due",
				$spec->{branch}, $remote;
			next;
		}
		# The count is the delta's own rather than the length of the list
		# beneath it, because a branch the remote has never held carries its
		# whole history and prints no line per commit.
		info "\n  #C{%s}: %d commit%s, %d file%s changed, %d removed%s",
			$spec->{branch},
			$delta->{count}, $delta->{count} == 1 ? '' : 's',
			$delta->{changed}, $delta->{changed} == 1 ? '' : 's',
			$delta->{deleted},
			$delta->{new_branch}
				? ", on a branch #C{$remote} does not hold yet" : '';
		info "      %s", $_ for @{$delta->{commits}};
	}

	return 1 if $opts{yes};
	return 1 unless in_controlling_terminal();
	return prompt_for_boolean("Publish these branches? [y|n]", 1) ? 1 : 0;
}

# }}}
# publish_delta - what one branch's push would carry {{{
#
# The verified delta is the range from the remote-tracking ref to the local
# branch, which is exactly what the push sends, so it is read from git rather
# than recomposed from the walk's record.
#
# A branch the remote does not hold yet has no range to read, and it is the
# push that carries the most rather than the least, so its delivery is its
# whole history: every commit the branch reaches, and every path its tip
# holds, which is what a diff against the empty tree would name.  The showing
# exists so an operator sees what the push sends, and a new branch reported as
# an empty delta said the opposite of the truth about it.
sub publish_delta {
	my ($git, $remote, $spec) = @_;
	my $branch = $spec->{branch};
	return {removal => 1} if $spec->{delete};

	# resolve_branch is the tree's one reader of where a branch stands
	# against its remote, and no-remote is its word for a branch only the
	# local repository has.  It answers nothing at all where neither side
	# holds the name, which is a different case and is refused below.
	my $state = $git->resolve_branch($branch, remote => $remote);

	# The publish set is the branches the run committed to, so every branch
	# this is asked about has a local ref.  Two of the reader's answers say
	# there is none, which are no-local, where the remote holds the name and
	# this repository does not, and silence, where neither side holds it.
	# Both are a caller's mistake rather than a state to read a range over,
	# and each is refused by name, because the step that would put one right
	# puts the other nowhere.
	#
	# Neither survives the reads below, and the way each fails is worse than
	# a refusal.  ls_tree checks git's status and bails with a sentence about
	# listing a ref, which stops the run over a caller's mistake as though
	# the repository were at fault.  log_subjects checks none, and it runs
	# under the default that folds git's standard error in with its output,
	# so the three lines of git's fatal message would come back as three
	# commits and be printed as their subjects.
	bug("publish_delta was asked for the branch #C{%s}, which neither this ".
	    "repository nor #C{%s} holds",
	    $branch, $remote // 'the remote')
		unless $state;

	bug("publish_delta was asked for the branch #C{%s}, which #C{%s} holds ".
	    "and this repository does not",
	    $branch, $remote // 'the remote')
		if $state->{state} eq 'no-local';

	# Only no-remote reaches here, the two answers with no local ref in them
	# having been refused above and every other one having a range to read.
	if ($state->{state} eq 'no-remote') {
		# The commits are counted rather than listed, because a new branch
		# reaches as far back as the repository does and the showing is a
		# sentence rather than a log.
		my @history = $git->log_subjects("refs/heads/$branch", format => '%H');
		# The pathspec is the root, because ls_tree refuses an empty one.
		my @paths   = $git->ls_tree("refs/heads/$branch", '.');
		return {
			new_branch => 1,
			commits    => [],
			count      => scalar(@history),
			changed    => scalar(@paths),
			deleted    => 0,
		};
	}

	my $tracking = "refs/remotes/$remote/$branch";
	my @commits  = $git->log_subjects("$tracking..refs/heads/$branch",
		format => '%h %s');
	my $diff = $git->diff_files($tracking, "refs/heads/$branch");

	return {
		new_branch => 0,
		commits    => \@commits,
		count      => scalar(@commits),
		changed    => scalar(@{$diff->{changed}}),
		deleted    => scalar(@{$diff->{deleted}}),
	};
}

# }}}
# }}}

### INTERNAL {{{

# _recheck_control - D30's in-sync rule, asked once more before the first push {{{
#
# A marker is a bare sha with no ancestry link to the deployment branch, so it
# means something only where the commit it names can be fetched from the
# remote, and the deploy that reads it may run on another machine.  Control
# moving under the run is therefore the one condition that makes every
# delivery stale, and it is the one the pre-flight cannot settle for good,
# because it asks before the walk and the walk takes time.
#
# Genesis never moves control, so each refusal names the corrective step and
# leaves control where the operator's teammate put it.  The sentence is
# returned rather than printed, because the command closes the session before
# it speaks and a stage that printed for itself would speak first.
#
# A fetch that could not reach the remote is passed over here.  The question
# this asks is about control and the answer to a remote that has gone away is
# D82's, which the push below raises for itself, so a failed refresh leaves
# the reading to the tracking ref and the push to say what it finds.
sub _recheck_control {
	my ($git, $control, $remote) = @_;
	return undef unless $git && defined $control && length $control;

	$git->fetch_branches([$control], $remote);
	my $state = $git->resolve_branch($control, remote => $remote);
	return undef if $state && $state->{state} eq 'in-sync';

	# The query has six answers and a seventh silence, and in-sync above is
	# the only one that lets the push go out.  Each of the rest earns words
	# of its own, because the step that repairs one repairs none of the
	# others and an operator told to rebase a branch the remote has never
	# had gets nowhere.
	my $named    = $remote // 'the remote';
	my $tracking = sprintf('%s/%s', $named, $control);
	my $what     = $state ? $state->{state} : 'gone';

	my ($said, $remedy);
	if ($what eq 'gone') {
		$said = sprintf("is neither here nor on #C{%s} any more, and the ".
		                "environment files live on it", $named);
		$remedy = "Put it back";
	} elsif ($what eq 'no-remote') {
		$said = sprintf("is here and no longer on #C{%s}, so nothing it ".
		                "holds can be read by a deploy on another machine",
		                $named);
		$remedy = sprintf("Push it with #C{git push %s %s}", $named, $control);
	} elsif ($what eq 'no-local') {
		$said = "has gone from this repository since the run started";
		$remedy = sprintf("Write the ref with #C{git checkout -B %s %s}",
		                  $control, $tracking);
	} elsif ($what eq 'ahead') {
		$said = sprintf("carries %s that are not on #C{%s}, which are ".
		                "unpushed", _commits($state->{ahead}), $tracking);
		$remedy = sprintf("Push them with #C{git push %s %s}", $named, $control);
	} elsif ($what eq 'behind') {
		$said = sprintf("is behind #C{%s} by %s, so everything this run ".
		                "computed is stale", $tracking, _commits($state->{behind}));
		$remedy = sprintf("Rebase it with #C{git pull --rebase %s %s}",
		                  $named, $control);
	} else {
		$said = sprintf("is ahead of #C{%s} by %s and behind it by %s, so it ".
		                "is both unpushed and stale", $tracking,
		                _commits($state->{ahead}), _commits($state->{behind}));
		$remedy = sprintf("Rebase with #C{git pull --rebase %s %s} and push ".
		                  "with #C{git push %s %s}",
		                  $named, $control, $named, $control);
	}

	return sprintf(
		"Refusing to publish.  The control branch #C{%s} %s.  Genesis never ".
		"moves control.  Nothing was pushed, and every branch this run wrote ".
		"has been put back.  %s, then run #C{genesis propagate} again.",
		$control, $said, $remedy
	);
}

# }}}
# _commits - the count and its noun, so the verb around it reads {{{
sub _commits {
	my ($n) = @_;
	$n = 0 unless defined $n;
	return sprintf('%d commit%s', $n, $n == 1 ? '' : 's');
}

# }}}
# _reset_publish_set - put every branch the run committed to back at T {{{
#
# A branch carrying a commit the remote has never seen is the illegal initial
# state D96 names, and a run that stops before its first push must not leave
# one behind.  Both such runs come through here, which are the one a moved
# control refuses and the one the operator declined, and the set is the
# session's own, which is the set an abort resets, so those two and the
# abort put back exactly the same work.  Control is not in it, because I2
# keeps committed work on control whole.
sub _reset_publish_set {
	my ($session) = @_;
	return 0 unless $session;

	# A deployment branch the remote has never had is refused in the
	# pre-flight, so every one of those goes back to T.  A pull request
	# branch may be one this run cut itself, and the session recorded that,
	# so putting it back is deleting it rather than a state nobody can undo.
	my @branches = $session->committed_branches;
	$session->restore_branch($_) for @branches;
	return scalar(@branches);
}

# }}}
# _spec_for - the ref spec a push result belongs to {{{
sub _spec_for {
	my ($specs, $branch) = @_;
	for my $spec (@$specs) {
		return $spec if $spec->{branch} eq $branch;
	}
	return {};
}

# }}}
# _record_for - the walk's record for an environment {{{
sub _record_for {
	my ($records, $env) = @_;
	return undef unless defined $env;
	for my $rec (@$records) {
		return $rec if ($rec->{env} // '') eq $env;
	}
	return undef;
}

# }}}
# _mark_delivered - the commit axis of I8, for an environment that published {{{
#
# The report's per-commit word defaults to delivered, and the publish is what
# the enum names as the writer of it, so the word is written here for every
# commit an environment actually got onto R.  A rejected environment's commits
# are left null, because they are delivered in no sense the word carries.
sub _mark_delivered {
	my ($rec) = @_;
	return unless $rec;
	$_->{outcome} = 'delivered' for @{$rec->{pending} || []};
	return;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=0:noet
