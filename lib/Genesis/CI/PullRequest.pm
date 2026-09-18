package Genesis::CI::PullRequest;
# The pull request arm of the propagate run.  An environment in pull request
# mode takes its propagation on <pr_prefix><env>/<type> as one aggregate
# commit, and a pull request from there into <env>/<type>, and this module
# owns the aggregate, the rule that reads what a reviewer decided, and the
# proposed record's lifecycle.
#
# deliver is never imported.  The harness exports a helper of the same name
# that every test file in this step also calls, so the two are kept apart by
# always naming this one in full.
use strict;
use warnings;

use Genesis qw/bail bail_text bug info warning/;
use Genesis::Exit;
use Genesis::CI::Marker;

use Exporter qw/import/;
our @EXPORT_OK = qw/client_for_run pr_state sync_pull_request/;

# align_with_remote - bring the local pull request branch level with R {{{
#
# The discard report reads what is about to be destroyed, and what is about to
# be destroyed is what R carries, so the local ref has to be level with R
# before it is read.  The refresh fetches control and the deployment branches
# alone, because those are the branches the pre-flight classifies, so the pull
# request branch is fetched here, by the arm that is about to stand on it.
#
# The fetch runs every time, and not only where the tracking ref is missing.
# This sub is the only thing that ever writes that ref, so from the second run
# for an environment onward the ref is present and holds the previous run's
# tip, and a fetch skipped over it would reset the branch to yesterday's value
# and read yesterday's discard report.  branch_exists is asked afterwards for
# the one thing it can still answer, which is whether the remote has the
# branch at all.
sub align_with_remote {
	my ($git, $branch) = @_;
	my $remote = $git->default_remote or return 0;

	$git->fetch_branches([$branch], $remote);
	return 0 unless $git->branch_exists("$remote/$branch");

	$git->reset_hard("$remote/$branch");
	return 1;
}

# }}}
# aggregate_message - the whole aggregate commit message D49 fixes {{{
#
# The subject is the marker naming the newest due control commit, and the body
# lists every commit the aggregate carries, oldest first, each with its short
# hash and subject and the diff --stat lines for the files it changed inside
# this environment's propagation set.  The pull request body is this body
# verbatim, so the commit and the pull request can never disagree.
#
# The sha is abbreviated, which is the form T259 reads off the subject and the
# form every other builder in the tree hands the marker.  Nothing downstream
# loses by it: Marker::in_text parses four to forty hex digits, so the marker
# is still machine-read, and a reader that wants the whole sha resolves the
# abbreviation through the git handle it already holds, which is what the
# marker's own contract says it must do.
#
# The set is read at the commit being delivered, through the same reader the
# writer uses (D69), because a restructure moves the prefix that defines it and
# a body scoped by today's configuration would name files the delivery did not
# move.
#
# The sha of each entry is read under the name the walk writes on a pending
# entry, which is control_commit rather than sha.
#
# Each entry's summary is taken of the commit itself rather than between it
# and its parent, because control's own first commit has no parent and an
# environment introduced there has that commit due on its first run.
sub aggregate_message {
	my ($git, $env, $commits, %opts) = @_;

	my $newest = $commits->[-1];
	my @paths  = $env->propagation_files_at($newest->{control_commit},
		git => $git);

	my @lines = (
		Genesis::CI::Marker::build(
			$git->sha($newest->{control_commit}, short => 1), $env->name),
		'',
		sprintf('Carries %d control commit%s:',
			scalar(@$commits), @$commits == 1 ? '' : 's'),
		'',
	);

	for my $commit (@$commits) {
		push @lines, sprintf('%s %s',
			$git->sha($commit->{control_commit}, short => 1),
			$commit->{subject});
		push @lines, $git->commit_stat($commit->{control_commit}, @paths);
		push @lines, '';
	}

	push @lines, $opts{gate}, ''       if $opts{gate};
	push @lines, $opts{supersedes}, '' if $opts{supersedes};
	push @lines, $opts{review}, ''     if $opts{review};

	my $message = join("\n", @lines);
	$message =~ s/\n+$/\n/;
	return $message;
}

# }}}
# gate_line - the paragraph the body carries when the aggregate is a gate {{{
#
# D49 as corrected on 2026-09-09 has a gate constrain only what follows it, so
# the aggregate runs up to and including the gate and the commits after it are
# held.  The line names the reason the trailer gave and how many wait, so a
# reviewer can see why the pull request stops where it does.
#
# The reason is read under gate_reason, which is the name the walk writes it
# by on the entry it gates; gate beside it is the gate's own commit, and a
# line that printed that would name a sha where the trailer wrote a sentence.
#
# A gate standing on control's own tip holds nothing, and the sentence about
# what waits is left off there rather than said of nought commits.  The gate
# is still named, because the reviewer is being asked to deploy this before
# anything later lands and that is true whether or not anything later exists
# yet.
sub gate_line {
	my ($commit, $held) = @_;
	my $reason = $commit->{gate_reason} // '';
	$reason =~ s/\s+$//;
	$reason =~ s/\.$//;
	return sprintf('Gate: %s.', $reason) unless $held->{count};
	return sprintf(
		"Gate: %s. Holding %d later commit%s for %s until this deploys.",
		$reason, $held->{count}, $held->{count} == 1 ? '' : 's', $held->{env}
	);
}

# }}}
# review_paragraph - the one renderer that quotes a reviewer {{{
#
# D49 has a superseding body carry the rejection text where the API gave one,
# and D56 has a changes-requested rebuild name the review it answers.  The two
# are the same paragraph with a different opening sentence, so one renderer
# writes both and the quoting cannot drift apart between them.
sub review_paragraph {
	my ($number, $review, %opts) = @_;
	return undef unless $review && length($review->{body} // '');

	my $quoted = join("\n", map {"> $_"} split /\n/, $review->{body});
	my ($date) = ($review->{at} // '') =~ /^(\d{4}-\d{2}-\d{2})/;

	# The default is load-bearing rather than a convenience.  deliver passes
	# this same string explicitly for the changes-requested rebuild, and
	# supersedes_paragraph below passes no opening at all and takes the
	# default, so the two paragraphs read alike and are told apart by the
	# prefix.  An edit to either the default or that call site has to
	# remember the other.
	return sprintf("%s%s on #%d by %s%s:\n%s",
		$opts{prefix} // '',
		$opts{opening} // 'Changes were requested',
		$number, $review->{reviewer},
		$date ? " on $date" : '', $quoted);
}

# }}}
# supersedes_paragraph - the closing paragraph a superseding body carries {{{
#
# D49 has the body carry the rejection text where the API gives one, which is
# the body of a changes-requested review, and a link to the closed pull request
# where it does not.  A merged pull request is never a prior attempt, so
# pr_state never puts one in the rejected list.
sub supersedes_paragraph {
	my ($rejected) = @_;
	return undef unless $rejected && @$rejected;

	my ($reviewed) = grep {$_->{review} && length($_->{review}{body} // '')}
		@$rejected;
	my @bare = grep {!($_->{review} && length($_->{review}{body} // ''))}
		@$rejected;

	my @parts;
	push @parts, review_paragraph($reviewed->{number}, $reviewed->{review},
		prefix => sprintf('Supersedes #%d. ', $reviewed->{number}))
		if $reviewed;
	# An attempt the API answered with no html_url takes the sentence without
	# the colon, rather than ending it on a colon with nothing after it.  No
	# row reaches this branch: the GitHub double carries html_url on every
	# pull request it holds and GitHub itself answers one on every pull
	# request there is, so it stands for a field that has gone missing rather
	# than for a shape anything produces.
	push @parts, sprintf('Supersedes %s.',
		join(', ', map {
			$_->{html_url}
				? sprintf('#%d, closed without merging: %s',
					$_->{number}, $_->{html_url})
				: sprintf('#%d, closed without merging', $_->{number})
		} @bare))
		if @bare;

	return join("\n\n", @parts);
}

# }}}
# freeze - the approved arm, which writes nothing at all {{{
#
# D51 freezes an approved pull request, so the branch is left exactly as the
# reviewer read it and every new due commit is held with the reason
# awaiting-merge.  A long-stale approval is the operator's to merge or to
# dismiss, and the run never dismisses one on their behalf.
#
# It answers undef rather than a word, because the outcome is the bare enum
# word held and the qualifier beside it is held_qualifier's to compose, so the
# run, the preview, and pipeline-status all read one phrase from one place.
sub freeze {
	my ($record, $commits) = @_;

	my $pr = $record->{pr};
	$pr->{action} = 'freeze';

	push @{$record->{held}}, {
		control_commit => $_->{control_commit},
		subject        => $_->{subject},
		reason         => 'awaiting-merge',
		number         => $pr->{number},
	} for @$commits;
	$record->{pending} = [];

	return undef;
}

# }}}
# expected_tip - the value on R the publish will push against {{{
#
# D51 reads it at the run's refresh and nowhere else, because reading it again
# at the push would close no window at all.  What the arm does next is fetch
# the branch and rewrite it, so a read taken after that would name the value
# this run is about to overwrite and would lease the branch against whatever a
# teammate had just put there.
#
# An absent branch has no expected tip, which is how the publish tells a first
# push from a rewrite, and _push_one turns that undef into the empty object
# name.  The remote is asked for by name rather than spelled origin, because
# align_with_remote a few lines above reads the same ref through the same
# accessor and the two must not disagree about which remote R is.
sub expected_tip {
	my ($git, $pr_branch) = @_;
	my $remote = $git->default_remote or return undef;
	return undef unless $git->branch_exists("$remote/$pr_branch");
	return $git->rev_parse("$remote/$pr_branch");
}

# }}}
# deliver - the pull request arm for one environment {{{
#
# The branch carries exactly one commit above the deployment branch, so the
# arm resets it to the deployment branch's tip and calls the single writer
# once, at the newest due commit's source.  D69 makes a delivery a mirror, so
# the mirror of the newest commit is the whole aggregate's tree, and D82's two
# index assertions run against that same commit.
#
# It answers the environment's outcome word, or undef where the report is to
# settle the environment itself, which is what a freeze answers.
sub deliver {
	my ($session, $record, %opts) = @_;

	my $env     = $opts{env};
	my $git     = $session->git;
	my $commits = $opts{commits} || [];
	my $state   = $opts{state};
	my $pr      = $record->{pr}
		or bug("Genesis::CI::PullRequest::deliver was handed %s, which the ".
		       "walk composed no pull request branch for", $record->{env});

	# What the reader answered about the pull request, carried onto the
	# record before any arm is taken, so the publish, the sync, and the
	# report all read one answer rather than asking the API again.
	$pr->{state}      = $state ? $state->{state}      : undef;
	$pr->{number}     = $state ? $state->{number}     : undef;
	$pr->{url}        = $state ? $state->{url}        : undef;
	$pr->{superseded} = $state ? $state->{superseded} : [];

	# Recorded above everything the arm writes, so the value the publish is
	# handed is the one the rest of the arm reasoned from, and not the one the
	# arm's own rewrite leaves behind.
	$pr->{expected} = expected_tip($git, $pr->{branch});

	return 'idempotent' unless @$commits;

	# The approved arm, which answers undef, so the report settles the
	# environment as held with the qualifier held_qualifier composes.
	#
	# The state is read off the record rather than off the answer itself, for
	# the reason the supersedes guard below carries: the answer is undef for a
	# run given no token at all, and the record already holds the one copy
	# every reader here takes.
	return freeze($record, $commits)
		if ($pr->{state} // '') eq 'approved';

	# The switch cuts the branch where neither side holds it, because it is
	# derived state and the deployment branch is what it is derived from, and
	# the session records the absence so the reset can take it off again.
	$session->switch($pr->{branch}, create_from => $record->{branch});
	align_with_remote($git, $pr->{branch});
	$git->reset_hard($record->{branch});

	# The newest due commit's own control sha, under the name the walk gives
	# it on each pending entry, which is control_commit and not sha.
	my $newest  = $commits->[-1];
	my $source  = $newest->{control_commit};
	my %body;

	# A gate ends the delivery, so the walk has already trimmed the list to it.
	# What the paragraph is decided by is the environment's gate state as the
	# walk left it on the record, and not whether the newest commit delivered
	# is itself the gate.  gate_state reads the trailer over every control
	# commit in range whatever it touched, so a gate that changes nothing in
	# this environment's propagation set holds every commit after it while
	# never becoming a pending entry at all, which is the ordinary shape once
	# several environments share one control branch.  The aggregate then ends
	# before the gate rather than at it, and the body still owes a reviewer the
	# reason it stops there.
	#
	# The count is of what this gate holds for this environment and not of
	# everything held, for the reason Genesis::CI::Report::hold_detail gives
	# about its own count: a commit stopped for another reason is reported
	# under that reason, and counting it here would name it twice.
	#
	# The delivered commits are asked only where the gate holds nothing, which
	# is a gate standing on control's own tip.  There is no held entry to read
	# it off then, and the gate's own pending entry carries the marks.
	#
	# The first gate-ahead entry is the only gate there is to read.  The walk
	# takes the oldest unreleased gate in the range and stops at it
	# (Genesis::CI::Walk.pm ~1212-1222), because a second gate behind the
	# first is reached only once the first is cleared, so one walk of one
	# environment marks its entries with one gate and never two.
	my @gated = grep {($_->{reason} // '') eq 'gate-ahead'}
		@{$record->{held} || []};
	my ($gate) = @gated;
	($gate) = grep {$_->{gate}} @$commits unless $gate;
	$body{gate} = gate_line($gate, {
		count => scalar @gated,
		env   => $record->{env},
	}) if $gate;

	# When every pull request for this environment was closed without merging,
	# the next one supersedes them, and D51 has the old branch rebuilt in
	# place rather than left standing, because it is derived state.
	#
	# The state is read off the record rather than off the answer itself,
	# because the answer is undef for a run given no token at all and the
	# record already carries the one copy every reader here takes.
	$body{supersedes} = supersedes_paragraph($state->{rejected})
		if ($pr->{state} // '') eq 'closed unmerged';

	# D56: a rebuild that answers a reviewer says so, in the same shape a
	# superseding body quotes a rejection, so a reviewer opening the pull
	# request again reads their own words above the aggregate that answers
	# them.  One renderer writes both, and the opening sentence is the only
	# thing this call site gives it.
	#
	# The state is read off the record for the reason the two guards above
	# carry: the answer is undef for a run given no token at all, and the
	# record already holds the one copy every reader here takes.
	$body{review} = review_paragraph($state->{number}, $state->{review},
		opening => 'Changes were requested')
		if ($pr->{state} // '') eq 'changes requested';

	my $message = aggregate_message($git, $env, $commits, %body);
	my $written = $session->apply_files($source,
		env     => $env,
		message => $message,
		changed => [map {@{$_->{files} || []}} @$commits],
	);

	$pr->{action}         = 'rebuild';
	$pr->{control_commit} = $source;
	$pr->{title}          = (split /\n/, $message)[0];
	$pr->{body}           = ($message =~ s/^[^\n]*\n\n?//r) =~ s/\s+$//r;
	$pr->{commit}         = $written->{commit};
	$record->{overwrote}  = $written->{overwrote};

	return 'propagated';
}

# }}}
# pr_state - the pull request and what a reviewer decided about it {{{
#
# Answers the state as one of none, unreviewed, approved, changes requested,
# and closed unmerged, which are the four arms of D51 plus the case where
# there is no pull request at all.  merged carries the merged pull requests,
# which D52's recovery reads, rejected carries the closed-unmerged ones
# themselves so the body can quote one, and superseded carries their numbers
# for the title.  An API that cannot answer is not a fifth state but a
# refusal, under D55.
#
# The record it is handed needs three fields and no more, which are the
# environment's name, its deployment branch, and its pull request branch, so
# the run can read every environment's state before the walk has composed a
# record of its own.
sub pr_state {
	my ($github, $owner_repo, $record, %opts) = @_;

	my ($open, $closed);
	eval {
		$open   = $github->open_prs($owner_repo,
			$record->{branch}, $record->{pr}{branch});
		$closed = $github->closed_prs($owner_repo,
			$record->{branch}, $record->{pr}{branch});
		1;
	} or refuse_unreadable($record->{env}, $@, %opts);

	# The one the listing puts first, which GitHub orders newest first, so the
	# run acts on the most recent attempt.  The order is the API's rather than
	# anything asserted here, and the warning names the rest so an operator
	# who meant a different one can close the others.
	if (@$open > 1) {
		warning(
			"Several pull requests are open for #C{%s} from #C{%s}, which are ".
			"%s. Acting on #%d by its review state and leaving the rest alone.",
			$record->{env}, $record->{pr}{branch},
			join(', ', map {'#'.$_->{number}} @$open), $open->[0]{number}
		);
	}

	my @merged   = grep { $_->{merged_at} } @$closed;
	my @rejected = grep { !$_->{merged_at} } @$closed;

	my $pr = @$open ? $open->[0] : undef;
	my $state = !$pr          ? (@rejected ? 'closed unmerged' : 'none')
	          : $pr->{review} ? $pr->{review}{state}
	          :                 'unreviewed';

	return {
		state      => $state,
		number     => $pr ? $pr->{number}   : undef,
		url        => $pr ? $pr->{html_url} : undef,
		title      => $pr ? $pr->{title}    : undef,
		body       => $pr ? $pr->{body}     : undef,
		review     => $pr ? $pr->{review}   : undef,
		rejected   => \@rejected,
		superseded => [map {$_->{number}} @rejected],
		merged     => \@merged,
	};
}

# }}}
# refuse_unreadable - the one refusal D55 specifies, naming the input {{{
#
# The refusal is whole-run, because a run that cannot read what a reviewer
# decided cannot know what it would do with any pull request branch, and D98
# gives it UNAVAILABLE (69) since the API is the service it could not reach.
# Genesis::Exit declares codes and no subs, so it is raised through bail with
# a named code, the way every other refusal in the tree is.
#
# A caller inside an open session hands its own refusal closure in, so the
# operator is put back on the branch they started from before they are told
# why the run stopped.  A caller with no session leaves it out and the bail
# below speaks for itself.
#
# Every failure of the two readers arrives here and none is passed through.
# They raise their own already-worded message and the status behind it can
# only be read back out of that text, so the refusal quotes what the reader
# said rather than sorting a rejected token from an unreachable API and
# claiming a retry is the answer.  A retry helps some of these and not
# others, and the quoted line is what says which.
#
# The quote is stripped of the reader's own wrapping first, through bail_text,
# which is what every caller quoting a bail it caught inside an eval goes
# through.  Interpolating one whole would give the operator a banner in the
# middle of a paragraph and two wrap widths in one message.
sub refuse_unreadable {
	my ($env, $why, %opts) = @_;

	my $said = bail_text($why);

	($opts{refuse} || \&bail)->(
		{exitcode => Genesis::Exit::UNAVAILABLE},
		"Could not read the review state of #C{%s}'s pull request from ".
		"GitHub, so this run refuses rather than guess what to do with its ".
		"pull request branch.\n\n%s",
		$env, (length $said ? $said : 'The API did not answer.')
	);
}

# }}}
# title_for - the aggregate's subject, with the supersedes list where there is one {{{
#
# D49 puts the marker in the title as well as in the subject, so a squash merge
# keeps it, and the supersedes-title rule of D12 names every closed-unmerged
# attempt by number, because a number survives a closed pull request and a
# deleted branch where a branch name does not.
#
# The title is composed on every sync rather than only on the open, which is
# what displaces FWT-1099's criterion that an open pull request keeps the title
# it was opened with.  A title left alone names whatever control commit the
# first proposal carried, and a rebuilt branch proposing a newer one would then
# be described by a marker that is no longer true of it.
sub title_for {
	my ($subject, $superseded) = @_;
	return $subject unless $superseded && @$superseded;
	return sprintf('%s (supersedes %s)',
		$subject, join(', ', map {"#$_"} @$superseded));
}

# }}}
# sync_pull_request - open or update the pull request, after its branch is up {{{
#
# It runs after the publish and not inside the arm, because GitHub opens a
# pull request from a branch the remote holds and D83 makes the pull request
# branch's push the branch's own at the end of the run.  One call site, so the
# title and the body are composed once and the proposed record is written from
# what the API actually answered.
sub sync_pull_request {
	my ($github, $owner_repo, $record, %opts) = @_;

	my $pr = $record->{pr} or return undef;
	return undef unless ($pr->{action} // '') eq 'rebuild';

	# The composed title goes into a local rather than back onto the record,
	# because the record's own title is what the aggregate's subject said and a
	# second call that read it back would append the supersedes list to a title
	# that already carried it.
	my $title = title_for($pr->{title}, $pr->{superseded});

	my $answer = $pr->{number}
		? $github->update_pr($owner_repo, $pr->{number},
			title => $title, body => $pr->{body})
		: $github->create_pr($owner_repo,
			head  => $pr->{branch},
			base  => $record->{branch},
			title => $title,
			body  => $pr->{body},
		);

	$pr->{number} = $answer->{number};
	$pr->{url}    = $answer->{html_url};

	$opts{env}->set_proposed(
		control_commit => $pr->{control_commit},
		number         => $pr->{number},
		url            => $pr->{url},
	);
	return $pr;
}

# }}}

1;
# vim: fdm=marker:foldlevel=0:noet
