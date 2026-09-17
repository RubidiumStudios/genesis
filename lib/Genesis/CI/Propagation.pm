package Genesis::CI::Propagation;

use strict;
use warnings;

use Genesis::CI::Marker;

# _apply_propagation_commit - apply files + commit (current branch is target) {{{
sub _apply_propagation_commit {
	my ($git, $env_name, $control_sha, $control_short, $detail) = @_;
	my @to_copy = @{$detail->{changed} || []};
	my @to_rm   = @{$detail->{deleted} || []};
	$git->checkout_file($control_sha, $_) for @to_copy;
	$git->rm(@to_rm) if @to_rm;
	my $msg = Genesis::CI::Marker::build($control_short, $env_name);
	$git->commit($msg, @to_copy);
}
# }}}
# _pr_branch_has_control_sha - idempotency check for pr/<env>/<type> {{{
#
# Asks the one reader for the branch's newest marker and compares the commit
# it names with the one being propagated.  The old form matched the tip's
# subject, so a squash, an amend, or an edited subject re-propagated and a
# coincidental short sha suppressed a real propagation, which is H7.  M16
# replaces the check outright with the marker walk on both branches.
#
# The two sides are compared as full shas, because a marker spells its commit
# at whatever width the delivery abbreviated it to and only a full sha makes
# two spellings of one commit compare equal.  The reader expands the marker
# already where this clone holds the commit, so the expansion below is for
# the side it could not reach, and a side that will not come back as forty
# hex digits is a commit this clone cannot name.  The check then says the
# branch is not idempotent rather than guessing, and the caller propagates
# again, which is the safe way to be wrong.
sub _pr_branch_has_control_sha {
	my ($git, $branch, $control_short) = @_;
	return 0 unless $git->branch_exists($branch);

	my $marker = Genesis::CI::Marker::newest($git, $branch);
	return 0 unless defined $marker;
	# The expansion below fires only where the clone does not hold the
	# commit the marker names, since the reader has expanded it already
	# everywhere else, and the step that retires the propagate-envs double
	# may well drop it.
	$marker = $git->sha($marker) unless $marker =~ /^[0-9a-f]{40}$/;
	return 0 unless defined $marker && $marker =~ /^[0-9a-f]{40}$/;

	my $control = $git->sha($control_short);
	return 0 unless defined $control && $control =~ /^[0-9a-f]{40}$/;

	return $marker eq $control ? 1 : 0;
}
# }}}
# _build_pr_body - generic PR body for rolling pr/<env>/<type> branches {{{
#
# Rolling branches accumulate commits across propagation events; per-
# propagation file detail lives in the commit history.  The body is a
# stable signpost, not a per-event diff.
sub _build_pr_body {
	my ($env_name, $control) = @_;
	$control //= 'control';
	return join("\n",
		"Aggregates pending propagations from `$control` to `$env_name`.",
		"",
		"See commit history for per-propagation details — each commit",
		"subject carries the source control SHA and the affected files",
		"are visible in the commit diff.",
	);
}
# }}}
# _find_or_open_pr - dispatch to create_pr or update_pr based on $existing {{{
sub _find_or_open_pr {
	my ($github, $owner_repo, $pr_branch, $base_branch, $title, $body, $existing) = @_;

	return $existing
		? $github->update_pr($owner_repo, $existing->{number},
			title => $title,
			body  => $body,
		)
		: $github->create_pr($owner_repo,
			head  => $pr_branch,
			base  => $base_branch,
			title => $title,
			body  => $body,
		);
}
# }}}

1;
