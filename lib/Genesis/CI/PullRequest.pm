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
	my $pr      = $record->{pr}
		or bug("Genesis::CI::PullRequest::deliver was handed %s, which the ".
		       "walk composed no pull request branch for", $record->{env});

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
