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

use Genesis qw/bail bug info warning/;
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
		push @lines, $git->diff_stat($commit->{control_commit}.'^',
			$commit->{control_commit}, @paths);
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
	my $reason = $commit->{gate_reason};
	$reason =~ s/\s+$//;
	$reason =~ s/\.$//;
	return sprintf('Gate: %s.', $reason) unless $held->{count};
	return sprintf(
		"Gate: %s. Holding %d later commit%s for %s until this deploys.",
		$reason, $held->{count}, $held->{count} == 1 ? '' : 's', $held->{env}
	);
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

	return 'idempotent' unless @$commits;

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

	# A gate ends the delivery, so the walk has already trimmed the list to
	# the gate.  Where the newest commit it handed us is one, the body says so
	# and names how many of that environment's commits wait behind it.
	$body{gate} = gate_line($newest, {
		count => scalar @{$record->{held} || []},
		env   => $record->{env},
	}) if $newest->{gate};

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
# The quote is stripped of the reader's own wrapping first.  Inside an eval
# bail dies with its message already wrapped to the terminal and already
# prefixed [FATAL] on every line, so interpolating it whole would give the
# operator a banner in the middle of a paragraph and two wrap widths in one
# message.  The prefix and the colour go, and so does the hard wrap inside
# each paragraph, which leaves the outer refusal one paragraph per paragraph
# to wrap once.  The blank lines stay, because they are the reader's own
# structure rather than the wrap's.
sub refuse_unreadable {
	my ($env, $why, %opts) = @_;

	my @said;
	if (defined $why) {
		$why =~ s/\e\[[0-9;]*m//g;
		for my $paragraph (split /\n[ \t]*\n/, $why) {
			my @lines = grep {/\S/}
				map {s/^\s*(?:\[FATAL\]\s*)?//r =~ s/\s+$//r}
				split /\n/, $paragraph;
			push @said, join(' ', @lines) if @lines;
		}
	}

	($opts{refuse} || \&bail)->(
		{exitcode => Genesis::Exit::UNAVAILABLE},
		"Could not read the review state of #C{%s}'s pull request from ".
		"GitHub, so this run refuses rather than guess what to do with its ".
		"pull request branch.\n\n%s",
		$env, (@said ? join("\n\n", @said) : 'The API did not answer.')
	);
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

	my $answer = $pr->{number}
		? $github->update_pr($owner_repo, $pr->{number},
			title => $pr->{title}, body => $pr->{body})
		: $github->create_pr($owner_repo,
			head  => $pr->{branch},
			base  => $record->{branch},
			title => $pr->{title},
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
