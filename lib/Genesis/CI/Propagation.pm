package Genesis::CI::Propagation;

use strict;
use warnings;

use Genesis qw(info warning);
use Genesis::CI::Marker;

# _propagate_one_pr_env - rolling-branch decision tree for require_pr=1 {{{
sub _propagate_one_pr_env {
	my (%a) = @_;
	my $git           = $a{git};
	my $session       = $a{session};
	my $github        = $a{github};
	my $owner_repo    = $a{owner_repo};
	my $top           = $a{top}
		or die "_propagate_one_pr_env: 'top' is required\n";
	my $env_name      = $a{env_name};
	# The deployment branch the pull request is cut from and opened
	# against, which is the slug and not the environment's own name.
	my $branch        = $a{branch} // $env_name;
	my $control_sha   = $a{control_sha};
	my $control_short = $a{control_short};
	my $detail        = $a{detail};

	my $pr_branch = $top->pr_branch_for($env_name);

	# Query open PRs from the API — authoritative on PR state.
	# Branch presence (local or remote) is a separate concern.
	my @open;
	if ($github) {
		my $prs = $github->open_prs($owner_repo, $branch, $pr_branch);
		@open = @$prs;
	}

	if (@open > 1) {
		warning(
			"Multiple open PRs for #C{%s} with head #C{%s}; using PR #%d.",
			$env_name, $pr_branch, $open[0]{number}
		);
	}
	my $existing_pr = @open ? $open[0] : undef;

	if ($existing_pr) {
		# count == 1 (or >1, treated as 1): append to existing branch.
		#
		# The refresh runs only where this clone lacks the branch, so the
		# switch below has nothing to switch to when it fails.  The result
		# is read rather than discarded, and the failure stops this
		# environment the way every other failed delivery does, which is a
		# die the caller turns into a warning and an error entry.
		unless ($git->branch_exists($pr_branch)) {
			my (undef, $fetched) = $git->fetch_branches([$pr_branch]);
			die sprintf("Failed to fetch '%s' from the remote: %s\n",
				$pr_branch,
				($fetched->{err} || $fetched->{kind} || 'the fetch failed')
					=~ s/\s+$//r)
				unless $fetched->{ok};
		}
		$session->switch($pr_branch);

		# Idempotency: skip whole env if HEAD already matches this control_sha
		if (_pr_branch_has_control_sha($git, $pr_branch, $control_short)) {
			info "  #Yi{%s}: PR #%d already includes control\@%s, skipping",
				$env_name, $existing_pr->{number}, $control_short;
			return { idempotent_skip => 1 };
		}

		_apply_propagation_commit($git, $env_name, $control_sha, $control_short, $detail);
		info "  #G{%s}: appended to existing PR #%d on #C{%s}",
			$env_name, $existing_pr->{number}, $pr_branch;
	} else {
		# count == 0: clean any stale remote, create fresh branch
		if ($git->remote_branch_exists($pr_branch)) {
			info "  #Yi{%s}: cleaning stale remote branch #C{%s}",
				$env_name, $pr_branch;
			$git->delete_remote_branch($pr_branch);
		}
		$session->switch($branch);
		$git->create_branch($pr_branch);
		$session->switch($pr_branch);
		_apply_propagation_commit($git, $env_name, $control_sha, $control_short, $detail);
		info "  #G{%s}: created #C{%s}", $env_name, $pr_branch;
	}

	_render_detail_lines($git, $detail);

	return {
		branch      => $pr_branch,
		existing_pr => $existing_pr,
	};
}
# }}}
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
# _render_detail_lines - per-file M/D info() lines (display only) {{{
sub _render_detail_lines {
	my ($git, $detail) = @_;
	my @to_copy = @{$detail->{changed} || []};
	my @to_rm   = @{$detail->{deleted} || []};
	my %renames = %{$detail->{renamed} || {}};

	for my $f (@to_copy) {
		my ($old)      = grep { $renames{$_} eq $f } keys %renames;
		my ($disp_f)   = $git->unprefixed($f);
		my ($disp_old) = $old ? $git->unprefixed($old) : ();
		my $note = $old ? " #Yi{(renamed from $disp_old)}" : '';
		info "    #G{M} %s%s", $disp_f, $note;
	}
	info "    #R{D} %s", $_ for $git->unprefixed(@to_rm);
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
