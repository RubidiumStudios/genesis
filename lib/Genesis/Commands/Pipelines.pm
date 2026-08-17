package Genesis::Commands::Pipelines;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Commands;
use Genesis::Top;
use Genesis::Env;
use Genesis::CI::Legacy qw//;
use Genesis::CI::Compiler;
use Genesis::CI::Propagation;
use Service::Git;
use Service::Github;
use Service::Vault::Remote;

use File::Basename qw/dirname/;
use File::Path qw/rmtree/;
use JSON::PP;

### Public Commands {{{

# embed - embed Genesis binary in the repository {{{
sub embed {
	command_usage(1) if @_;
	Genesis::Top->new('.')->embed($ENV{GENESIS_CALLBACK_BIN} || $0);
}

# }}}
# apply - compile and deploy pipeline (replaces genesis repipe) {{{
sub apply {
	my ($layout) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';

	bail("--output-dir requires --platform")
		if $opts->{'output-dir'} && !$opts->{platform};
	bail("--debug-dir requires --platform")
		if $opts->{'debug-dir'} && !$opts->{platform};

	my $top = _get_top($opts);

	# Short-circuit on the 'manual' provider: it has no pipeline to apply
	# — Genesis is the CLI you run at your terminal, there is no CI to
	# generate or deploy.
	if (($top->config->get('ci.provider.type') // '') eq 'manual') {
		bail(
			"Manual provider has no pipeline to apply.\n\n".
			"#i{Genesis is your CLI - deploys happen at your terminal, ".
			"not in a hosted pipeline.}\n\n".
			"To use a real CI provider, change #C{ci.provider.type} in ".
			"#C{.genesis/config} to one of: #C{concourse}, #C{github-actions}, ".
			"then re-run #C{genesis pipeline-apply}."
		);
	}

	my $result = _compile_pipeline($top, $platform);

	_dump_debug_artifacts($opts->{'debug-dir'}, $result, $platform)
		if $opts->{'debug-dir'};

	my $ast    = $result->{ast};
	my $output = $result->{output};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");

	if (my $out_dir = $opts->{'output-dir'}) {
		mkdir_or_fail($out_dir);
		for my $file (sort keys %$output) {
			mkfile_or_fail("$out_dir/$file", $output->{$file});
			info("Wrote #C{%s/%s}", $out_dir, $file);
		}
		mkfile_or_fail("$out_dir/ast.json",
			JSON::PP->new->pretty->canonical->encode({%$ast}));
		info("Wrote #C{%s/ast.json}", $out_dir);
		exit 0;
	}

	if ($platform eq 'concourse') {
		my $provider = $result->{provider};

		if ($opts->{'dry-run'}) {
			my $yaml = $output->{'pipeline.yml'}
				or bail("Concourse provider did not produce pipeline.yml");
			output({raw => 1}, $yaml);
			exit 0;
		}

		$provider->check_prereqs() or exit 86;

		my %deploy_opts = %{ $provider->normalize_provider_opts(
			$result->{provider_cli_opts} || {}
		) };
		$deploy_opts{target}          //= $opts->{target} // $layout // $name;
		$deploy_opts{pause_after_set} //= $opts->{paused};
		$provider->deploy(%deploy_opts, yes => $opts->{yes});

	} elsif ($platform eq 'github-actions') {
		if ($opts->{'dry-run'}) {
			for my $file (sort keys %$output) {
				output "#G{--- %s ---}", $file;
				output({raw => 1}, $output->{$file});
			}
			exit 0;
		}
		for my $file (sort keys %$output) {
			my $path = ".github/workflows/$file";
			mkdir_or_fail(dirname($path));
			mkfile_or_fail($path, $output->{$file});
			info("Wrote #C{%s}", $path);
		}
		info("GitHub Actions workflows written. Commit and push to activate.");

	} else {
		bail("Unsupported platform '%s' for pipeline apply", $platform);
	}

	exit 0;
}

# }}}
# pipeline_status - show propagation state across all environments {{{
sub pipeline_status {

	my $top = Genesis::Top->new('.');
	bail("CI is not configured for this repository.")
		unless $top->ci_configured;

	my $git     = Service::Git->new('.');
	my $control = Genesis::Top::DEFAULT_CONTROL_BRANCH();

	# Build the DAG
	require Genesis::CI::Compiler::ASTBuilder;
	my $builder = Genesis::CI::Compiler::ASTBuilder->new(
		top     => $top,
		env_dir => $top->path,
	);
	my ($nodes, $edges) = $builder->_build_from_env_files($top->path);

	bail("No environments with pipeline metadata found.")
		unless %$nodes;

	my (%children, %has_parent, %parent_of);
	for my $edge (@$edges) {
		push @{ $children{$edge->{from}} }, $edge->{to};
		$has_parent{$edge->{to}} = 1;
		$parent_of{$edge->{to}} = $edge->{from};
	}

	# Topological order
	my @dag_order;
	my @queue = sort grep { !$has_parent{$_} } keys %$nodes;
	my %visited;
	while (@queue) {
		my $env = shift @queue;
		next if $visited{$env}++;
		push @dag_order, $env;
		push @queue, sort @{$children{$env} || []};
	}

	# Refresh env branch refs from remote before reading status so the
	# display reflects teammate commits, not just local state.
	$top->fetch_pipeline_envs($git)
		unless get_options->{'no-fetch'};

	my $head       = $git->sha($control);
	my $head_short = $git->sha($head, short => 1);

	# Gather state for each env
	my %env_state;   # env => { branch_sha, deployed_sha, changed, ... }
	my %env_changed; # for propagation target computation
	for my $env_name (@dag_order) {
		my %state = ( name => $env_name );

		unless ($git->branch_exists($env_name)) {
			$state{status} = 'no-branch';
			$env_state{$env_name} = \%state;
			next;
		}

		# Branch column: the CONTROL sha that was most recently propagated
		# to this env (read from the `[pipeline] control@<sha>` marker on
		# the env branch) — not the env-branch's own HEAD sha.
		my ($branch_ctl) = _resolve_propagation_base($env_name, $git);
		$state{branch_sha} = $branch_ctl
			? $git->sha($branch_ctl, short => 1)
			: undef;

		my $env = eval { $top->load_env($env_name) };
		unless ($env) {
			$state{status} = 'error';
			$state{error}  = _summarize_load_error($@);
			$env_state{$env_name} = \%state;
			next;
		}

		# Deploy column: the CONTROL sha certified by the last successful
		# deployment (exodus git.control_commit).  Also used below to
		# determine deployed-vs-pending status.
		my $dep_ctl = '';
		my $env_v = eval { $env->with_vault };
		if ($env_v) {
			my $dep = eval { $env_v->deployments->latest_successful };
			$dep_ctl = $dep ? ($dep->lookup('git.control_commit') || '') : '';
		}
		$state{deployed_sha} = $dep_ctl
			? $git->sha($dep_ctl, short => 1)
			: undef;

		my @dep_files = $env->propagation_files;
		my $diff = $git->diff_files($env_name, $head, @dep_files);

		if (@{$diff->{all}}) {
			$state{changed} = $diff->{all};
			$state{count}   = scalar @{$diff->{all}};
			$env_changed{$env_name} = $diff->{all};
		} else {
			# Synced — check if branch's control sha matches deploy's
			my $deployed = ($dep_ctl && $branch_ctl && $dep_ctl eq $branch_ctl) ? 1 : 0;
			$state{status} = $deployed ? 'deployed' : 'awaiting-deploy';
		}

		$env_state{$env_name} = \%state;
	}

	# Run entry point algorithm to determine who's blocked
	my $targets = Genesis::CI::Propagation::compute_propagation_targets(
		dag_order   => \@dag_order,
		parent_of   => \%parent_of,
		env_changed => \%env_changed,
	);

	for my $env_name (@dag_order) {
		my $state = $env_state{$env_name};
		next if $state->{status};  # already resolved (synced, no-branch, error)

		if ($targets->{$env_name}) {
			$state->{status} = 'pending';
		} else {
			# Has changes but not an entry point — blocked by ancestor
			my $blocker = $parent_of{$env_name};
			while ($blocker && !$env_changed{$blocker}) {
				$blocker = $parent_of{$blocker};
			}
			$state->{status}  = 'blocked';
			$state->{blocker} = $blocker;
		}
	}

	# Pre-fetch open propagation PRs from GitHub if any env uses require_pr.
	# One paginated API call covers all envs; non-fatal if credentials are
	# absent or the call fails — display degrades to [PR required] for all.
	my %gh_open_prs;  # env_name => PR object for the most-recent open propagation PR
	{
		my $has_require_pr = grep { ($nodes->{$_}{require_pr} // 0) } keys %$nodes;
		if ($has_require_pr && $ENV{GITHUB_AUTH_TOKEN}) {
			my ($gh_owner, $gh_repo) = _github_owner_repo_from_remote($git);
			if ($gh_owner && $gh_repo) {
				my $github = Service::Github->new(org => $gh_owner);
				eval {
					my $prs = $github->list_prs("$gh_owner/$gh_repo", state => 'open');
					for my $pr (@$prs) {
						if ($pr->{head}{ref} =~ m{^propagate/([^/]+)/}) {
							$gh_open_prs{$1} //= $pr;
						}
					}
				};
				# Silently degrade on error — status output continues without PR info
			}
		}
	}

	# Display
	my $pipeline_name = $top->config->get('ci.name') || $top->type;
	my $provider_type = $top->config->get('ci.provider.type') || 'manual';

	output "\n#G{Pipeline}: #C{%s}  #Yi{provider}: %s  #Yi{control}: %s",
		$pipeline_name, $provider_type, $head_short;
	output "";

	# Compute column width: widest (indent + name) across all envs
	my $col_width = 0;
	my %depth_of;
	for my $env_name (@dag_order) {
		my $depth = 0;
		my $p = $parent_of{$env_name};
		while ($p) { $depth++; $p = $parent_of{$p}; }
		$depth_of{$env_name} = $depth;
		my $w = ($depth * 2) + length($env_name);
		$col_width = $w if $w > $col_width;
	}

	# SHA columns: fixed-width (7-char short SHA + padding).  Displays
	# the env branch's HEAD and the last successfully deployed commit
	# side by side so drift is visually obvious.
	my $sha_col = sub {
		my ($sha) = @_;
		return sprintf("%-7s", defined($sha) ? $sha : '-');
	};

	output "  %s  #u{%-7s}  #u{%-7s}  #u{%s}",
		' ' x $col_width, 'branch', 'deploy', 'status';

	for my $env_name (@dag_order) {
		my $state  = $env_state{$env_name};
		my $status = $state->{status};
		my $depth  = $depth_of{$env_name};
		my $indent = '  ' x $depth;
		my $pad    = $col_width - ($depth * 2) - length($env_name);
		$pad = 0 if $pad < 0;
		my $name_col = sprintf("%s%s%s", $indent, $env_name, ' ' x $pad);
		my $branch   = $sha_col->($state->{branch_sha});
		my $deployed = $sha_col->($state->{deployed_sha});

		if ($status eq 'deployed') {
			output "  #G{%s}  %s  %s  #G\@{+}#G{deployed}",
				$name_col, $branch, $deployed;
		} elsif ($status eq 'awaiting-deploy') {
			output "  #C{%s}  %s  %s  #Y\@{O}#Y{synced, pending deploy}",
				$name_col, $branch, $deployed;
		} elsif ($status eq 'pending') {
			my $req_pr  = ($nodes->{$env_name} || {})->{require_pr} // 0;
			if ($req_pr) {
				my $open_pr = $gh_open_prs{$env_name};
				if ($open_pr) {
					output "  #C{%s}  %s  %s  #Y\@{!}#Y{%d pending} #Yi{[PR #%d open: %s]}",
						$name_col, $branch, $deployed, $state->{count},
						$open_pr->{number}, $open_pr->{html_url};
				} else {
					output "  #C{%s}  %s  %s  #Y\@{!}#Y{%d pending} #Yi{[PR required]}",
						$name_col, $branch, $deployed, $state->{count};
				}
			} else {
				output "  #C{%s}  %s  %s  #Y\@{!}#Y{%d pending}",
					$name_col, $branch, $deployed, $state->{count};
			}
		} elsif ($status eq 'blocked') {
			output "  #C{%s}  %s  %s  #Y\@{!}#Yi{blocked by %s} (%d files)",
				$name_col, $branch, $deployed, $state->{blocker}, $state->{count};
		} elsif ($status eq 'no-branch') {
			output "  #K{%s}  %-7s  %-7s  #K\@{*}#K{not propagated}",
				$name_col, '-', '-';
		} elsif ($status eq 'error') {
			# Branch SHA is git-only — we already have it even if the env
			# itself couldn't be loaded.  Surface what we know plus the
			# reason instead of pretending the row is blank.
			my $reason = $state->{error} || 'unknown reason';
			output "  #R{%s}  %s  %-7s  #R\@{-}#R{load error}: #Ri{%s}",
				$name_col, $branch, '-', $reason;
		}
	}

	output "";
	exit 0;
}

# }}}
# propagate - route control branch changes to environment branches {{{
#
# Must be run from the control branch.  Optional positional argument
# names an environment whose children should be the propagation scope
# (cascade after deploy).  Without it, all envs are candidates and
# the entry point algorithm determines which receive files.
#
# Always sources files from control HEAD (or --commit).
sub propagate {
	my ($after_env) = @_;

	my $opts    = get_options;
	my $dry_run = $opts->{'dry-run'};
	my $no_push = $opts->{'no-push'};
	my $top     = Genesis::Top->new('.');

	bail("CI is not configured for this repository.")
		unless $top->ci_configured;

	my $git     = Service::Git->new('.', track_branch => !$dry_run);
	my $control = Genesis::Top::DEFAULT_CONTROL_BRANCH();

	bail(
		"Propagation must be run from the #C{%s} branch (currently on #C{%s}).",
		$control, $git->current_branch // '<detached>'
	) unless ($git->current_branch // '') eq $control;

	# Bail on uncommitted changes — even on --dry-run.  Propagation
	# operates on committed state; uncommitted edits to env files
	# would silently make a dry-run misrepresent reality.
	bail(
		"Working tree has uncommitted changes.  Commit or stash them\n".
		"before running propagate."
	) unless $git->is_clean;

	# Build the DAG from control branch env files
	require Genesis::CI::Compiler::ASTBuilder;
	my $builder = Genesis::CI::Compiler::ASTBuilder->new(
		top     => $top,
		env_dir => $top->path,
	);
	my ($nodes, $edges) = $builder->_build_from_env_files($top->path);

	bail("No environments with pipeline metadata found.")
		unless %$nodes;

	my (%children, %has_parent, %parent_of);
	for my $edge (@$edges) {
		push @{ $children{$edge->{from}} }, $edge->{to};
		$has_parent{$edge->{to}} = 1;
		$parent_of{$edge->{to}} = $edge->{from};
	}

	# Topological order (BFS from roots)
	my @dag_order;
	my @queue = sort grep { !$has_parent{$_} } keys %$nodes;
	my %visited;
	while (@queue) {
		my $env = shift @queue;
		next if $visited{$env}++;
		push @dag_order, $env;
		push @queue, sort @{$children{$env} || []};
	}

	# Refresh env branch refs so diff computations see teammate commits.
	$top->fetch_pipeline_envs($git)
		unless $opts->{'no-fetch'};

	# Resolve the control SHA that will be the source of this propagation.
	#
	# Root propagation (no after_env): use control HEAD so freshly-pushed
	# commits reach the first tier immediately.  This preserves the
	# "always HEAD" principle that solves the lost-no-op problem.
	#
	# Cascade propagation (after_env given): use <after_env>'s last
	# successfully deployed git.control_commit.  Descendants receive the
	# exact control state that was CERTIFIED at the ancestor — not
	# whatever happens to be on HEAD now.  This keeps commits travelling
	# as a unit down the chain even while control keeps advancing.
	my $control_sha = $opts->{commit} || $git->sha('HEAD');

	# Determine scope
	my @scope;
	if ($after_env) {
		bail("Environment #C{%s} is not in the pipeline topology.", $after_env)
			unless $nodes->{$after_env};

		# Verify the after_env has been propagated AND deployed
		my ($last_sync) = _resolve_propagation_base($after_env, $git);
		bail(
			"Environment #C{%s} has never been propagated to.\n".
			"Run #C{genesis propagate} without arguments first.",
			$after_env
		) unless $last_sync;

		my $after_load = eval { $top->load_env($after_env) };
		if ($after_load) {
			# Cascade requires a successful deployment with a recorded
			# git.control_commit.  The env branch being ahead of that
			# deployment is FINE — cascade intentionally propagates
			# the certified (last deployed) control state, not whatever
			# is currently on the env branch.  New changes on control
			# flow through a fresh root-propagate + deploy cycle.
			my $env_v = eval { $after_load->with_vault };
			unless ($env_v) {
				warning(
					"Could not verify deployment status for #C{%s} (vault unavailable).\n".
					"Ensure it has been deployed before cascading.",
					$after_env
				);
			} elsif (!$opts->{commit}) {
				my $dep = $env_v->deployments->latest_successful;
				bail(
					"Environment #C{%s} has never been successfully deployed.\n".
					"Deploy it before cascading to downstream environments.",
					$after_env
				) unless $dep;

				my $certified = $dep->lookup('git.control_commit');
				bail(
					"Environment #C{%s} has no #C{git.control_commit} in its\n".
					"last successful deployment (pre-pipeline deploy?).\n".
					"Cannot propagate safely - redeploy #C{%s} to record it.",
					$after_env, $after_env
				) unless $certified;

				$control_sha = $certified;
			}
		}

		my %child_set;
		my @expand = @{$children{$after_env} || []};
		while (@expand) {
			my $e = shift @expand;
			next if $child_set{$e}++;
			push @expand, @{$children{$e} || []};
		}
		@scope = grep { $child_set{$_} } @dag_order;
		unless (@scope) {
			info "\n#Yi{Environment %s has no downstream environments - nothing to propagate.}",
				$after_env;
			exit 0;
		}
	} else {
		@scope = @dag_order;
	}

	# An env branch that does not exist is a broken topology, not an env
	# with nothing to do.  The per-env diff below is
	# `git diff <env-branch>..<sha>`, which fails and returns an empty
	# list when the branch is absent -- so without this the run reports
	# "nothing to propagate" and exits successfully having done nothing.
	if (my @missing = _missing_env_branches($git, \@scope)) {
		bail(
			"No branch exists for %s:\n%s\n\n".
			"Propagation compares each environment's branch against %s, so an\n".
			"absent branch cannot be told apart from one with no changes.\n\n".
			"Create them with #C{genesis new <env>} on the %s branch%s.",
			(@missing == 1 ? "this environment" : "these environments"),
			join("\n", map {"  #C{$_}"} @missing),
			$control, $control,
			($opts->{'no-fetch'}
				? ", or drop #C{--no-fetch} if they exist on the remote"
				: "")
		);
	}

	my $control_short = $git->sha($control_sha, short => 1);
	if ($after_env) {
		info "\n#G{Propagating from} #C{%s} #G{@} #C{%s} #G{(certified by %s)}\n",
			$control, $control_short, $after_env;
	} else {
		info "\n#G{Propagating from} #C{%s} #G{@} #C{%s}\n",
			$control, $control_short;
	}

	# Build per-env diffs.  Two diffs per env:
	#   env_changed    — files on control not yet on the env branch
	#                    (what we'd copy if this env were an entry point)
	#   env_undeployed — files on control not yet DEPLOYED from this env
	#                    (branch may have them but exodus shows an older
	#                    commit).  Used by the entry-point algorithm so
	#                    descendants don't cascade past an ancestor that
	#                    has received a change on-branch but not yet
	#                    deployed it.
	my (%env_changed, %env_changed_detail, %env_undeployed, %env_skipped_ahead);
	for my $env_name (@scope) {
		# Every env in scope is known to have a branch: the guard above
		# bails otherwise, rather than skipping and reporting nothing.
		my $env = eval { $top->load_env($env_name) };
		next unless $env;

		my @dep_files = $env->propagation_files;
		next unless @dep_files;

		# Cascade-only safety: if this env's last propagation marker
		# already references a commit equal-to or descended-from
		# $control_sha, the env is at-or-ahead of the cascade source.
		# Propagating now would REGRESS its state to an older commit.
		# Skip the diff entirely so the env shows up in the summary
		# as "ahead of cascade source" rather than getting silently
		# rolled back.
		if ($after_env) {
			my ($env_last_sync) = _resolve_propagation_base($env_name, $git);
			if ($env_last_sync
				&& $git->is_ancestor($control_sha, $env_last_sync)) {
				$env_skipped_ahead{$env_name} = $git->sha($env_last_sync, short => 1);
				next;
			}
		}

		my $diff = $git->diff_files(
			$env_name, $control_sha, @dep_files
		);
		if (@{$diff->{all}}) {
			$env_changed{$env_name}        = $diff->{all};
			$env_changed_detail{$env_name} = $diff;
		}

		# Compute the undeployed set (for cascade-blocking).
		#
		# Anchor is the last-successful deploy's `git.control_commit`
		# (the control SHA that was propagated when this env last
		# deployed).  Diff that against control HEAD and filter by
		# dep_files to get "what's changed on control since this env
		# last shipped."
		#
		# Fallback (no exodus record, vault down, or pre-pipeline
		# deploy): conservatively treat everything the env would
		# receive via propagation as undeployed — blocks descendants
		# from cascading past an env whose state we can't verify.
		my $last_ctl_sha;
		my $env_v = eval { $env->with_vault };
		if ($env_v) {
			my $dep = eval { $env_v->deployments->latest_successful };
			$last_ctl_sha = $dep ? ($dep->lookup('git.control_commit') || '') : '';
		}
		if ($last_ctl_sha) {
			my $udiff = $git->diff_files(
				$last_ctl_sha, $control_sha, @dep_files
			);
			$env_undeployed{$env_name} = $udiff->{all} if @{$udiff->{all}};
		} elsif ($env_changed{$env_name}) {
			# No deploy history: use the env branch's own pending set
			$env_undeployed{$env_name} = $env_changed{$env_name};
		}
	}

	# Determine entry points
	my $env_propagate = Genesis::CI::Propagation::compute_propagation_targets(
		dag_order      => \@dag_order,
		parent_of      => \%parent_of,
		env_changed    => \%env_changed,
		env_undeployed => \%env_undeployed,
		scope          => \@scope,
	);

	# Pre-flight: build GitHub service once for all require_pr envs in scope.
	# Owner/repo is resolved from the remote URL; credentials are validated
	# against the API before touching any branches.  With --no-push, GitHub
	# is not contacted (no push, no PR) so credentials are not required.
	my ($gh_owner, $gh_repo, $github);
	if (!$dry_run) {
		my $needs_github = grep {
			$env_propagate->{$_} && ($nodes->{$_}{require_pr} // 0)
		} @scope;
		if ($needs_github) {
			($gh_owner, $gh_repo) = _github_owner_repo_from_remote($git);
			bail(
				"Could not determine GitHub owner/repo from remote URL.\n".
				"Ensure the origin remote points to a GitHub repository."
			) unless $gh_owner && $gh_repo;

			unless ($no_push) {
				bail(
					"GitHub credentials required for PR-based propagation.\n".
					"Set the GITHUB_AUTH_TOKEN environment variable."
				) unless $ENV{GITHUB_AUTH_TOKEN};

				$github = Service::Github->new(org => $gh_owner);
				my $authed_user = $github->get_authorized_user;
				bail(
					"GitHub credentials are invalid or lack sufficient permissions.\n".
					"Verify GITHUB_AUTH_TOKEN is a valid Personal Access Token."
				) unless $authed_user;
			}
		}
	}

	# Build the propagation target list in DAG order, then delegate
	# the per-env execution + batched push + PR API calls to the
	# shared Genesis::CI::Propagation::propagate_envs.
	my @targets;
	for my $env_name (@scope) {
		next unless $env_propagate->{$env_name};
		push @targets, {
			env        => $env_name,
			require_pr => $nodes->{$env_name}{require_pr} // 0,
			detail     => $env_changed_detail{$env_name} || {
				changed => $env_propagate->{$env_name},
				deleted => [],
				renamed => {},
			},
		};
	}

	my $owner_repo = ($gh_owner && $gh_repo) ? "$gh_owner/$gh_repo" : undef;
	my $result = Genesis::CI::Propagation::propagate_envs(
		git           => $git,
		github        => $github,
		owner_repo    => $owner_repo,
		targets       => \@targets,
		control       => $control,
		control_sha   => $control_sha,
		control_short => $control_short,
		push_direct_commits => 1,    # manual provider
		push_pr_branches    => 1,
		create_prs          => 1,
		no_push             => $no_push,
		dry_run             => $dry_run,
		push_extra_branches => @targets ? [$control] : [],
	);

	bail("Propagation aborted due to error.") if @{$result->{errors}};
	my $propagated = $result->{propagated};

	# Report any envs we deliberately skipped because they were already
	# at-or-ahead of the cascade source (avoids silent regressions).
	if (%env_skipped_ahead) {
		info "";
		for my $env_name (sort keys %env_skipped_ahead) {
			info "  #Y{%s}: skipped - already at #C{%s} (more recent %s commit)",
				$env_name, $env_skipped_ahead{$env_name}, $control;
		}
	}

	if ($propagated) {
		info "\n#G{Done.} %s %d environment%s.",
			$dry_run ? "Would propagate to" : "Propagated to",
			$propagated, $propagated == 1 ? '' : 's';
	} elsif (%env_skipped_ahead) {
		info "\n#Yi{No changes to propagate (downstream envs already up-to-date or ahead).}";
	} else {
		info "\n#Yi{No changes to propagate.}";
	}
	exit 0;
}

# _resolve_propagation_base - find the control SHA to diff from for an env branch {{{
#
# Resolution order:
#   1. Scan commit log for most recent [pipeline] control@<sha> → use that
#      (warns if it's not the HEAD commit, meaning manual commits were added)
#   2. No propagation commit found → branch was spawned from control, use
#      git merge-base as the starting point
#
# Returns: ($control_sha_full, $manual_commits_on_top)
# _summarize_load_error - extract a short, actionable reason from a
# load_env failure for the pipeline-status display.  bail() output is
# multi-line and decorated; we strip the noise and keep the first
# substantive line.
sub _summarize_load_error {
	my ($err) = @_;
	return 'unknown reason' unless defined($err) && length($err);

	# Strip ANSI color escapes and structural prose
	$err =~ s/\e\[[0-9;]*m//g;
	$err =~ s/\[FATAL\]\s*//g;
	$err =~ s/Environment\s+\S+\s+could not be loaded:\s*//g;
	$err =~ s/Please fix the above errors and try again\.\s*//g;

	# Take the first non-blank line that looks like a reason
	my $reason;
	for my $line (split /\n/, $err) {
		$line =~ s/^\s*-\s+//;     # bullet prefix
		$line =~ s/^\s+|\s+$//g;
		next unless length $line;
		next if $line =~ /^at \S+ line \d+/;  # perl trace frames
		$reason = $line;
		last;
	}
	$reason //= 'unknown reason';

	# Trim to fit on one terminal row alongside the rest of the row
	$reason = substr($reason, 0, 80) . '...' if length($reason) > 80;
	return $reason;
}

# _missing_env_branches - envs in scope that have no branch {{{
#
# Kept separate from propagate() so the decision can be tested without a
# repository: the command needs a working tree, a DAG and a vault before
# it reaches this point.
sub _missing_env_branches {
	my ($git, $scope) = @_;
	return grep {!$git->branch_exists($_)} @$scope;
}

# }}}
sub _resolve_propagation_base {
	my ($branch, $git) = @_;
	$git ||= Service::Git->new('.');
	my $control = Genesis::Top::DEFAULT_CONTROL_BRANCH();

	# Scan log for propagation markers
	my @lines = $git->log_subjects($branch);
	my $depth = 0;
	for my $line (@lines) {
		if ($line =~ /^[0-9a-f]+ \[pipeline\] control\@([0-9a-f]+)/) {
			my $full = $git->sha($1);
			if ($depth > 0) {
				warning(
					"Branch #C{%s} has %d manual commit%s on top of the last propagation.",
					$branch, $depth, $depth == 1 ? '' : 's'
				);
			}
			return ($full, $depth);
		}
		$depth++;
	}

	# No propagation commit — use merge-base with control
	my $merge_base = $git->merge_base($control, $branch);
	return ($merge_base, 0) if $merge_base;

	return (undef, 0);
}
# }}}
# _verify_deployed - check that an env's propagated state was deployed {{{
#
# Compares the env branch HEAD against the git.commit field in the
# latest successful deployment's exodus audit data.  Requires vault.
# Warns and allows cascade if vault is unavailable.
sub _verify_deployed {
	my ($env_name, $env, $git) = @_;

	my $branch_head = $git->sha($env_name);

	# Vault access is required — soft-fail if unavailable
	my $env_with_vault = eval { $env->with_vault };
	unless ($env_with_vault) {
		warning(
			"Could not verify deployment status for #C{%s} (vault unavailable).\n".
			"Ensure it has been deployed before cascading.",
			$env_name
		);
		return;
	}

	my $deployment = $env_with_vault->deployments->latest_successful;
	bail(
		"Environment #C{%s} has never been successfully deployed.\n".
		"Deploy it before cascading to downstream environments.",
		$env_name
	) unless $deployment;

	my $deployed_commit = $deployment->lookup('git.commit') || '';
	if ($deployed_commit && $deployed_commit ne $branch_head) {
		bail(
			"Environment #C{%s} has been propagated but not yet deployed\n".
			"with the latest changes.  Deploy it before cascading to\n".
			"downstream environments.",
			$env_name
		);
	} elsif (!$deployed_commit) {
		# Pre-pipeline deployment (no git context in exodus) — warn only
		warning(
			"Environment #C{%s} was deployed before pipeline tracking was enabled.\n".
			"Cannot verify deployment state — ensure it has been deployed.",
			$env_name
		);
	}
}
# }}}
# _github_owner_repo_from_remote - parse owner and repo from the git remote URL {{{
#
# Supports SSH (git@github.com:owner/repo.git) and HTTPS formats.
# Returns (owner, repo) or (undef, undef) on failure.
sub _github_owner_repo_from_remote {
	my ($git) = @_;
	my $url = $git->remote_url($git->default_remote) or return (undef, undef);
	if ($url =~ m{github\.com[:/]([^/]+)/([^/.]+?)(?:\.git)?\s*$}) {
		return ($1, $2);
	}
	return (undef, undef);
}
# }}}

# }}}
# pipeline_graph - write pipeline.md with Mermaid flowchart {{{
sub pipeline_graph {
	my ($layout) = @_;
	option_defaults(config => 'ci.yml');

	my $opts = get_options;
	my $top  = Genesis::Top->new('.');

	# For env-file topology, build the DAG directly.
	if ($top->ci_configured) {
		my $env_dir = $top->path;
		require Genesis::CI::Compiler::ASTBuilder;
		my $builder = Genesis::CI::Compiler::ASTBuilder->new(
			top     => $top,
			env_dir => $env_dir,
		);
		my ($nodes, $edges) = $builder->_build_from_env_files($env_dir);
		my $md = _topology_to_mermaid_md($top, $nodes, $edges);
		mkfile_or_fail('pipeline.md', $md);
		info("Wrote #C{pipeline.md}");
		exit 0;
	}

	# Full compiler path for legacy/multi-file configurations
	my $platform = $opts->{platform} || 'concourse';
	my $result   = _compile_pipeline($top, $platform);
	my $ast      = $result->{ast};
	my $provider = $result->{provider};

	my $md = $provider->can('graph_md')
		? $provider->graph_md()
		: _ast_to_mermaid_md($ast);

	mkfile_or_fail('pipeline.md', $md);
	info("Wrote #C{pipeline.md}");
	exit 0;
}

# }}}
# pipeline_describe - human-readable pipeline progression {{{
sub pipeline_describe {
	my ($layout) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $top      = Genesis::Top->new('.');

	# For env-file topology (manual provider or genesis-config CI),
	# build the DAG directly without the full compiler/provider chain.
	if ($top->ci_configured) {
		my $env_dir = $top->path;
		require Genesis::CI::Compiler::ASTBuilder;
		my $builder = Genesis::CI::Compiler::ASTBuilder->new(
			top     => $top,
			env_dir => $env_dir,
		);
		my ($nodes, $edges) = $builder->_build_from_env_files($env_dir);
		_describe_topology($top, $nodes, $edges);
		exit 0;
	}

	# Full compiler path for legacy/multi-file configurations
	my $platform = $opts->{platform} || 'concourse';
	my $result   = _compile_pipeline($top, $platform);
	my $ast      = $result->{ast};
	my $provider = $result->{provider};

	if ($provider->can('generate_description')) {
		$provider->generate_description($ast);
	} else {
		_describe_ast($ast, $platform);
	}
	exit 0;
}

# }}}
# diff - show compiled vs live pipeline delta {{{
sub diff {
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';

	bail("diff is only supported for the 'concourse' platform")
		unless $platform eq 'concourse';

	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, $platform);
	my $ast    = $result->{ast};
	my $output = $result->{output};

	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my ($target, $k_flag) = _concourse_fly_flags($result, $opts, $name);

	my $compiled = $output->{'pipeline.yml'}
		or bail("Concourse provider did not produce pipeline.yml");

	my $dir = workdir;
	mkfile_or_fail("$dir/compiled.yml", $compiled);

	my ($live, $rc) = run("fly${k_flag} -t \$1 get-pipeline -p \$2", $target, $name);
	if ($rc != 0) {
		info("#Y{Pipeline '%s' does not exist on target '%s' — nothing to diff against.}",
			$name, $target);
		info("Run #C{genesis pipeline-apply} to deploy it first.");
		exit 0;
	}
	mkfile_or_fail("$dir/live.yml", $live);

	my ($diff_out, $diff_rc) = run(
		'diff -u --label live --label compiled $1 $2',
		"$dir/live.yml", "$dir/compiled.yml"
	);

	if ($diff_rc == 0) {
		info("#G{No differences} — compiled pipeline matches live pipeline.");
	} else {
		output({raw => 1}, $diff_out);
	}
	exit 0;
}

# }}}
# status - show per-env job health {{{
sub status {
	my ($filter_env) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';

	bail("status is only supported for the 'concourse' platform")
		unless $platform eq 'concourse';

	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, $platform);
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my ($target, $k_flag) = _concourse_fly_flags($result, $opts, $name);

	my ($json_out, $rc) = run("fly${k_flag} -t \$1 jobs -p \$2 --json", $target, $name);
	bail("Could not get jobs for pipeline '%s' on target '%s': %s", $name, $target, $json_out)
		unless $rc == 0;

	my $jobs;
	eval { $jobs = JSON::PP->new->decode($json_out) };
	bail("Failed to parse fly jobs output: %s", $@) if $@;

	output "#G{Pipeline}: #C{%s}  (#Yi{target}: %s)", $name, $target;
	output "";

	my %job_by_name = map { $_->{name} => $_ } @$jobs;

	my @ordered_names;
	for my $wf_name ($ast->workflow_names) {
		my @stage_order = eval { $ast->workflow_stage_order($wf_name) };
		if (@stage_order) {
			my $nodes = ($ast->workflows->{$wf_name} || {})->{graph}{nodes} || {};
			push @ordered_names, map { $nodes->{$_}{alias} || $_ } @stage_order;
		}
	}
	my %seen = map { $_ => 1 } @ordered_names;
	push @ordered_names, sort grep { !$seen{$_} } keys %job_by_name;

	my $col_w = 40;
	output "  %-${col_w}s  %-10s  %s", "Environment", "Status", "Notes";
	output "  %s  %s  %s", '-' x $col_w, '-' x 10, '-' x 20;

	for my $job_name (@ordered_names) {
		next if $filter_env && $job_name ne $filter_env;
		my $job = $job_by_name{$job_name} or next;

		my $status = _job_status_label($job);
		my @notes;
		push @notes, 'paused'  if $job->{paused};
		push @notes, 'errored' if ($job->{finished_build} || {})->{status} eq 'errored';

		output "  %-${col_w}s  %-10s  %s",
			$job_name,
			$status,
			join(', ', @notes) || '';
	}
	output "";
	exit 0;
}

# }}}
# pause - pause env job or entire pipeline {{{
sub pause {
	my ($env) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';

	bail("pause is only supported for the 'concourse' platform")
		unless $platform eq 'concourse';

	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, $platform);
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my ($target, $k_flag) = _concourse_fly_flags($result, $opts, $name);

	if ($env) {
		run({ interactive => 1,
		      onfailure => "Could not pause job '$env' in pipeline '$name'" },
			"fly${k_flag} -t \$1 pause-job -p \$2 -j \$3",
			$target, $name, $env);
		info("Paused job #C{%s} in pipeline #C{%s}", $env, $name);
	} else {
		run({ interactive => 1,
		      onfailure => "Could not pause pipeline '$name'" },
			"fly${k_flag} -t \$1 pause-pipeline -p \$2",
			$target, $name);
		info("Paused pipeline #C{%s}", $name);
	}
	exit 0;
}

# }}}
# resume - resume env job or entire pipeline {{{
sub resume {
	my ($env) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';

	bail("resume is only supported for the 'concourse' platform")
		unless $platform eq 'concourse';

	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, $platform);
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my ($target, $k_flag) = _concourse_fly_flags($result, $opts, $name);

	if ($env) {
		run({ interactive => 1,
		      onfailure => "Could not resume job '$env' in pipeline '$name'" },
			"fly${k_flag} -t \$1 unpause-job -p \$2 -j \$3",
			$target, $name, $env);
		info("Resumed job #C{%s} in pipeline #C{%s}", $env, $name);
	} else {
		run({ interactive => 1,
		      onfailure => "Could not resume pipeline '$name'" },
			"fly${k_flag} -t \$1 unpause-pipeline -p \$2",
			$target, $name);
		info("Resumed pipeline #C{%s}", $name);
	}
	exit 0;
}

# }}}
# }}}
### Deprecated Commands {{{

# repipe - deprecated; delegates to apply {{{
sub repipe {
	warning("'genesis repipe' is deprecated and will be removed in a future version.  Use 'genesis pipeline-apply' instead.");
	apply(@_);
}

# }}}
# graph - deprecated; legacy graphviz without --platform, modern pipeline.md with {{{
sub graph {
	warning("'genesis graph' is deprecated and will be removed in a future version.  Use 'genesis pipeline-graph' instead.");
	option_defaults(config => 'ci.yml');
	my $layout = $_[0];
	my $top    = Genesis::Top->new('.');

	if (get_options->{platform}) {
		return pipeline_graph($layout);
	}

	(my $pipeline, $layout) = Genesis::CI::Legacy::parse(get_options->{config}, $top, $layout);
	my $dot = Genesis::CI::Legacy::generate_pipeline_graphviz_source($pipeline);
	output "$dot";
	exit 0;
}

# }}}
# describe - deprecated; delegates to pipeline_describe {{{
sub describe {
	warning("'genesis describe' is deprecated and will be removed in a future version.  Use 'genesis pipeline-describe' instead.");
	pipeline_describe(@_);
}


# ci_pipeline_deploy, ci_show_changes, ci_generate_cache, and
# ci_pipeline_run_errand — the legacy pipeline task entry points —
# have been retired.  Their commands remain registered in bin/genesis
# with `retired => ...` so run_command bails at dispatch time and a
# legacy pipeline fails loudly instead of producing a silent-but-
# inconsistent deploy.  See lib/Genesis/Commands.pm run_command.

# }}}
# }}}
### Internal Compiler Helpers {{{

# _compile_pipeline - detect config source and compile; returns result hash {{{
sub _compile_pipeline {
	my ($top, $platform) = @_;

	my %compiler_opts = (top => $top);

	# Priority order:
	#   1. .genesis/ci/pipeline.yml or targets.yml  (multi-file)
	#   2. ci: section in .genesis/config           (genesis-config)
	#   3. Legacy ci.yml / --config file            (backward compat)
	my $ci_dir = $top->path('.genesis/ci');
	if (-d $ci_dir && (-f "$ci_dir/pipeline.yml" || -f "$ci_dir/targets.yml")) {
		$compiler_opts{ci_dir} = $ci_dir;
		info("Using multi-file CI configuration from #C{.genesis/ci/}");
	} elsif (Genesis::CI::Compiler->can_compile_from_genesis_config($top)) {
		info("Using inline CI configuration from #C{.genesis/config}");
	} else {
		$compiler_opts{file} = get_options->{config} || $top->path('ci.yml');
		info("Using legacy CI configuration from #C{%s}", $compiler_opts{file});
	}

	# Parse provider-specific CLI flags
	my %provider_cli_opts;
	{
		require Genesis::CI::Compiler::PipelineProvider;
		my @argv = ();
		Genesis::CI::Compiler::PipelineProvider->parse_cli_opts(
			\@argv, \%provider_cli_opts, $platform
		);
		for my $key (Genesis::CI::Compiler::PipelineProvider->cli_opt_keys($platform)) {
			$provider_cli_opts{$key} = get_options->{$key}
				if defined get_options->{$key};
		}
	}

	my $compiler = Genesis::CI::Compiler->new(%compiler_opts);
	my $result   = $compiler->compile(
		provider      => $platform,
		provider_opts => \%provider_cli_opts,
	);

	if (my $debug_dir = get_options->{'debug-dir'}) {
		_dump_debug_artifacts($debug_dir, $result, $platform);
	}

	$result->{provider_cli_opts} = \%provider_cli_opts;
	return $result;
}

# }}}
# _get_top - create Genesis::Top, optionally skipping vault {{{
sub _get_top {
	my ($opts, %defaults) = @_;

	my $skip = $opts->{'skip-vault'} || $defaults{skip_vault};
	if ($skip) {
		return Genesis::Top->new('.');
	}

	my $top = Genesis::Top->new('.', vault => $opts->{vault});
	bail(
		"No vault specified or configured.\n".
		"Use --skip-vault to compile without vault access."
	) unless $top->vault;
	return $top;
}

# }}}
# _dump_debug_artifacts - write compiler intermediates to a directory {{{
sub _dump_debug_artifacts {
	my ($debug_dir, $result, $platform) = @_;

	mkdir_or_fail($debug_dir);

	my $json = JSON::PP->new->pretty->canonical;

	if ($result->{parsed}) {
		mkfile_or_fail("$debug_dir/01-parsed.json",
			$json->encode($result->{parsed}));
		info("Debug: wrote #C{%s/01-parsed.json}", $debug_dir);
	}

	if (my $ast = $result->{ast}) {
		my %source;
		for my $key (qw(branches integrations targets workflows configuration
		                provider_config triggers resources)) {
			my $accessor = $ast->can($key);
			$source{$key} = $accessor->($ast) if $accessor;
		}
		$source{metadata} = $ast->metadata;
		$source{scripts}  = $ast->scripts;

		mkfile_or_fail("$debug_dir/02-ast-source.json",
			$json->encode(\%source));
		info("Debug: wrote #C{%s/02-ast-source.json}", $debug_dir);

		if ($ast->pipeline && %{$ast->pipeline}) {
			my %pipeline    = %{$ast->pipeline};
			my $mermaid     = delete $pipeline{mermaid};
			my $pipeline_md = delete $pipeline{pipeline_md};
			my $description = delete $pipeline{description};

			mkfile_or_fail("$debug_dir/03-pipeline.json",
				$json->encode(\%pipeline));
			info("Debug: wrote #C{%s/03-pipeline.json}", $debug_dir);

			if ($pipeline_md) {
				mkfile_or_fail("$debug_dir/04-pipeline.md", $pipeline_md);
				info("Debug: wrote #C{%s/04-pipeline.md}", $debug_dir);
			}

			if ($description) {
				mkfile_or_fail("$debug_dir/05-description.txt", $description);
				info("Debug: wrote #C{%s/05-description.txt}", $debug_dir);
			}
		}
	}

	if ($result->{output}) {
		if (ref($result->{output}) eq 'HASH') {
			for my $file (sort keys %{$result->{output}}) {
				mkfile_or_fail("$debug_dir/06-output-$file",
					$result->{output}{$file});
				info("Debug: wrote #C{%s/06-output-%s}", $debug_dir, $file);
			}
		} else {
			mkfile_or_fail("$debug_dir/06-output.yml", $result->{output});
			info("Debug: wrote #C{%s/06-output.yml}", $debug_dir);
		}
	}

	info("Debug artifacts written to #C{%s/}", $debug_dir);
}

# }}}
# _ast_to_mermaid_md - generate pipeline.md Mermaid content from a bare AST {{{
sub _ast_to_mermaid_md {
	my ($ast) = @_;

	my $name  = $ast->metadata->{name} || 'genesis-pipeline';
	my @lines = ("flowchart LR");

	for my $wf_name ($ast->workflow_names) {
		my $wf = $ast->workflows->{$wf_name};
		next unless $wf->{graph};

		my $nodes = $wf->{graph}{nodes} || {};
		my $edges = $wf->{graph}{edges} || [];

		my %in_any_edge;
		for my $edge (@$edges) {
			$in_any_edge{$edge->{from}} = 1;
			$in_any_edge{$edge->{to}}   = 1;
		}

		for my $edge (@$edges) {
			my $from = $nodes->{$edge->{from}}{alias} || $edge->{from};
			my $to   = $nodes->{$edge->{to}}{alias}   || $edge->{to};
			($from) =~ s/[^a-zA-Z0-9_]/_/g;
			($to)   =~ s/[^a-zA-Z0-9_]/_/g;
			push @lines, "  $from --> $to";
		}

		for my $n (sort keys %$nodes) {
			next if $in_any_edge{$n};
			my $alias = $nodes->{$n}{alias} || $n;
			($alias) =~ s/[^a-zA-Z0-9_]/_/g;
			push @lines, "  $alias";
		}
	}

	my $mermaid = join("\n", @lines) . "\n";
	return "# Pipeline: $name\n\n\`\`\`mermaid\n${mermaid}\`\`\`\n";
}

# }}}
# _topology_to_mermaid_md - mermaid flowchart from nodes+edges {{{
sub _topology_to_mermaid_md {
	my ($top, $nodes, $edges) = @_;

	my $name  = $top->config->get('ci.name') || $top->type;
	my @lines = (
		"---",
		"config:",
		"  flowchart:",
		"    useMaxWidth: false",
		"---",
		"flowchart TD",
	);

	# Declare nodes with explicit labels so names aren't truncated
	my %declared;
	for my $n (sort keys %$nodes) {
		my $label = $nodes->{$n}{alias} || $n;
		(my $id = $n) =~ s/[^a-zA-Z0-9_]/_/g;
		push @lines, "  ${id}[\"$label\"]";
		$declared{$n} = $id;
	}

	for my $edge (@$edges) {
		push @lines, "  $declared{$edge->{from}} --> $declared{$edge->{to}}";
	}

	my $mermaid = join("\n", @lines) . "\n";
	return "# Pipeline: $name\n\n\`\`\`mermaid\n${mermaid}\`\`\`\n";
}

# }}}
# _describe_topology - human-readable env-file topology description {{{
sub _describe_topology {
	my ($top, $nodes, $edges) = @_;

	my $name = $top->config->get('ci.name') || $top->type;
	my $provider_type = $top->config->get('ci.provider.type') || 'manual';
	output "\n#G{Pipeline}: #C{%s}", $name;
	output "  #Yi{Provider}: %s", $provider_type;
	output "";

	unless (%$nodes) {
		output "#Yi{No environments with pipeline metadata found.}";
		output "";
		return;
	}

	# Build adjacency: parent → [children]
	my %children;
	my %has_parent;
	for my $edge (@$edges) {
		push @{ $children{$edge->{from}} }, $edge->{to};
		$has_parent{$edge->{to}} = 1;
	}

	# Roots are nodes with no incoming edge
	my @roots = sort grep { !$has_parent{$_} } keys %$nodes;

	output "#G{Environment progression}:";
	output "";

	my $print_tree;
	$print_tree = sub {
		my ($env, $indent) = @_;
		my $node = $nodes->{$env};
		my @flags;
		push @flags, '#Y{manual}'     if $node->{manual};
		push @flags, '#M{require_pr}' if $node->{require_pr};
		my $flag_str = @flags ? '  (' . join(', ', @flags) . ')' : '';
		output "%s#C{%s}%s", $indent, $env, $flag_str;
		for my $child (sort @{$children{$env} || []}) {
			$print_tree->($child, "$indent  ");
		}
	};

	for my $root (@roots) {
		$print_tree->($root, '  ');
	}
	output "";
}

# }}}
# _describe_ast - human-readable AST description {{{
sub _describe_ast {
	my ($ast, $platform) = @_;

	output "#G{Pipeline}: #C{%s}", $ast->metadata->{name} || '(unnamed)';
	output "  #Yi{Platform}: %s", $platform;
	output "  #Yi{Source}:   %s", $ast->metadata->{source} || 'unknown';
	output "";

	my $integrations = $ast->integrations || {};
	if (my $sc = $integrations->{source_control}) {
		output "#G{Source Control}:";
		output "  Provider:   %s", $sc->{provider}   || 'unknown';
		output "  Repository: %s", $sc->{repository} || 'unknown';
	}

	my @targets = $ast->target_names;
	if (@targets) {
		output "";
		output "#G{Targets}: (%d)", scalar @targets;
		output "  - #C{%s}", $_ for sort @targets;
	}

	my @workflows = $ast->workflow_names;
	if (@workflows) {
		output "";
		output "#G{Workflows}: (%d)", scalar @workflows;
		for my $wf_name (sort @workflows) {
			my $wf = $ast->workflows->{$wf_name};
			output "  #Yi{%s} (%s)", $wf_name, $wf->{type} || 'deployment';

			if ($wf->{graph} && $wf->{graph}{nodes}) {
				my $nodes = $wf->{graph}{nodes};
				my $edges = $wf->{graph}{edges} || [];
				output "    Stages: %s", join(' -> ',
					map { $_->{alias} || $_->{genesis_env} || $_->{stage_name} }
					map { $nodes->{$_} }
					sort keys %$nodes
				);
				output "    Edges:  %d", scalar @$edges;
			}
		}
	}

	output "";
}

# }}}
# _concourse_fly_flags - derive (target, k_flag) from compiled result + CLI opts {{{
#
# Target resolution: explicit --target CLI opt > ci.provider.target config > pipeline name.
# k_flag is ' -k' when insecure is set, '' otherwise.
sub _concourse_fly_flags {
	my ($result, $opts, $name) = @_;
	my $provider = $result->{provider};
	my $target   = $opts->{target}
		// ($provider->can('provider_option') ? $provider->provider_option('target') : undef)
		// $name;
	my $insecure = $provider->can('provider_option')
		? ($provider->provider_option('insecure') // 0) : 0;
	my $k_flag   = $insecure ? ' -k' : '';
	return ($target, $k_flag);
}

# }}}
# _job_status_label - derive a display status from a fly jobs JSON entry {{{
sub _job_status_label {
	my ($job) = @_;
	return 'paused' if $job->{paused};
	my $fb = $job->{finished_build} || {};
	return $fb->{status} || 'pending';
}

# }}}
# }}}

1;

=head1 NAME

Genesis::Commands::Pipelines - Pipeline management command suite

=head1 DESCRIPTION

Implements the C<genesis pipeline-*> command family and the legacy
C<repipe>, C<graph>, C<describe>, C<embed>, and C<ci-*> commands.

=head1 COMMANDS

=over 4

=item B<pipeline-apply> [--platform PROVIDER] [--dry-run] [--paused]

Compile and deploy the pipeline. Defaults to Concourse. Supports
C<--dry-run> (print YAML only) and C<--output-dir> (write artifacts).

=item B<pipeline-graph> [--platform PROVIDER]

Compile pipeline and write C<pipeline.md> containing a Mermaid flowchart.

=item B<pipeline-describe> [--platform PROVIDER]

Compile pipeline and print a human-readable ordered progression.

=item B<pipeline-diff> [--target TARGET]

Compare compiled pipeline YAML against the live pipeline via
C<fly get-pipeline>.

=item B<pipeline-status> [<env>] [--target TARGET]

Query C<fly jobs> for per-environment job status.

=item B<pipeline-pause> [<env>] [--target TARGET]

Pause a specific environment's job, or the entire pipeline.

=item B<pipeline-resume> [<env>] [--target TARGET]

Resume a specific environment's job, or the entire pipeline.

=item B<repipe> (deprecated)

Alias for C<pipeline-apply>.

=item B<graph> (deprecated)

Legacy graphviz output without C<--platform>; C<pipeline-graph> with it.

=item B<describe> (deprecated)

Alias for C<pipeline-describe>.

=back

=head1 SEE ALSO

Genesis::CI::Compiler, Genesis::CI::Legacy

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
