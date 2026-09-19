package Genesis::CI::Status;
# The pipeline-status read model of D91.  One canonical record for the
# deployment root the command runs in, computed from the walk the propagate
# run uses, rendered either as the indented tree or as the JSON --json emits.
# It moves no branch and writes nothing to vault.  The refresh it does by
# default materialises local refs the remote already holds, and it hands its
# events to the caller rather than printing them.
use strict;
use warnings;

use Exporter qw/import/;
use JSON::PP ();

use Genesis;
use Genesis::Term qw/csprintf/;
# The one refusal code this module has to tell apart, which is what says
# whether GitHub itself went quiet or the settings for reaching it are
# missing, and the two get different words.
use Genesis::Exit qw/UNAVAILABLE/;
use Genesis::CI::Walk ();
use Genesis::CI::Preflight ();
# Genesis::CI::Report owns every word an operator reads about an outcome, so
# the held qualifier and the per-commit hold reason are rendered by the same
# two subs the propagation run's own report calls rather than by a second pair
# here, which is the one thing that could make the two commands disagree about
# a phrase.
use Genesis::CI::Report qw/held_qualifier hold_reason/;
# Genesis::CI::PullRequest owns every decision the run makes about a pull
# request, so the client, the state read, the copy onto the record, and the
# approved arm are asked of it here rather than written a second time.
use Genesis::CI::PullRequest ();
# Genesis::CI::Marker owns the marker's vocabulary, so the snapshot reader
# below asks it which control commits a message names rather than spelling the
# prefix a second time.
use Genesis::CI::Marker ();
use Service::Git;

our @EXPORT_OK = qw/status_records render_tree render_json/;

# The word every cell resting on a refresh carries where the operator asked
# for none, which Refresh and divergence owns and which the marking of the
# stale report writes onto the record.
use constant UNVERIFIABLE => 'unverifiable';

# The five classes of D91, each mapped to markup Genesis::Term already has, so
# the renderer emits no escape sequence of its own.
our %CLASS_MARKUP = (
	settled   => 'G',
	in_flight => 'Y',
	on_ice    => 'B',
	wrong     => 'R',
	inert     => 'K',
);

our %CLASS_GLYPH = (
	settled   => '+',
	in_flight => '!',
	on_ice    => 'O',
	wrong     => '-',
	inert     => '*',
);

# Worst first, so the row's glyph and name take the class an operator should
# look at before reading a phrase.
our @CLASS_ORDER = qw/wrong on_ice in_flight settled inert/;

# status_records - the canonical record for one deployment root {{{
#
# D91 fixes the record, and a command runs in one deployment root, so there is
# one record and the caller renders it.  The walk decides the routing and the
# certification, and the command renders what it hands back.
sub status_records {
	my ($top, %opts) = @_;
	my $git     = $opts{git} // Service::Git->new('.');
	my $refresh = exists $opts{refresh} ? $opts{refresh} : 1;

	my $refreshed = $refresh
		? $top->fetch_pipeline_envs($git, command => 'pipeline-status')
		: undef;

	# The status reports every state and resolves none, so a diverged control
	# is a line in the report rather than a refusal, and the one answer that
	# leaves the command nothing to read is still refused.
	my $control = Genesis::CI::Preflight::require_control($top, $git,
		refreshed     => $refreshed,
		command       => 'pipeline-status',
		unverifiable  => $refresh ? 0 : 1,
		on_divergence => 'report');

	# The events the control check raised, handed to the caller the moment
	# they exist rather than on the record at the end.  The refresh creates
	# the local control ref from the remote where this clone lacks it, which
	# moves a ref the operator did not, and a walk that refuses below would
	# otherwise end the command with that move unaccounted for.  They go to
	# the caller rather than to a terminal, because this module computes a
	# record and one that wrote to a terminal mid-computation would be no use
	# to a caller that wanted the record alone.
	#
	# The stage's own event lines are not raised, because it moves no branch
	# for this caller and a line reading "fast-forwarded" over a branch that
	# stands where it stood would be an account of a write nobody made.  What
	# those branches are is in the record's divergence cell.
	$opts{on_events}->(@{$control->{events}})
		if $opts{on_events} && @{$control->{events}};

	# The stage is asked read-only, because this command reports and writes
	# nothing.  A branch the stage would have reset or fast-forwarded keeps
	# its own ref and carries the ref a real run would have moved it to,
	# which is the ref this report should be reading, and no caveat about a
	# preview is said, because nobody is about to make a run.
	my $initial = Genesis::CI::Preflight::initial_state($top, $git,
		envs      => [$top->pipeline_env_names],
		command   => 'pipeline-status',
		refreshed => $refreshed // 0,
		control   => $control,
		read_only => 1);

	# The scope, composed here through the walk's own reader and handed to
	# the walk below, so the pull request branch this report asks GitHub
	# about is the branch the walk matches and the branch a run would open.
	# One composition answers both, so the two cannot disagree about a name
	# and the walk composes no scope of its own.  The topology behind it is
	# still built more than once a run, since pipeline_env_names above asks
	# for it too and Genesis::Top::pipeline_topology memoises none of that
	# work, and that is a cost for whoever takes the reader on next.
	my @composed = Genesis::CI::Walk::scope_for($top, scope => $opts{scope});
	my ($github, $pr_state_of) = _pull_request_state($top, $composed[0]);

	my $record = Genesis::CI::Walk::plan($top,
		git       => $git,
		branches  => $initial->{branches},
		composed  => \@composed,
		refreshed => $refresh ? 1 : 0,
		# D52's recovery, which the walk makes for itself out of these two.
		# A deployment branch whose pull request went in as a squash carries
		# no marker of its own, and the merged pull request in the answer
		# read above is the only thing that still says which control commit
		# it received.  The propagate run hands the walk the same pair, so a
		# branch like that reads caught up in both commands rather than
		# reading as though the whole of control were due in this one.
		github    => $github,
		state_of  => $pr_state_of,
		# The walk's own refusals close by saying what was written, which is
		# the account a run owes and no account at all to somebody who asked
		# for a report.  This caller writes nothing and has nothing to
		# report, so it says that instead.
		outcome   => 'No report was produced.',
	);

	# The walk writes the flag as a number, so it is made the encoder's own
	# boolean here and the marking below writes the same kind.  --json then
	# emits one shape for the field whichever form of the command wrote the
	# record, which is what D91 asks of every field it fixes.
	$record->{refreshed} = $record->{refreshed} ? JSON::PP::true : JSON::PP::false;

	# What the API answered, carried onto the walk's own records through the
	# arm's own writer, so the column below and the run's report read one
	# answer about one pull request.  An environment the read said nothing
	# about keeps the branch the walk seeded and nothing else, and the column
	# falls back to the proposed record for it.
	for my $row (@{$record->{environments}}) {
		next unless $row->{pr};
		my $state = $pr_state_of->{$row->{env}} or next;
		Genesis::CI::PullRequest::carry_state($row, $state);

		# D51's approved arm, taken from the sub the run takes it from rather
		# than decided again here, so the report and the run cannot disagree
		# about what an approved pull request does to an environment.  It
		# touches nothing outside the record: the due commits move to held
		# under the awaiting-merge reason held_qualifier reads, which is the
		# wait the operator acts on and the one this row has to show.
		Genesis::CI::PullRequest::freeze($row, $row->{pending})
			if ($row->{pr}{state} // '') eq 'approved'
			&& @{$row->{pending} || []};
	}

	# D43's staleness, asked through the one query Genesis::Top gives it, so
	# the deploy pre-flight, the propagate pre-flight, and this command
	# cannot disagree about whether the pipeline is stale.  The query answers
	# an arrayref of env and reason pairs, and the reasons are its own two
	# words rather than any filename, so the two lists below run in step and
	# the renderer reads the pair at one index.
	#
	# The query diffs the applied commit against control, and git refuses a
	# diff against an object this clone does not have, so a clone that never
	# fetched the commit the pipeline was applied from ended the whole report
	# on that refusal.  A command that reports and resolves nothing says what
	# it cannot read instead: the three fields are left null, which is one
	# more reading than a boolean carries, and both renderers say the
	# staleness is unverifiable.
	if (my $applied = $record->{applied}) {
		if ($git->holds_commit($applied->{control_commit})) {
			my $changes = $top->pipeline_staleness($git);
			$applied->{stale}         = @$changes ? JSON::PP::true : JSON::PP::false;
			$applied->{stale_envs}    = [map {$_->{env}} @$changes];
			$applied->{stale_because} = [map {$_->{reason}} @$changes];
		}
	}

	# The walk leaves drifted null for this command to fill, and the fill
	# reads git off the branch the walk already named.  The ref is the one
	# the walk routed from, which under this command is the ref a real run
	# would have moved the branch to wherever the stage held its move back,
	# so the snapshot the drift is measured against is the snapshot every
	# other column of the row was read from.
	for my $row (@{$record->{environments}}) {
		# Every row carries the seed annotation, false where the row is not
		# a pending one and false where there was no branch to count it
		# over, so --json emits one shape for the field whatever the row
		# reads and no consumer meets the key missing.  It is set before the
		# two exits below for that reason.
		$row->{seeded} = JSON::PP::false;

		next if $row->{error};
		my $settled = $initial->{branches}{$row->{env}} or next;

		# The ref the walk routed this environment from, which under this
		# command is the ref a real run would have moved the branch to
		# wherever the stage held its move back.  Both fills read it, so the
		# snapshot the drift is measured against and the history the seed is
		# counted over are the ones every other column of the row was read
		# from.
		my $ref = $settled->{assumed} // $settled->{branch};
		$row->{drifted} = drift_for($git, $ref);

		# D91 keeps seeded an annotation on the pending reading rather than
		# a fifth reading of its own, so only a pending row is asked and
		# every other row costs nothing, which is a whole git process and a
		# list of fifty commits.  It is written as the encoder's own boolean,
		# as the walk's manual marker is, so --json emits one shape for the
		# field whatever the row reads.
		$row->{seeded} = (($row->{reading} // '') eq 'pending-deploy'
			&& _seeded($git, $ref)) ? JSON::PP::true : JSON::PP::false;
	}

	$record->{breaches} = [unfetchable_markers($record, $git)];

	# Last, so that everything the record carries has been filled before the
	# stale form goes over it.
	$record = _mark_unverifiable($record) unless $refresh;

	return $record;
}

# }}}
# _mark_unverifiable - every value that rests on a refresh nobody ran {{{
#
# D40 keeps one --no-refresh, on this command alone, and it yields a
# read-only report with every cell that rests on the remote-tracking refs
# marked unverifiable.  The divergence cell is set through its state rather
# than replaced by a string, so --json emits one shape for that field
# whichever form of the command wrote it, and a row that had no divergence at
# all gains the same shape with the same word in it.
#
# The word goes no further than that.  Marking each phrase component with a
# class of the wrong kind would make worst_class answer wrong for every row,
# so the colour an operator reads a stale report by would carry no
# information at all.  What the renderers add is the header, the bracket on
# the routing summary, and the qualifier on the breach line, each of which
# says the reading rather than replacing it.
sub _mark_unverifiable {
	my ($record) = @_;
	$record->{refreshed} = JSON::PP::false;
	for my $row (@{$record->{environments}}) {
		# A row that failed to load is left alone, as the drift fill and the
		# breach report leave it.  Nothing about that row was read, so a
		# divergence cell saying the reading is unverifiable would claim a
		# reading was withheld where none was ever taken.
		next if $row->{error};
		$row->{divergence}{state} = UNVERIFIABLE;

		# The branchless reading rests on the same refs the divergence cell
		# does, because it is the absence of a branch record and nothing
		# else, and unrefreshed it cannot tell an environment nobody has
		# applied from one a teammate applied an hour ago.  It is marked
		# rather than withheld, because the wait is still the likelier
		# reading of the two and an operator who cannot tell them apart has
		# to be told which one they are holding.  The state is left standing
		# so that the wait is still worded by the one sub that owns it.
		$row->{certified}{unverifiable} = JSON::PP::true
			if ($row->{certified} || {})->{state} &&
			   $row->{certified}{state} eq 'no-branch';
	}
	return $record;
}

# }}}
# drift_for - the snapshot axis of D33 {{{
#
# A deployment branch carries a marker on every commit propagation wrote, so
# the newest marked commit is the snapshot the branch is certified to hold and
# everything above it is a hand edit.  D33 makes that edit legal and
# temporary, so the reading is never a refusal; it is a report, and it names
# every file so the operator sees the whole edit.
#
# The comparison is git alone.  Asking the environment for its propagation set
# would load the kit through vault, which a read-only caller that has not
# connected meets as a refusal, and the branch's own history answers the same
# question without one.
sub drift_for {
	my ($git, $branch) = @_;
	return undef unless defined $branch && length $branch;

	my ($hand, $marked) = _newest_unmarked($git, $branch);
	return undef unless $marked;

	my $diff  = $git->diff_files($marked, $branch);
	my @files = sort @{$diff->{all} || []};
	return undef unless @files;

	return {files => \@files, commit => $hand};
}

# }}}
# unfetchable_markers - the H30 breach report {{{
#
# A marker is a bare sha with no ancestry link to the branch, because
# propagation copies files and never commits, so it means something only while
# a ref still reaches the commit.  D31 closes the hazard through the branch
# protection; a rewrite that got past it is reported here by name, because
# nothing else in the command would notice.
sub unfetchable_markers {
	my ($record, $git) = @_;
	my @breaches;
	# One answer per sha, because a rewrite that dropped a commit dropped it
	# for every environment whose marker names it, and the reading costs two
	# git processes each time it is asked.
	my %reaches;
	for my $row (@{$record->{environments}}) {
		next if $row->{error};
		my $sha = $row->{merged} or next;
		$reaches{$sha} //= $git->commit_exists($sha);
		next if $reaches{$sha};
		push @breaches, {env => $row->{env}, control_commit => $sha};
	}
	return @breaches;
}

# }}}
# _seeded - is the branch's delivered history its first delivery alone {{{
#
# D61 makes the seed the branch's first delivery, and nothing about the
# reading tells it apart from the tenth, so the annotation is answered off the
# branch's own history, which carries one marked commit and no more.
#
# What bounds the cost is the fifty-commit limit, since log_subjects runs git
# and builds the whole list before the loop begins.  Returning at the second
# marked commit saves the iteration below it and no git work at all, and it is
# there so that the answer is decided at the first commit that decides it.
#
# Genesis::CI::Marker owns the marker's vocabulary here as it does in
# _newest_unmarked, so nothing spells the prefix a second time.
sub _seeded {
	my ($git, $branch) = @_;
	return 0 unless defined $branch && length $branch;

	my $marked = 0;
	for my $commit ($git->log_subjects($branch, body => 1, limit => 50)) {
		next unless Genesis::CI::Marker::in_text($commit->{message});
		return 0 if ++$marked > 1;
	}
	return $marked == 1 ? 1 : 0;
}

# }}}
# _newest_unmarked - the hand commit above the snapshot, and the snapshot {{{
#
# One walk answers both, newest first.  The hand commit is the newest commit
# carrying no marker, and the snapshot is the first commit below it that
# carries one.  Genesis::CI::Marker owns the marker's vocabulary and answers
# which control commits a message names, so nothing here spells the prefix.
sub _newest_unmarked {
	my ($git, $branch) = @_;

	my $unmarked;
	for my $commit ($git->log_subjects($branch, body => 1, limit => 50)) {
		return wantarray ? ($unmarked, $commit->{sha}) : $unmarked
			if Genesis::CI::Marker::in_text($commit->{message});
		$unmarked //= $commit->{sha};
	}
	return wantarray ? ($unmarked, undef) : $unmarked;
}

# }}}
# render_json - the record itself, in canonical key order {{{
#
# One object, because a command runs in one deployment root and the record is
# that root's.  A repository with a second root is read by running the command
# in it, which is how every other pipeline command reads one.
sub render_json {
	my ($record) = @_;
	return JSON::PP->new->canonical->pretty->encode(_jsonable($record));
}

# }}}
# _jsonable - the record with every object in it written out as its text {{{
#
# A deployment's timestamp reaches the record as a Time::Piece, because that
# is what the exodus reader answers with, and an encoder handed an object of
# any kind raises rather than guessing at one.  So each object is written as
# text, and the timestamp is written in the form vault holds it in rather than
# in the ctime form Time::Piece stringifies to, because this output is the one
# a machine reads and a reader comparing it against the stored record has to
# get the same string back, timezone and all.  The record itself is left
# alone, since a caller may still be holding it.
sub _jsonable {
	my ($value) = @_;

	return $value unless ref $value;

	# The encoder writes its own booleans back as true and false, so they are
	# the one blessed thing that goes through untouched.  It is asked first,
	# because a guard for a blessed scalar standing below the container arms
	# reads as though nothing could reach it.
	return $value if ref($value) eq 'JSON::PP::Boolean';
	return $value->strftime(EXODUS_TIME_FORMAT)
		if ref($value) eq 'Time::Piece';

	return [map {_jsonable($_)} @$value] if ref $value eq 'ARRAY';
	return {map {($_ => _jsonable($value->{$_}))} keys %$value}
		if ref $value eq 'HASH';

	return "$value";
}

# }}}
# render_tree - the root's environments as an indented tree in DAG order {{{
#
# The rendering is D91's constraint and not a suggestion, so we render the
# tree, the branch and deploy columns side by side, and one composed phrase
# per row.  The header names the pipeline by the label the configuration gives
# it, and by the deployment type where a repository names no label.
sub render_tree {
	my ($record, %opts) = @_;
	my @out;

	push @out, csprintf("\n#G{Pipeline}: #C{%s}  #Yi{provider}: %s  #Yi{control}: #C{%s}#Yi{\@}#C{%s}",
		$record->{pipeline} // $record->{type}, $record->{provider},
		$record->{control}{branch}, _short($record->{control}{commit}));
	# Directly under the pipeline header, so the operator reads that the
	# report rests on a stale pipeline before they read a row.
	push @out, _applied_line($record) if $record->{applied};
	# Above the columns, because an operator has to read that the report is
	# stale before they read a row of it.
	push @out, csprintf("  #R{the report is stale, because no refresh ran; every cell marked %s rests on one}",
		UNVERIFIABLE) if $opts{stale};
	push @out, '';

	my $width = 0;
	for my $row (@{$record->{environments}}) {
		my $w = ($row->{depth} * 2) + length($row->{env});
		$width = $w if $w > $width;
	}

	push @out, csprintf("  %s  #u{%-7s}  #u{%-7s}  #u{%s}",
		' ' x $width, 'branch', 'deploy', 'status');

	# The environments a breach names, read once before the rows, so each row
	# can take the class the breach puts on it.  The record already names
	# them, so there is no new field for the renderer to read.
	my %breached = map {($_->{env} => 1)} @{$record->{breaches} || []};

	for my $row (@{$record->{environments}}) {
		my @phrase = compose_phrase($row, stale => $opts{stale});
		# The glyph and the name take the worst thing on the row, and a
		# marker naming a commit nothing can fetch is worse than anything
		# the phrase carries.  It is forced here rather than composed as a
		# component, because the breach is written out in full beneath the
		# table and a phrase that said it as well would say it twice.
		my $class  = $breached{$row->{env}} ? 'wrong' : worst_class(@phrase);
		my $name   = sprintf("%s%s%s",
			'  ' x $row->{depth}, $row->{env},
			' ' x ($width - ($row->{depth} * 2) - length($row->{env})));

		push @out, csprintf("  #%s{%s}  %-7s  %-7s  #%s\@{%s}%s",
			$CLASS_MARKUP{$class}, $name,
			_short($row->{merged}) // '-',
			_short($row->{deployed} ? $row->{deployed}{control_commit} : undef) // '-',
			$CLASS_MARKUP{$class}, $CLASS_GLYPH{$class},
			join('; ', map { csprintf("#%s{%s}", $CLASS_MARKUP{$_->[0]}, $_->[1]) } @phrase));
	}

	# Beneath the table, because a breach is about the repository rather than
	# about one row of it, and an operator reading the rows should meet it
	# after the environment it names rather than in the middle of the report.
	#
	# The whole reading rests on the remote-tracking refs, so under the stale
	# form it is qualified rather than withheld.  A commit propagated an hour
	# ago and never fetched reads here exactly like one the remote dropped,
	# and an operator who cannot tell the two apart needs to be told which
	# reading they are holding.
	for my $breach (@{$record->{breaches} || []}) {
		push @out, csprintf("  #R{%s's marker names control@%s, which the remote no longer holds%s}",
			$breach->{env}, _short($breach->{control_commit}),
			$opts{stale} ? sprintf(' [%s]', UNVERIFIABLE) : '');
	}

	push @out, '';
	return join("\n", @out)."\n";
}

# }}}
# _pull_request_state - what GitHub says about each environment's pull request {{{
#
# The client is built where an environment in scope would deliver into a pull
# request, which is the branch the walk seeded, and not at all where none
# would.  D57 draws the rule wider than that, since it counts an environment
# holding a proposed record as one that needs the API too, and the propagate
# run narrows it the same way this does, so an environment whose policy no
# longer asks for a pull request reads its proposed record unvalidated in both
# commands.
#
# The answer is keyed by environment, and an environment it holds no key for
# is one nothing was read about.
#
# The client is asked for only where a token exists to build it with.  Built
# without one it warns that the run's branches are still written and published,
# which is false of a command that writes nothing at all, and a missing token
# is the fallback the pull request column is built for rather than something to
# warn an operator about.
#
# This command never refuses on any of it.  Ruling 49 leaves pipeline-status
# one refusal, which is the disowned pipeline, and D57 already has the column
# report a proposed record flagged as possibly outdated where no token was
# there to validate it with.  All three refusals the two subs below raise are
# therefore rendered that same way, which are an API that will not answer, a
# repository that resolves no owner and repository pair, and a token GitHub
# will not name an owner for, and the run says once which of them it met.  A
# writing run still refuses on all three, because a run about to open a pull
# request branch cannot guess what a reviewer decided, which is why the
# refusal closure is handed in from here rather than softened where the
# refusals live.
sub _pull_request_state {
	my ($top, $scope) = @_;

	my @wanted = grep {$_->{pr_branch}} @$scope;
	return (undef, {}) unless @wanted && $ENV{GITHUB_AUTH_TOKEN};

	# What the run would have refused on, in this command's own words rather
	# than the refusal's, because those are written for somebody who was
	# about to write a branch.  The first one is kept, since a second refusal
	# is the same story about the same API told again.
	#
	# Three refusals arrive here and each gets its own clause, because what
	# an operator does about an API that went quiet, about a repository that
	# names no pair, and about a token GitHub will not name an owner for are
	# three different things.  The exit code tells the unreadable API from
	# the other two, and the pair itself tells those two apart, which costs
	# nothing because the source control block resolves once and keeps its
	# answer.
	#
	# Every refusal inside Genesis::CI::PullRequest hands a hashref of
	# options first, which is the contract this closure is written to, and
	# anything else is read as the configuration case rather than taken
	# apart as a hashref and died on.
	my $unconsulted;
	my $refuse = sub {
		my ($spec) = @_;
		my $code = ref $spec eq 'HASH' ? ($spec->{exitcode} // 0) : 0;
		$unconsulted //= $code == UNAVAILABLE
			? 'GitHub did not answer'
			: $top->source_control_repository
				? 'GitHub named no owner for the token this run carries'
				: 'This repository delivers into pull requests and resolves '.
				  'no owner and repository pair';
		return;
	};

	my $github = Genesis::CI::PullRequest::client_for_run($top,
		records => [map {{pr => {branch => $_->{pr_branch}}}} @wanted],
		refuse  => $refuse);
	return _unconsulted($unconsulted) if $unconsulted;
	return (undef, {}) unless $github;

	my $owner_repo = $top->source_control_repository;

	# The client goes back with the answer, because the walk reads a marker a
	# squash merge dropped out of the merged pull request itself and wants
	# both.  What it takes and why is beside propagate's own pair, in
	# Genesis::Commands::Pipelines::propagate, and the two callers hand the
	# walk the same thing.
	#
	# The three fields pr_state reads and no more, which is what lets the
	# state be read before the walk has composed a record of its own.
	my %state_of;
	for my $env (@wanted) {
		my $state = Genesis::CI::PullRequest::pr_state($github, $owner_repo, {
			env    => $env->{env},
			branch => $env->{branch},
			pr     => {branch => $env->{pr_branch}},
		}, refuse => $refuse);

		# One environment the API would not answer about says nothing about
		# how it would answer about the next, but a client that could not be
		# read once is not one this report should keep asking, and every
		# environment it would have served reads alike.
		return _unconsulted($unconsulted) if $unconsulted;
		$state_of{$env->{env}} = $state;
	}

	return ($github, \%state_of);
}

# }}}
# _unconsulted - the one line a report says where GitHub went unread {{{
#
# One sentence on standard error, once a run, saying why nobody asked and what
# the column is therefore reading.  It answers what _pull_request_state answers
# with no token at all, so every environment the client would have served
# renders as the no-token case does.
sub _unconsulted {
	my ($why) = @_;

	warning(
		"%s, so the pull request column below is read from each ".
		"environment's proposed record and says nothing about what a ".
		"reviewer has since decided.",
		$why
	);

	return (undef, {});
}

# }}}
# _applied_line - the header that says the pipeline is stale {{{
#
# D43 detects staleness by a path comparison that needs no fly, and
# Genesis::Top gives it one method, so we ask that method rather than diffing
# here.  The line names each changed environment with the reason the query
# gave for it, and the command that fixes it.
sub _applied_line {
	my ($record) = @_;
	my $applied = $record->{applied} or return ();

	my $line = csprintf("  #Yi{applied at} #C{%s}", _short($applied->{control_commit}));

	# Null rather than false is the reading status_records leaves where this
	# clone does not hold the commit the pipeline was applied from, since the
	# query that answers the staleness cannot be asked about a commit git
	# does not have.  The remedy is the fetch that brings it, said in one
	# clause, because a report is not the place to argue the case.
	return $line.csprintf("  #R{[stale: %s]}  this clone does not hold that commit",
		UNVERIFIABLE) unless defined $applied->{stale};

	return $line unless $applied->{stale};

	my @changed = @{$applied->{stale_envs} || []};
	my @reasons = @{$applied->{stale_because} || []};
	return $line.csprintf("  #R{[stale: %s]}  run #C{genesis pipeline-apply}",
		join(', ', map {sprintf('%s %s', $changed[$_], $reasons[$_])} 0 .. $#changed));
}

# }}}
# _pull_request_component - the column the pull request mode needs {{{
#
# The walk's pr field is the branch the pull request mode delivers onto, which
# Genesis::Top::pr_branch_for composes, so the name this column reads and the
# name propagation opens come from one accessor and cannot disagree.  The
# baseline matched a literal propagate/<env>/ prefix that propagation has never
# opened, which is why an operator was told nothing waited while a pull request
# sat open for review.
#
# With a token the state has been read, so the answer is what the API gave.  A
# number is only ever taken off the open listing, so a number on the record is
# an open pull request and the word open is the truth about it rather than a
# second reading.  Where the read found nothing open the column says nothing,
# because the rest of the row already says what the environment is doing.
#
# Without a token the proposed record answers.  It is a pointer to a pull
# request Genesis itself opened rather than a cache of somebody else's state,
# and reading it costs no API call at all, so the column says which pull
# request was proposed and for which control commit, and says plainly that
# nobody has read what a reviewer since decided.
sub _pull_request_component {
	my ($row) = @_;

	# An environment whose policy asks for no pull request has no pull request
	# column at all.  The walk seeds the branch onto every environment that
	# would deliver into one and leaves the field null for the rest, so that
	# field is the whole of the question, and the proposed record below is
	# read only for an environment the walk says would have one.
	my $pr = $row->{pr} or return ();

	if (defined $pr->{state}) {
		return () unless defined $pr->{number};
		return [in_flight => sprintf('[PR #%d open: %s]',
			$pr->{number}, $pr->{state})];
	}

	# A record naming no pull request is one no run has proposed anything
	# through, and a number is the whole of what this component is built on.
	my $proposed = $row->{proposed};
	return () unless $proposed && defined $proposed->{number};
	return [in_flight => sprintf(
		'[PR #%d proposes control@%s: review state unread, possibly outdated]',
		$proposed->{number}, _short($proposed->{control_commit}))];
}

# }}}
# compose_phrase - the components in D91's fixed order {{{
#
# The order is the certification word, the routing summary, the snapshot flag,
# the pull request, the hold, and [manual].  Each component keeps its own
# class, and detail sits in square brackets after the word it qualifies.
sub compose_phrase {
	my ($row, %opts) = @_;
	return ([wrong => sprintf('load error: %s', $row->{error})]) if $row->{error};

	my %word = (
		'deployed'       => [settled   => 'deployed'],
		'pending-deploy' => [in_flight => 'awaiting deployment'],
		'unseeded'       => [settled   => 'unseeded'],
		# The reading says what was read and nothing about what the
		# environment waits for.  What it waits for is the held qualifier
		# below, which answers awaiting pipeline-apply for the environment
		# the pipeline was never applied to, so the phrase carries that
		# wording once and a hold can stand ahead of it.
		'not-propagated' => [inert     => 'not propagated'],
	);

	my @phrase = ($word{$row->{reading}} || [wrong => 'unknown reading']);
	# D61's seed, directly after the certification word, because the
	# annotation qualifies that word rather than standing beside it.  It
	# takes the in-flight class the pending word beside it takes, since a
	# seeded environment is one waiting on its first deploy.
	push @phrase, [in_flight => 'seeded'] if $row->{seeded};
	my @pending = @{$row->{pending} || []};
	# The routing summary is the component that rests on the refresh, so it
	# is the component the stale form marks.  The word rides in brackets
	# after the words it qualifies and the component keeps its own class,
	# because a component marked wrong would leave worst_class answering
	# wrong for the whole row.
	push @phrase, [in_flight => sprintf('%d pending%s', scalar @pending,
		$opts{stale} ? sprintf(' [%s]', UNVERIFIABLE) : '')]
		if @pending;
	# A branch no run may start from is described rather than refused, so the
	# row says which state it is in and what the operator does about it.  The
	# remedy is one sentence, because the whole of it is the refusal's own
	# paragraph and a tree line has room for the act rather than the argument.
	#
	# Neither remedy is offered by a stale report.  Both readings rest on the
	# remote-tracking refs, and unrefreshed they cannot tell a branch nobody
	# published from one a teammate pushed an hour ago.  Telling an operator
	# to delete the second is worse than telling them nothing, so the stale
	# form says nothing here and the divergence cell carries the word
	# instead.
	if (my $div = $opts{stale} ? undef : $row->{divergence}) {
		push @phrase, [wrong => 'unrelated [no ancestor in common with the '.
			'remote\'s; move anything wanted to control and delete it]']
			if $div->{unrelated};
		push @phrase, [wrong => 'local only [the remote has no such branch; '.
			'move anything wanted to control and delete it]']
			if ($div->{state} // '') eq 'no-remote';
	}

	if (my $drift = $row->{drifted}) {
		push @phrase, [wrong => sprintf('drifted [%s differs: hand commit]',
			join(', ', @{$drift->{files}}))];
	}
	# D91 puts the pull request between the snapshot flag and the hold.  The
	# flag says what the branch itself holds, this says which pull request is
	# carrying the change and what a reviewer made of it, and the hold below
	# says what the environment is waiting for.
	push @phrase, _pull_request_component($row);
	# The hold sits where the design's order puts it, after the snapshot flag
	# and before the marker, because a marker says how the environment is
	# driven and a hold says what it is waiting for, and an operator reads
	# the waiting first.  The qualifier answers what the environment waits
	# for and the word held is written here, where this command decides the
	# outcome, exactly as the run writes it where it decides its own.  Every
	# held component takes the on-ice class, because a hold is something a
	# person set or the topology imposed and nothing moves until it is
	# cleared.
	if (my $qualifier = held_qualifier($row)) {
		# The word rides in brackets after the wait it qualifies, as the
		# routing summary's does, and the component keeps its own class,
		# because a component marked wrong would leave worst_class answering
		# wrong for the whole row.  What is marked is the certification cell,
		# which the stale form marks where the wait rests on a refresh.
		push @phrase, [on_ice => sprintf('held, %s%s', $qualifier,
			($row->{certified} || {})->{unverifiable}
				? sprintf(' [%s]', UNVERIFIABLE) : '')];
		# Why this one commit is held, which is a different question from
		# what the environment waits for, and the answer carries the
		# ancestor's own state so an operator is not left to infer it from
		# another row.
		#
		# Two rules keep the row from saying one wait twice, and each one
		# sees a case the other is blind to.
		#
		# The first compares reason names.  Where the standing hold is what
		# took the commit, apply_hold stamps that commit with the hold's own
		# text while the qualifier says the same fact in the words a hold is
		# announced in, so the two strings differ and no comparison of the
		# rendered words could ever suppress the repeat.  The name on-hold is
		# the only thing the two have in common.
		my ($first) = @{$row->{held} || []};
		if ($first && ($first->{reason} // '') ne 'on-hold') {
			# The second compares the rendered words.  An approved pull
			# request is both what the environment waits for and what holds
			# every commit standing behind it, and the qualifier and the
			# frozen commit's reason both come out of Genesis::CI::Report
			# identical, so here the names differ where the words do not and
			# only the words say the row is about to repeat itself.  It is
			# compared on the words for that reason and to save a second list
			# of reason names kept in step with that module.
			my $reason = hold_reason($first);
			push @phrase, [on_ice => $reason] unless $reason eq $qualifier;
		}
	}

	push @phrase, [inert => '[manual]'] if $row->{manual};
	return @phrase;
}

# }}}
# worst_class - the class the row's glyph and name take {{{
sub worst_class {
	my (@phrase) = @_;
	my %present = map { $_->[0] => 1 } @phrase;
	for my $class (@CLASS_ORDER) {
		return $class if $present{$class};
	}
	return 'inert';
}

# }}}
# _short - the seven characters every column of this report abbreviates to {{{
#
# Genesis::CI::Report abbreviates to the same seven wherever it names a
# control commit, in hold_reason and in held_qualifier alike, so the run's
# report and this one print one sha at one width.
sub _short { my ($sha) = @_; return defined($sha) ? substr($sha, 0, 7) : undef }

# }}}
1;
