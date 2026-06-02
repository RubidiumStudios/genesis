package Genesis::CI::Propagation;

use strict;
use warnings;

use Genesis qw(info warning);

# compute_propagation_targets - determine which envs receive files directly {{{
#
# Pure function: no git, no IO.  Given a DAG topology, per-env
# propagation diffs, and (optionally) per-env deploy diffs, returns
# which environments are direct entry points for propagation and
# which files each receives.
#
# Two diffs per env:
#   - propagation_diff: files on control HEAD that aren't yet on this
#     env's branch.  Used to decide what to copy when the env is an
#     entry point.
#   - deploy_diff: files on control HEAD that haven't yet been
#     DEPLOYED from this env (branch may have them, but exodus
#     audit shows an older commit).  Used to detect ancestors that
#     have in-flight propagations — descendants must wait.
#
# An environment is a direct entry point when:
#   1. Its propagation_diff is non-empty, AND
#   2. NONE of its propagation_diff files overlap with any ancestor's
#      deploy_diff (i.e., no ancestor is sitting on an undeployed copy
#      of the same file).
#
# This keeps commits travelling as a unit: a file can't cascade past
# an ancestor that has received it on-branch but not yet deployed it.
#
# When deploy_diff is omitted, it falls back to propagation_diff —
# preserving the original single-diff behaviour for callers that
# aren't yet deployment-aware.
#
# Args (named):
#   dag_order         => \@ordered_env_names   (topologically sorted)
#   parent_of         => \%parent_map          (env => parent_env or undef)
#   env_changed       => \%propagation_diff    (env => \@files to copy)
#   env_undeployed    => \%deploy_diff         (env => \@files pending deploy)
#                                               (optional; defaults to env_changed)
#   scope             => \@scoped_env_names    (optional: subset to consider)
#
# Returns: hashref  { env_name => \@files_to_propagate }
#          Only entry point envs appear in the result.
sub compute_propagation_targets {
	my (%args) = @_;

	my @dag_order      = @{$args{dag_order}      || []};
	my %parent_of      = %{$args{parent_of}      || {}};
	my %env_changed    = %{$args{env_changed}    || {}};
	my %env_undeployed = %{$args{env_undeployed} || \%env_changed};
	my @scope          = @{$args{scope}          || \@dag_order};

	my %in_scope = map { $_ => 1 } @scope;

	my %targets;

	for my $env_name (@scope) {
		next unless $env_changed{$env_name};
		next unless @{$env_changed{$env_name}};

		my %my_files = map { $_ => 1 } @{$env_changed{$env_name}};

		# Walk up the DAG checking for overlap with any ancestor's
		# undeployed set (what the ancestor is still sitting on).
		my $has_ancestor_overlap = 0;
		my $ancestor = $parent_of{$env_name};
		while ($ancestor) {
			if ($env_undeployed{$ancestor} && @{$env_undeployed{$ancestor}}) {
				for my $f (@{$env_undeployed{$ancestor}}) {
					if ($my_files{$f}) {
						$has_ancestor_overlap = 1;
						last;
					}
				}
			}
			last if $has_ancestor_overlap;
			$ancestor = $parent_of{$ancestor};
		}

		unless ($has_ancestor_overlap) {
			$targets{$env_name} = $env_changed{$env_name};
		}
	}

	return \%targets;
}

# }}}
# propagate_envs - execute propagation to a set of computed targets {{{
#
# Iterates targets, applying each propagation either directly to the
# env branch or via a rolling pr/<env> branch + GitHub PR.  Batches
# all branch pushes and PR API calls at the end.
#
# Provider-agnostic: callers parameterise behavior via the option
# flags below.  Manual provider sets push_direct_commits=1; Concourse
# (when wired) sets it to 0 because concourse's `put` step on the env
# git resource lands the commit upstream.
#
# Args (named):
#   git           => Service::Git instance
#   github        => Service::Github instance (or undef when no targets need PRs)
#   owner_repo    => "owner/name" (required when any target has require_pr)
#   targets       => arrayref of target hashes, each:
#                    {
#                      env        => 'staging',
#                      require_pr => 0|1,
#                      detail     => {
#                        changed => [...],   # files to copy from control_sha
#                        deleted => [...],   # files to remove
#                        renamed => {...},   # old_path => new_path
#                      },
#                    }
#   control       => control branch name
#   control_sha   => full SHA of control HEAD
#   control_short => short SHA
#
#   push_direct_commits => bool (default 1) — push direct-to-<env> commits
#   push_pr_branches    => bool (default 1) — push pr/<env> branches
#   create_prs          => bool (default 1) — call create_pr / update_pr
#   no_push             => bool (default 0) — MASTER KILL: forces all push_*
#                                              and create_prs to 0
#   dry_run             => bool (default 0) — report intent, no mutations
#   push_extra_branches => arrayref (default []) — extra branches to include
#                          in the batched push (e.g., control)
#
# Returns: hashref
#   {
#     propagated         => N,        # total envs successfully propagated
#                                     # (includes skipped-idempotent)
#     skipped_idempotent => [envs],   # envs whose pr/<env> HEAD already
#                                     # matched this control_sha
#     errors             => [strings] # any per-env failures (loop bails on first)
#   }
sub propagate_envs {
	my (%args) = @_;

	my $git           = $args{git}     or die "propagate_envs: 'git' is required\n";
	my $github        = $args{github};
	my $owner_repo    = $args{owner_repo};
	my @targets       = @{$args{targets} || []};
	my $control       = $args{control};
	my $control_sha   = $args{control_sha};
	my $control_short = $args{control_short};

	my $dry_run             = $args{dry_run}             // 0;
	my $no_push             = $args{no_push}             // 0;
	my $push_direct_commits = $args{push_direct_commits} // 1;
	my $push_pr_branches    = $args{push_pr_branches}    // 1;
	my $create_prs          = $args{create_prs}          // 1;
	my @extra_push          = @{$args{push_extra_branches} || []};

	# no_push is the master kill switch — forces all writes off
	if ($no_push) {
		$push_direct_commits = 0;
		$push_pr_branches    = 0;
		$create_prs          = 0;
	}

	my $propagated = 0;
	my @skipped_idempotent;
	my @pushed_branches;
	my @pr_targets;
	my @errors;

	for my $t (@targets) {
		my $env_name   = $t->{env};
		my $require_pr = $t->{require_pr} ? 1 : 0;
		my $detail     = $t->{detail}
			|| { changed => [], deleted => [], renamed => {} };

		if ($dry_run) {
			_report_dry_run($git, $env_name, $require_pr, $detail,
				$control_short);
			$propagated++;
			next;
		}

		my $outcome;
		if ($require_pr) {
			$outcome = eval {
				_propagate_one_pr_env(
					git           => $git,
					github        => $github,
					owner_repo    => $owner_repo,
					env_name      => $env_name,
					control_sha   => $control_sha,
					control_short => $control_short,
					detail        => $detail,
				);
			};
		} else {
			$outcome = eval {
				_propagate_one_direct_env(
					git           => $git,
					env_name      => $env_name,
					control_sha   => $control_sha,
					detail        => $detail,
					control_short => $control_short,
				);
			};
		}
		if (my $err = $@) {
			$git->reset_working_tree;
			warning("Propagation to #C{%s} failed: %s",
				$env_name, $err =~ s/\s+$//r);
			push @errors, "$env_name: $err";
			last;
		}

		if ($outcome->{idempotent_skip}) {
			push @skipped_idempotent, $env_name;
			$propagated++;
			next;
		}

		$propagated++;
		if ($outcome->{branch}) {
			my $should_push = $require_pr ? $push_pr_branches : $push_direct_commits;
			push @pushed_branches, $outcome->{branch} if $should_push;
		}
		if ($require_pr && !$outcome->{idempotent_skip}) {
			push @pr_targets, {
				env      => $env_name,
				branch   => $outcome->{branch},
				detail   => $detail,
				existing => $outcome->{existing_pr},
			};
		}
	}

	$git->restore_branch unless $dry_run;

	# Skip push and PR creation if any target failed — partial state on
	# remote is worse than no state.  Caller can decide to bail or
	# report based on errors.
	if (@errors) {
		return {
			propagated         => $propagated,
			skipped_idempotent => \@skipped_idempotent,
			errors             => \@errors,
		};
	}

	# Batched push: extras (e.g. control) + propagated branches
	if (!$dry_run && (@pushed_branches || @extra_push)) {
		my $remote = $git->default_remote;
		if ($remote) {
			my @all = (@extra_push, @pushed_branches);
			info "\n#G{Pushing} to #C{%s}...", $remote;
			my $results = $git->push($remote, @all);
			for my $branch (@all) {
				if ($results->{$branch}) {
					info "  #G{%s}: pushed", $branch;
				} else {
					warning("Failed to push #C{%s} to #C{%s}.",
						$branch, $remote);
				}
			}
		}
	}

	# PR API: create or update for each PR-mode target
	if (!$dry_run && $create_prs && @pr_targets && $github) {
		info "\n#G{Opening pull requests} on #C{%s}...", $owner_repo;
		for my $pt (@pr_targets) {
			my $title = sprintf("[pipeline] propagate to %s", $pt->{env});
			my $body  = _build_pr_body($pt->{env}, $control);
			eval {
				my $pr = _find_or_open_pr(
					$github, $owner_repo, $pt->{branch}, $pt->{env},
					$title, $body, $pt->{existing}
				);
				info "  #G{%s}: PR #%d %s",
					$pt->{env}, $pr->{number}, $pr->{html_url};
			};
			if ($@) {
				warning("Failed to open/update PR for #C{%s}: %s",
					$pt->{env}, $@ =~ s/\s+$//r);
			}
		}
	}

	return {
		propagated         => $propagated,
		skipped_idempotent => \@skipped_idempotent,
		errors             => \@errors,
	};
}
# }}}
# _propagate_one_direct_env - apply propagation commit directly to <env> {{{
sub _propagate_one_direct_env {
	my (%a) = @_;
	my $git         = $a{git};
	my $env_name    = $a{env_name};
	my $control_sha = $a{control_sha};
	my $detail      = $a{detail};
	my $short       = $a{control_short};

	my @to_copy = @{$detail->{changed} || []};
	my @to_rm   = @{$detail->{deleted} || []};
	my $total   = scalar(@to_copy) + scalar(@to_rm);

	$git->checkout($env_name);
	$git->checkout_file($control_sha, $_) for @to_copy;
	$git->rm(@to_rm) if @to_rm;
	my $msg = sprintf("[pipeline] control\@%s -> %s", $short, $env_name);
	$git->commit($msg, @to_copy);

	info "  #G{%s}: propagated %d file%s",
		$env_name, $total, $total == 1 ? '' : 's';
	_render_detail_lines($git, $detail);

	return { branch => $env_name };
}
# }}}
# _propagate_one_pr_env - rolling-branch decision tree for require_pr=1 {{{
sub _propagate_one_pr_env {
	my (%a) = @_;
	my $git           = $a{git};
	my $github        = $a{github};
	my $owner_repo    = $a{owner_repo};
	my $env_name      = $a{env_name};
	my $control_sha   = $a{control_sha};
	my $control_short = $a{control_short};
	my $detail        = $a{detail};

	my $pr_branch = "pr/$env_name";

	# Query open PRs from the API — authoritative on PR state.
	# Branch presence (local or remote) is a separate concern.
	my @open;
	if ($github) {
		my $prs = $github->open_prs($owner_repo, $env_name, $pr_branch);
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
		# count == 1 (or >1, treated as 1): append to existing branch
		$git->fetch_branch($pr_branch) unless $git->branch_exists($pr_branch);
		$git->checkout($pr_branch);

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
		$git->checkout($env_name);
		$git->create_branch($pr_branch);
		$git->checkout($pr_branch);
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
	my $msg = sprintf("[pipeline] control\@%s -> %s", $control_short, $env_name);
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
# _report_dry_run - print what would happen without doing it {{{
sub _report_dry_run {
	my ($git, $env_name, $require_pr, $detail, $control_short) = @_;
	my @to_copy = @{$detail->{changed} || []};
	my @to_rm   = @{$detail->{deleted} || []};
	my %renames = %{$detail->{renamed} || {}};
	my $total   = scalar(@to_copy) + scalar(@to_rm);

	info "  #C{%s}: %d file%s to propagate",
		$env_name, $total, $total == 1 ? '' : 's';
	for my $f (@to_copy) {
		my ($old)      = grep { $renames{$_} eq $f } keys %renames;
		my ($disp_f)   = $git->unprefixed($f);
		my ($disp_old) = $old ? $git->unprefixed($old) : ();
		my $note = $old ? " #Yi{(renamed from $disp_old)}" : '';
		info "    #G{M} %s%s", $disp_f, $note;
	}
	info "    #R{D} %s", $_ for $git->unprefixed(@to_rm);
	my $msg = sprintf("[pipeline] control\@%s -> %s", $control_short, $env_name);
	info "    #Yi{commit}: %s", $msg;
	info "    #Yi{PR}: would open pr/%s -> %s", $env_name, $env_name
		if $require_pr;
}
# }}}
# _pr_branch_has_control_sha - idempotency check for pr/<env> {{{
#
# Returns true iff the latest commit on $branch is a propagation
# commit for $control_short.  Word-boundary anchor prevents a
# shorter SHA from matching a longer subject sha (e.g., "abc123" must
# not match "[pipeline] control@abc1234 -> env").
sub _pr_branch_has_control_sha {
	my ($git, $branch, $control_short) = @_;
	return 0 unless $git->branch_exists($branch);
	my @subjects = $git->log_subjects($branch, limit => 1, format => '%s');
	return 0 unless @subjects;
	return $subjects[0] =~ /\[pipeline\]\s+control\@\Q$control_short\E\b/ ? 1 : 0;
}
# }}}
# _build_pr_body - generic PR body for rolling pr/<env> branches {{{
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
	my ($github, $owner_repo, $pr_branch, $env_name, $title, $body, $existing) = @_;

	return $existing
		? $github->update_pr($owner_repo, $existing->{number},
			title => $title,
			body  => $body,
		)
		: $github->create_pr($owner_repo,
			head  => $pr_branch,
			base  => $env_name,
			title => $title,
			body  => $body,
		);
}
# }}}

1;
