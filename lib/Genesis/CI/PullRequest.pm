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
sub align_with_remote {
	my ($git, $branch) = @_;
	my $remote = $git->default_remote or return 0;

	$git->fetch_branches([$branch], $remote)
		unless $git->branch_exists("$remote/$branch");
	return 0 unless $git->branch_exists("$remote/$branch");

	$git->reset_hard("$remote/$branch");
	return 1;
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
	my $message = Genesis::CI::Marker::build($source, $env->name);
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
sub refuse_unreadable {
	my ($env, $why, %opts) = @_;
	$why =~ s/\s+$// if defined $why;
	($opts{refuse} || \&bail)->(
		{exitcode => Genesis::Exit::UNAVAILABLE},
		"Could not read the review state of #C{%s}'s pull request from ".
		"GitHub, so this run refuses rather than guess what to do with its ".
		"pull request branch.\n%s\n\nRetry once the API answers again.",
		$env, $why // 'the API did not answer'
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
