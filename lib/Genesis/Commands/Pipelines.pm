package Genesis::Commands::Pipelines;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Commands;
use Genesis::Exit qw/CONFIG DATAERR NOPERM ABORTED TEMPFAIL/;
use Genesis::Config;
use Genesis::Term qw/in_controlling_terminal/;
use Genesis::UI qw/prompt_for_boolean/;
use Genesis::Top;
use Genesis::Env;
use Genesis::CI::Legacy qw//;
use Genesis::CI::Compiler;
use Genesis::CI::Compiler::PipelineProvider;
use Genesis::CI::Marker;
use Genesis::CI::Preflight;
use Genesis::CI::ProviderRegistry;
use Genesis::CI::Publish;
use Genesis::CI::Report;
use Genesis::CI::RunFailure qw/one_line/;
use Genesis::CI::Walk;
use Service::Git;
use Service::Github;
use Service::Vault::Remote;

use File::Basename qw/dirname/;
use File::Path qw/rmtree/;
use JSON::PP;

# The init file says who owns the branch, because an operator who finds it
# in a fresh clone has nothing else to read.
use constant INIT_FILE_BODY =>
	"This branch is managed by genesis pipeline-apply.\n";

### Public Commands {{{

# embed - embed Genesis binary in the repository {{{
sub embed {
	command_usage(1) if @_;
	Genesis::Top->new('.')->embed($ENV{GENESIS_CALLBACK_BIN} || $0);
}

# }}}
# apply - give the pipeline its shape on every provider (replaces repipe) {{{
sub apply {
	my ($layout) = @_;

	my $opts = get_options;

	# D64 refuses first, because the command applies a configured pipeline
	# and never enables one.  The refusal reads .genesis/config raw and
	# builds no Genesis::Top of its own, so it lands ahead of the vault
	# connection _get_top makes.  The dispatch gate already holds a handle
	# built without a vault, so this is only the first read that could ask
	# for one.  A repository with no pipeline has no reason to hold a
	# vault, and bailing on the vault first would name the wrong thing.
	_refuse_disabled_pipeline();

	my $top = _get_top($opts);

	# D27 took --platform away, so the provider is the one the repository
	# is configured for and nothing else, and under D15 an absent type is
	# the manual provider.  The refusal above has already turned away the
	# repository that declares no pipeline at all, so what reaches here is
	# a pipeline the operator enabled and chose a provider for.
	my $platform = $top->pipeline_provider_type // 'manual';

	my $git = Service::Git->new('.');

	# D44 gives the propagate run a preview that writes nothing of its own,
	# and a preview worth reading follows the same rule everywhere.  The flag
	# is read once here and handed to every stage below, so no stage has to
	# reach into the options for itself and none of them can disagree about
	# what a dry run is.
	#
	# What a dry run withholds is the repository, the remote, and the vault,
	# which are the three stores an operator cannot simply throw away again.
	# --output-dir and --debug-dir write into a directory the operator named
	# for the purpose, so a run that is given either of them still fills it.
	#
	# The banner names whichever of the two the run actually carries, and
	# says nothing about either where neither was given, because an exception
	# to a rule is worth reading only where it applies.  The POD describes the
	# pairing in full, which is where a reader goes to learn what the flags do
	# together rather than what this run is about to do.
	#
	# The manual provider is the one case where neither flag fills anything.
	# Both directories are written from the compiled result, and the manual
	# run exits below with the branch work behind it and the compile never
	# reached, so a manual repository that names a directory gets an empty
	# one.  Naming the exception there would promise a fill that cannot
	# happen, which is the same defect in the other direction.
	my $dry_run = $opts->{'dry-run'} ? 1 : 0;
	my @scratch = $platform eq 'manual'
		? ()
		: grep {$opts->{$_}} qw/output-dir debug-dir/;

	info("\n#G{Applying the pipeline} for #C{%s}\n", $top->type);
	info(
		"#Yi{This is a dry run.  Nothing below is written to the repository, ".
		"the remote, or the vault%s.}\n",
		@scratch == 1 ? sprintf(', and --%s still fills its own directory',
			$scratch[0])
		: @scratch     ? ', and --output-dir and --debug-dir still fill their '.
			'own directories'
		: ''
	) if $dry_run;

	# The apply records the commit it applied from, and Service::Git resolves
	# a ref through git rev-parse, which folds its own error text into the
	# answer rather than failing.  A clone without the control branch would
	# therefore record git's complaint as the commit, and every reader below
	# would compare real shas against a sentence.  The refusal lands here,
	# ahead of the first write of any kind, so nothing is half done.
	bail(
		{exitcode => CONFIG},
		"Refusing to apply.  The branch #C{%s} is not in this clone, and the ".
		"apply records the commit it applied from.\n\n".
		"Fetch it, or create it, then run #C{genesis pipeline-apply} again.  ".
		"No branch was created and no record was written.",
		$top->control_branch
	) unless $git->branch_exists($top->control_branch);

	# D43 gives the branch work to every provider and the pipeline work to
	# the automated ones alone, so the branches are made before the provider
	# is asked for anything.  A manual repository still delivers through
	# these branches, and the operator deploys from their own terminal.
	#
	# This sits ahead of every exit the compile and the provider stages
	# make, --output-dir included, so a run that only means to write the
	# compiled artifacts out still creates and publishes any deployment
	# branch the remote lacks.  A dry run reports the same branches and
	# writes none of them.  The POD says so where each option is described.
	_apply_init_branches($top, $git, dry_run => $dry_run);

	# D45 asks the repository to enforce what D31 has Genesis observe on its
	# own side, because Genesis cannot prevent a rewrite it does not perform
	# and a rewrite that drops a commit leaves every marker naming it
	# unfetchable.  The stage lands after the branches, since a rule applied
	# to a branch that does not exist protects nothing.
	#
	# The owner and the repository are split off the resolved pair rather
	# than read off whichever remote git lists first, so the override is
	# honoured and a repository that carries no pair was already refused by
	# name, at load.
	#
	# A token is what the API answers to, and the propagate path already
	# refuses without one, so a run that carries none names the variable it
	# wanted and carries on.  The branches are in place either way, and the
	# protection is the one stage an operator can apply later.
	if ($ENV{GITHUB_AUTH_TOKEN}) {
		my $owner_repo = $top->source_control_repository;
		my ($gh_owner) = split m{/}, $owner_repo, 2;
		my @branches = ({
			branch => $top->control_branch,
			rules  => _protection_rules_for($top, $top->control_branch,
				control => 1),
		});

		# The topology carries a normalised require_pr for every node, put
		# there from the environment files, and it is the same answer the
		# compiled pipeline runs that environment by.  Reading it here rather
		# than looking the key up again keeps the protection and the
		# propagation on one reader, so a file that spells the key false or
		# no gets a branch protected in the mode it is actually run in.  The
		# topology is held once, because building it walks every environment
		# file.
		my $topology = $top->pipeline_topology;
		for my $name (@{$topology->{order}}) {
			my $branch = $top->branch_for($name);
			push @branches, {
				branch => $branch,
				rules  => _protection_rules_for($top, $branch,
					require_pr => $topology->{nodes}{$name}{require_pr}),
			};
		}
		_apply_branch_protection(
			Service::Github->new(org => $gh_owner), $owner_repo,
			branches => \@branches,
			dry_run  => $dry_run,
		);
	} else {
		info(
			"  #Yi{skipped} the branch protection, because ".
			"#C{GITHUB_AUTH_TOKEN} is not set"
		);
	}

	# D103 records the pipeline's own facts once the branches are in place,
	# because a record written ahead of them would claim a shape the
	# repository does not have yet.  The record is what every reader below
	# uses to tell an applied pipeline from one nobody has applied, so the
	# manual provider writes it too and only the pipeline work is skipped.
	# An --output-dir run writes the compiled artifacts rather than setting
	# the pipeline, and it records what it applied as any other run does.  A
	# dry run reports the same records and writes none of them.
	_apply_records($top,
		control_commit => $git->sha($top->control_branch),
		provider       => $platform,
		skip_vault     => $opts->{'skip-vault'},
		dry_run        => $dry_run,
	);

	# The manual provider has no pipeline to set, which is a stage with
	# nothing to do rather than a run that failed, so the command says which
	# stage it skipped and exits 0 with the branch work behind it.  The
	# provider is the one read above, because the enabled refusal has
	# already run and nothing between here and there can change the key.
	if ($platform eq 'manual') {
		info(
			"\n#Y{The manual provider has no pipeline to set.}\n\n".
			"#i{Genesis is your CLI - deploys happen at your terminal, ".
			"not in a hosted pipeline.}\n\n".
			"To have Genesis set a pipeline as well, change ".
			"#C{pipeline.provider.type} in #C{.genesis/config} to one of: %s, ".
			"then run #C{genesis pipeline-apply} again.",
			join(', ', map {"#C{$_}"}
				Genesis::CI::ProviderRegistry->automated_providers())
		);
		exit 0;
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
		unless $top->pipeline_enabled;

	my $git     = Service::Git->new('.');
	my $control = $top->control_branch;

	my $topo = $top->pipeline_topology;
	bail("No environments with pipeline metadata found.")
		unless %{$topo->{nodes}};

	my $nodes     = $topo->{nodes};
	my $edges     = $topo->{edges};
	my %children  = %{$topo->{children}};
	my %parent_of = %{$topo->{parent_of}};
	my @dag_order = @{$topo->{order}};

	# pipeline_status is the one command that reads without refreshing, and
	# --no-refresh is what says so.  Every T-dependent answer it then gives
	# carries the unverifiable flag, which M17 renders.
	my $unverifiable = get_options->{'no-refresh'} ? 1 : 0;
	my $refreshed = $unverifiable
		? undef
		: $top->fetch_pipeline_envs($git, command => 'pipeline-status');

	# pipeline-status reports every state and resolves none, so it asks the
	# same question and refuses on the one answer that leaves it nothing to
	# read, which is a control branch that exists nowhere.
	my $control_state = Genesis::CI::Preflight::require_control($top, $git,
		refreshed     => $refreshed,
		command       => 'pipeline-status',
		unverifiable  => $unverifiable,
		on_divergence => 'report');
	info("  #Gi{%s}", $_) for @{$control_state->{events}};

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
		my ($branch_ctl) = _resolve_propagation_base($env_name, $git, $control);
		$state{branch_sha} = $branch_ctl
			? $git->sha($branch_ctl, short => 1)
			: undef;

		my $env = eval { $top->load_env($env_name) };
		unless ($env) {
			$state{status} = 'error';
			# The one caller with a column to print into.  The row below
			# puts the reason at the end of a fixed table, so a reason
			# longer than a terminal line wraps the table apart and the
			# wrapped half reads as a row of its own.
			$state{error}  = one_line($@, width => 80);
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

	# Who is held, and by whom.  An environment is held where an ancestor is
	# still sitting on a file the environment's own change touches, and the
	# ancestor named is the nearest one that shares a file, because that is
	# the deploy the operator is waiting on.  The walk answers the same
	# question per commit, and this display answers it over the whole diff.
	for my $env_name (@dag_order) {
		my $state = $env_state{$env_name};
		next if $state->{status};  # already resolved (synced, no-branch, error)

		my ($blocker, %seen);
		my $ancestor = $parent_of{$env_name};
		while (defined $ancestor && !$seen{$ancestor}++) {
			# The same rule the walk holds a commit by, asked here of the
			# whole diff rather than of one commit, so the two can never
			# disagree about what counts as an overlap.
			if (Genesis::CI::Walk::overlap($env_changed{$ancestor} || [],
					$env_changed{$env_name} || [])) {
				$blocker = $ancestor;
				last;
			}
			$ancestor = $parent_of{$ancestor};
		}

		$state->{status}  = defined $blocker ? 'blocked' : 'pending';
		$state->{blocker} = $blocker if defined $blocker;
	}

	# Pre-fetch open propagation PRs from GitHub if any env uses require_pr.
	# One paginated API call covers all envs; non-fatal if credentials are
	# absent or the call fails — display degrades to [PR required] for all.
	my %gh_open_prs;  # env_name => PR object for the most-recent open propagation PR
	{
		my $has_require_pr = grep { ($nodes->{$_}{require_pr} // 0) } keys %$nodes;
		if ($has_require_pr && $ENV{GITHUB_AUTH_TOKEN}) {
			# The pair the API targets is the one the source-control block
			# resolves, so an override is honoured and the remote read is
			# the one the pipeline uses rather than whichever remote git
			# happens to list first.  A pair it cannot resolve was refused
			# by name at configuration load, so there is nothing to guard.
			my $repository = $top->source_control_repository;
			my ($gh_owner) = split m{/}, $repository, 2;
			my $github = Service::Github->new(org => $gh_owner);
			# The head is matched against the branch each environment
			# would be given, so the name this column reads and the
			# name propagation opens come from the same accessor and
			# cannot disagree.  The names are composed outside the
			# eval below, because that eval is there to let missing
			# credentials and a failed API call degrade quietly, and
			# a prefix that collides with a branch name is neither.
			my %pr_branch_env = map {
				($top->pr_branch_for($_) => $_)
			} keys %$nodes;
			eval {
				my $prs = $github->list_prs($repository, state => 'open');
				for my $pr (@$prs) {
					my $env = $pr_branch_env{$pr->{head}{ref} // ''};
					$gh_open_prs{$env} //= $pr if defined $env;
				}
			};
			# Silently degrade on error — status output continues without PR info
		}
	}

	# Display
	my $pipeline_name = $top->config->get('pipeline.name') || $top->type;
	my $provider_type = $top->pipeline_provider_type // 'manual';

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
# propagate - deliver each due control commit to the branches that want it {{{
#
# The run stands itself on control, refreshes, settles every deployment
# branch, and then walks control once per environment, from the marker that
# environment's branch carries to control's own tip.  A branch that carries
# no marker has never been delivered to, and it is walked from the commit
# that introduced the environment instead (D61), which is routed and held
# like any other.  Each commit that touches the environment's set is
# delivered on its own, in control order, as one commit on the deployment
# branch (D34).
#
# The run takes no argument and sources control's tip, always.
sub propagate {
	# D36 retired the <env> argument together with the cascade it scoped,
	# because one run walks every environment and a commit held behind an
	# ancestor is released by the next bare run rather than by a run aimed
	# at it.  A caller that still passes one is told so, rather than having
	# it quietly ignored.  Nothing below can see an argument from here on,
	# so the cascade the variable feeds is unreachable until the walk
	# replaces it.
	command_usage(1) if @_;

	my $opts    = get_options;
	my $dry_run = $opts->{'dry-run'};
	my $top     = Genesis::Top->new('.');

	# Both refusals stand ahead of everything else the run does, because a
	# refusal raised after a walk has started is worse than no refusal at
	# all.  The disowned pipeline comes first, since a repository whose
	# configuration contradicts its own applied record has nothing useful
	# to say about which provider owns the propagation.  A repository that
	# never had a pipeline passes both and meets the pre-flight, which is
	# where a repository with nothing configured belongs.
	assert_not_disowned($top, 'propagate');
	assert_provider_gate($top, $opts);

	my $git     = Service::Git->new('.');
	my $control = $top->control_branch;

	# D96's first stage begins here, and control is its first question,
	# because the topology is read from control and a control nobody
	# refreshed makes every later answer worthless (D65, D30).  It stands
	# ahead of the branch check, since a branch that exists nowhere is not
	# one the operator can be asked to stand on.
	#
	# The refresh brings R into T for every branch in scope, control included,
	# before the first read of any of them (D40).  There is no flag, because a
	# report that quietly rested on a stale tracking ref is the thing this
	# removes.
	my $refreshed = $top->fetch_pipeline_envs($git, command => 'propagate');
	# The stage's events are not printed here.  The whole list is printed
	# once, where the deployment branches are settled, and a line printed
	# twice is worse than a line printed late.
	#
	# A preview is let past a control branch that is ahead of its remote,
	# and warns under its own banner that its answer assumes the push, which
	# is D44's first caveat.  Every other divergence is refused here for a
	# preview as it is for a run, because a stale control makes the topology
	# the preview reports on the wrong one.
	my $control_state = Genesis::CI::Preflight::require_control($top, $git,
		refreshed    => $refreshed,
		command      => 'propagate',
		permit_ahead => $dry_run ? 1 : 0);

	# The run stands itself on control rather than asking the operator to,
	# which is D65.  Everything below reads the environment files off the
	# working tree, so the switch is what makes a run from a feature branch
	# read the same topology as a run from control, and finish puts the
	# operator back on the branch they started from.
	#
	# The clean-tree refusal that stood beside the branch refusal has moved
	# rather than gone.  It now lives in the session's own begin, which
	# names the files it found, and it is the same guard stated where D84
	# puts it.  It applies to a dry run as it does to a writing one, because
	# a dry run switches to control like any other run and D65 puts the
	# clean assertion on the switch.
	my $session = open_control_session($top, $git);

	# A refusal from here on owes the operator their branch back before it
	# tells them why the run stopped.  The session's exit net would restore
	# it either way, but it would say so in a second error printed on top of
	# the refusal, so a refusal below closes the session and then speaks.
	my $refuse = sub { $session->finish; bail(@_) };

	# The pipeline's environments, as read from the control branch.
	my $topo = $top->pipeline_topology;
	$refuse->("No environments with pipeline metadata found.")
		unless %{$topo->{nodes}};

	# The DAG order is all this command takes from the topology now.  The
	# walk reads the nodes, the children, and each environment's parent for
	# itself, from the same reader, so the record it hands back carries them
	# and nothing here keeps a second copy.
	my @dag_order = @{$topo->{order}};

	# The rest of D96's first stage, now that the topology is known.  Every
	# refusal below is collected before anything is written, so a run that
	# stops here has left nothing partial behind.  It classifies the whole
	# DAG rather than the cascade's scope, because the initial state is a
	# property of the repository and not of the run, and it stands ahead of
	# the creation guard further down, which makes a deployment branch the
	# remote has never had and never publishes it, and so builds the very
	# shape the first of the two refusals below exists to refuse.
	my $initial = Genesis::CI::Preflight::initial_state($top, $git,
		envs      => \@dag_order,
		refreshed => $refreshed,
		control   => $control_state,
		command   => 'propagate',
		dry_run   => $dry_run);
	info("  #Gi{%s}", $_) for @{$initial->{events}};

	# D36 retired the cascade, so the run always sources control's own tip.
	# What each environment receives is decided commit by commit by the
	# walk, from the marker its own branch carries, rather than by one diff
	# taken against that tip.  Collapsing everything outstanding into one
	# diff made an urgent change to one environment wait behind an
	# unrelated earlier change to a shared file (D34).
	# Everything I11 lets the run read, read once and handed to the walk.
	# The banner names control's own commit, and reading it here rather than
	# off HEAD is what keeps the sha the operator reads and the sha the walk
	# routes from one fact.
	# The refusal closure goes with it, because this read stands inside the
	# open session and outside the eval below, so a refusal raised in there
	# would leave the operator on control with a second error printed on top
	# of the first.
	my $state = Genesis::CI::Walk::read_durable_state(
		top       => $top,
		git       => $git,
		refreshed => $refreshed ? 1 : 0,
		refuse    => $refuse,
	);
	my $control_sha   = $state->{control}{commit};
	my $control_short = $git->sha($control_sha, short => 1);

	# D94's fourth reading, said once for the repository.  An applied record
	# that is absent is legitimately absent until genesis pipeline-apply has
	# run, so the run reads it rather than refusing over it, and it says
	# which reading it took, because a reading nobody prints is one the
	# operator cannot act on.
	warning(
		"The pipeline has never been applied to this repository, so every ".
		"environment reads #C{not-propagated}.  Run #C{genesis ".
		"pipeline-apply} to record the commit it was applied from."
	) unless $state->{applied};

	info "\n#G{Propagating from} #C{%s} #G{@} #C{%s}",
		$control, $control_short;

	my $delivered = 0;
	my @publish_specs;
	my $publish;
	my $record;

	# The environment the run has reached, which is what the outcome words
	# are split on when the run ends early: everything up to and including
	# it records that nothing of its was published, and everything after it
	# records that it was not attempted.  It stays where the last turn of
	# the loop left it, so a failure raised once every environment has been
	# walked names the last of them and leaves nobody reading unattempted.
	my $at;

	# One eval around the walk, the whole delivery, and the push, because a
	# die that no guard caught is the run as a whole failing, and abort is
	# what answers it (D32): the partial write is named and discarded, every
	# branch this session committed to goes back to where the remote has it,
	# and the operator is put back on the branch they started from.
	#
	# The walk is inside it rather than in an eval of its own.  A walk that
	# cannot read what it needs ends the run exactly as a delivery that
	# cannot write does, under the same two classes of D82, and two evals
	# reading the same error two ways is how the two come to disagree about
	# a status.
	my $ran = eval {
		# The walk reads durable state and writes nothing at all.  Everything
		# it decides stands in the record, and the delivery below is the only
		# thing here that touches a branch.
		$record = Genesis::CI::Walk::plan($top,
			git       => $git,
			state     => $state,
			branches  => $initial->{branches},
		);

		# Every environment the run delivers to is loaded here, before the
		# first switch, because an environment is read off the working tree
		# and the working tree stands on control only until the first
		# delivery moves it.  A load made between two deliveries would read
		# whichever deployment branch the session happened to be standing
		# on, which carries one environment's files and nobody else's.
		my %env_of;
		for my $env_record (@{$record->{environments}}) {
			next if $env_record->{error};
			next unless @{$env_record->{pending}};
			$env_of{$env_record->{env}} = $top->load_env($env_record->{env});
		}

		for my $env_record (@{$record->{environments}}) {
			my $env_name = $env_record->{env};
			$at = $env_name;

			# D43's awaiting outcome.  genesis pipeline-apply is the one
			# command that cuts a deployment branch, so the run names that
			# command and carries on past the environment without writing.
			# It is held rather than failed, because nothing is wrong with
			# the environment and one command releases it.
			unless ($initial->{branches}{$env_name}) {
				$env_record->{outcome}        = 'held';
				$env_record->{outcome_detail} =
					Genesis::CI::Report::AWAITING_APPLY;
				next;
			}

			# D96's second stage as the walk already resolved it.  An error
			# the walk confined to this environment is this environment's
			# outcome, and it is named as one rather than as a warning
			# standing beside the report, because I8 asks that every
			# environment in scope end with an outcome and a warning is not
			# one.  The walk wrote failed on the record as it caught the
			# error, and the report carries the error beneath it.
			next if $env_record->{error};

			# The pull-request path is not built yet, and this guard goes
			# with the task that builds it.  Until then a push onto a branch
			# the repository's own policy says may only ever receive a
			# proposal is the one half-built stage worth refusing outright.
			if ($topo->{nodes}{$env_name}{require_pr}) {
				$env_record->{outcome}        = 'not attempted';
				$env_record->{outcome_detail} =
					'delivery by pull request is not built yet';
				next;
			}

			# An environment with nothing pending is left as the walk wrote
			# it, and the report settles what it reads: a hold that stands
			# says what the environment waits for, and an environment with
			# nothing standing at all reads idempotent.  Nothing is decided
			# here, because a run and a preview that decided it separately
			# are two outputs that can disagree about a word.
			my @pending = @{$env_record->{pending}};
			next unless @pending;

			my $env    = $env_of{$env_name};
			my $branch = $env_record->{branch};

			# D96's second stage.  A delivery that dies halfway ends this
			# environment and nothing else: the branch goes back to T so
			# that no part of the delivery survives, the environment records
			# failed, and the run walks on to the next one.  A run-fatal or
			# unsurvivable failure is not caught, and it reaches the run's
			# own eval below, which aborts everything.
			Genesis::CI::Walk::walk_one(
				session => $session,
				record  => $env_record,
				writes  => $dry_run ? 0 : 1,
				deliver => sub {
					$session->switch($branch);
					Genesis::CI::Walk::deliver_pending(
						session => $session,
						env     => $env,
						record  => $env_record,
						dry_run => $dry_run,
						# The ref the pre-flight would have moved this
						# branch to, which it sets under a dry run alone
						# because a dry run makes none of its writes.  The
						# walk already takes its base from it, and the
						# delivery is the other reader that wants one.
						base    => $initial->{branches}{$env_name}{assumed},
					);
				},
			);
			next if ($env_record->{outcome} // '') eq 'failed';

			# A preview leaves the outcome where the walk left it, which is
			# null, and the preview's own renderer writes the verb that says
			# this would have propagated.  Writing propagated here under a
			# dry run put a fact about a run that never happened into the
			# record, and every reader of that field then had to know which
			# kind of run had filled it.
			$env_record->{outcome} = 'propagated' unless $dry_run;
			$delivered += scalar(@pending);
			# The publish set carries specs rather than names, because the
			# stage that spends it reports per environment and a bare
			# branch name leaves it deriving the environment back out of
			# the slug.
			push @publish_specs, {
				branch => $branch,
				kind   => 'deployment',
				env    => $env_name,
			} unless $dry_run;
		}

		# D96's third stage.  The publish is held to the end of the walk, so
		# a run that failed halfway has put nothing on the remote.
		#
		# The push set is the deployment branches alone.  Control is the run's
		# input and never its output, which is D30, so what the publish does
		# with control is read it once more before the first push and refuse
		# where it has moved.  It is named to the stage for that reading and
		# for nothing else.
		#
		# It is inside the session rather than after it, because a remote that
		# has gone away is D82's unsurvivable failure and the answer to one
		# is the abort.  A run that could publish nothing leaves nothing
		# half-delivered in L either, and the next run redoes the whole of it.
		# A session already finished has nothing left to reset, and a branch
		# the remote refused is put back through the session for the same
		# reason.
		if (@publish_specs) {
			my $remote = $git->default_remote;
			if ($remote) {
				$publish = Genesis::CI::Publish::publish_run(
					git     => $git,
					session => $session,
					remote  => $remote,
					control => $control,
					records => $record->{environments},
					specs   => \@publish_specs,
					# D83's ask.  The delta every push would carry is
					# shown either way, and this answers the question
					# that follows it.
					yes     => $opts->{yes},
					# D82's two shapes reach one reading.  git push failing to
					# run at all raises, and a remote nobody can resolve comes
					# back as a refused push per ref, so a push git named no
					# ref on at all is the remote being gone, where a push git
					# did name refs on is those branches' own quarrel with it
					# however many of them it refused.  The words git wrote are
					# classified here, beside the run, because the remedy each
					# class earns is the run's to offer and not the stage's.
					unsurvivable => sub {
						my ($reason, $stderr) = @_;
						my ($message, $remedy) =
							_push_failure($remote, $reason, $stderr);
						die Genesis::CI::RunFailure->unsurvivable(
							message => $message,
							remedy  => $remedy,
						);
					},
				);
			}
		}
		1;
	};
	my $failure = $@;

	# D82's two classes, which are the errors no environment survives.  Both
	# abort the same way and differ only in the status they exit with, and
	# both leave through here, because everything an environment could
	# survive was answered inside the walk and never reached this eval.
	Genesis::CI::Walk::abort_run(
		session => $session,
		record  => $record,
		envs    => \@dag_order,
		at      => $at,
		error   => $failure,
	) unless $ran;

	# D30's in-sync rule, answered a second time by the publish and spent
	# here.  Control moving under the run leaves every marker the run wrote
	# naming a commit computed from a tip that has already moved, so the run
	# refuses rather than publishing it.  Nothing went to the remote and
	# every branch the run committed to is back where the remote has it, so
	# the refusal leaves the repository as it found it.
	#
	# D106 puts the status at TEMPFAIL, because a code says whether an
	# unaided retry fixes the condition.  Nothing the operator wrote is
	# wrong here.  Another clone moved control while this run was walking,
	# and the next run refreshes and walks from what is there now, so it
	# succeeds with nobody doing anything first.  That is the rejected push
	# this refusal resembles, which is the same event on a different ref.
	$refuse->({exitcode => TEMPFAIL}, '%s', $publish->{refused})
		if $publish && $publish->{refused};

	# The walk is over, so the operator goes back on the branch they started
	# this run from, before a word of the summary is printed.  Nothing below
	# reads the working tree.
	$session->finish;

	# I8's three axes, printed once the run has finished writing.  Every
	# environment in scope carries one outcome, every routed control commit
	# one of its own, and every overwritten hand edit a third.  It is one
	# call rather than lines scattered through the walk, because
	# pipeline-status renders the same record through the same helpers and
	# two outputs composing one phrase twice are two that can disagree.
	# D44's preview and the run's own report are one report, composed from
	# one record by one renderer, so the two cannot disagree about a word.
	# The preview enters through its own sub because it has a banner and one
	# verb of its own, and everything under those is the run's.
	#
	# D44's two caveats, gathered here and said by the report.  The run has
	# already asked git both questions, once to decide whether to refuse the
	# control branch and once to decide whether to reset a deployment
	# branch, so the answers are read off what those two stages settled
	# rather than asked again.  The renderer prints them under its banner,
	# which is the only place a caveat about a preview can stand and still
	# be read before the report it is about.
	$record->{warnings} = _preview_warnings($git, $control, $control_state,
		$initial, \@dag_order) if $dry_run && $record;

	$dry_run
		? Genesis::CI::Report::render_preview($record, git => $git)
		: Genesis::CI::Report::render_run($record, git => $git);

	# The decline is read before the count, because a run the operator
	# stopped wrote its branches and then put every one of them back, so the
	# walk's counter is true of the working tree and false of the remote.  A
	# delivered count standing directly above a report that says nothing was
	# published is the one number in the run that contradicts everything
	# under it, and the operator who stopped the run is the last person who
	# should have to work out which of the two to believe.
	if ($publish && $publish->{declined}) {
		info "\n#Yi{The publish was declined.  Every branch is back where ".
		     "the remote has it.}";
	} elsif ($delivered) {
		info "\n#G{Done.} %s %d commit%s.",
			$dry_run ? 'Would deliver' : 'Delivered',
			$delivered, $delivered == 1 ? '' : 's';
	} else {
		info "\n#Yi{No changes to propagate.}";
	}

	# D97's decline, which is the one status the publish decides rather than
	# the run's second stage.  It is the number every shell user reads as
	# the person having stopped it, and it is spent here rather than beside
	# the ask so the operator reads the report of what the run wrote before
	# they read the status of the run they stopped.  Every branch that work
	# went onto is already back where the remote has it.
	exit ABORTED if $publish && $publish->{declined};

	# D97's second stage, decided in one place and spent here.  The run's
	# own status is the only thing a caller reads, so the reading is not
	# repeated beside the report: the report says which environment ended
	# which way, and the sentence below says what the whole of that means
	# for the next run.  It names nobody, because naming an environment
	# twice sends an operator looking for two different problems.
	my $status = run_status($record);
	warning(
		"\nThe run was partial.  Everything the report says was published ".
		"still stands, and the next run repairs the rest."
	) if $status;
	exit $status;
}

# _preview_warnings - the two things a preview's answer rests on {{{
#
# D44 names two, and each is a fact one of the run's first two stages has
# already settled.  Control being ahead of its remote is what require_control
# would have refused had this been a run that writes, and a deployment branch
# with an assumed reset is one the pre-flight would have moved to its tracking
# ref before the walk.  Both come off those records rather than out of a
# second pair of git reads.
#
# The pre-flight makes two assumed moves and names each on the record it
# leaves, so the reset is picked out by its name rather than inferred.  D44's
# second caveat is about the reset alone, because a fast-forward discards
# nothing the preview would otherwise have reported.
#
# Each caveat carries its own count, which the renderer says the noun and the
# verb of.  Both numbers were read once already, one by the control check and
# one by the classification, so neither is asked of git again here.
sub _preview_warnings {
	my ($git, $control, $control_state, $initial, $order) = @_;

	# A repository with no remote configured has no name to print, and the
	# words that stand in for one belong in prose, which is how the
	# pre-flight's own refusals spell it.
	my $remote = $git->default_remote // 'the remote';
	my @caveats;

	my $divergence = $control_state->{divergence} || {};
	push @caveats, {
		kind    => 'unpushed-control',
		branch  => $control,
		remote  => $remote,
		commits => $divergence->{ahead} || 1,
	} if ($divergence->{state} // '') eq 'ahead';

	for my $env (@$order) {
		my $branch = $initial->{branches}{$env} or next;
		next unless ($branch->{assumed_move} // '') eq 'reset';
		push @caveats, {
			kind    => 'unreset-branch',
			branch  => $branch->{branch},
			remote  => $remote,
			commits => $branch->{assumed_commits} || 1,
		};
	}

	return \@caveats;
}

# }}}
# run_status - the exit status D97 gives the run's second stage {{{
#
# Zero is the run in which every environment ended published or held with
# its reason.  TEMPFAIL is a partial run, which the next run repairs, and
# sysexits defines it as a temporary failure with the user invited to retry.
#
# Three exits leave before this sub is reached and none of them is decided
# here.  The illegal initial state at DATAERR belongs to the first stage,
# because only a person can clear it.  The declined confirmation at ABORTED
# belongs to the publish.  So does the pre-publish re-check of control,
# which D106 puts at TEMPFAIL, the same code for the same reason a partial
# run earns it, which is that the next run repairs the condition unaided.
#
# The whole outcome is matched, under ruling 22, because the record carries
# the bare enum word in outcome and the qualifier beside it in
# outcome_detail.  Cutting a phrase at its comma was what the field split
# removed the need for, and the two ways an environment comes to read
# 'not published' both leave through a status of their own before anything
# here is reached: an aborted run through abort_run, and a declined publish
# through ABORTED.
#
# An outcome the walk left null is none of the three whichever way the report
# settles it.  Genesis::CI::Report settles one to held where a hold stands
# and to idempotent where nothing does, and neither is a partial word, so a
# record this sub is handed before the renderer has seen it and the same
# record after it answer one status.
sub run_status {
	my ($record) = @_;

	my %partial = map {$_ => 1}
		('failed', 'not attempted', 'publish rejected');

	for my $env (@{$record->{environments}}) {
		my $outcome = $env->{outcome} // 'idempotent';
		return TEMPFAIL if $partial{$outcome};
	}
	return 0;
}

# }}}
# _push_failure - the sentence and the remedy one refused push earns {{{
#
# D82 lists the remote unreachable, the credential rejected, and the host
# answering with a server error, and says that where the cause is known the
# report names it.  The three want different things of the operator, so each
# carries a corrective step of its own and a report that said the remote was
# unreachable over a rejected credential would send them to the wrong one.
#
# Two of git's own words arrive here rather than one.  What git wrote to its
# standard error is classified first, because the phrases that name a class
# live in the hint text git prints beside a refusal, and the short reason off
# the porcelain line is read after it, where there was no standard error to
# read.  A push that answered nothing at all carries neither, and the
# unreachable wording is what an unmatched line and an absent one both earn.
sub _push_failure {
	my ($remote, $reason, $stderr) = @_;

	# What git wrote to its standard error is read first, because the phrases
	# that name a class below, such as an authentication that failed, live in
	# the hint text git prints beside a refusal and not in the short phrase
	# the porcelain line carries in its parentheses.  The short phrase is
	# read where there is no hint text, so a refusal still names itself.
	my $said = (defined $stderr && length "$stderr") ? $stderr : $reason;
	my $line = ($said && length "$said") ? one_line($said) : '';

	return (
		sprintf('%s refused the credential this push offered: %s',
			$remote, $line),
		'fix the credential this repository pushes with and run it again'
	) if $line =~ m{
		authentication\ failed | permission\ denied |
		could\ not\ read\ (?:username|password) |
		terminal\ prompts\ disabled | invalid\ username\ or\ password |
		\b40[13]\b | unauthorized | forbidden
	}xi;

	return (
		sprintf('%s answered with a server error: %s', $remote, $line),
		'try again once the remote has recovered'
	) if $line =~ m{
		\bHTTP\ 5\d\d\b | internal\ server\ error |
		service\ unavailable | bad\ gateway | gateway\ time-?out
	}xi;

	return (
		sprintf('could not reach the remote %s%s',
			$remote, length($line) ? ": $line" : ''),
		'try again once the remote is reachable'
	);
}

# }}}
# _resolve_propagation_base - the control commit the branch's marker names {{{
#
# The marker walk lives in Genesis::CI::Marker, so this asks it rather than
# scanning subjects with a regex of its own.  The old scan was anchored
# against a format its caller never passed and it read subject lines alone,
# so a squash merge that pushed the marker down into the body answered
# nothing at all.  The walk reads bodies too, and it skips the commits above
# the marker rather than following them, which is what the warning below
# counts.
#
# The merge-base fallback stays for a branch that has never been delivered
# to, which is what the callers below still diff against until the walk of
# M10 gives them the seed.  The control branch is passed in rather than
# assumed, because the name is configured per repository and every caller
# has already read it.
#
# Returns: ($control_commit, $manual_commits_on_top).  The first value is
# the commit the marker names, spelled as fully as this repository can spell
# it, so a marker naming a commit the clone has never fetched comes back at
# the width the marker wrote it.
sub _resolve_propagation_base {
	my ($branch, $git, $control) = @_;
	$git ||= Service::Git->new('.');

	my ($marker, $depth) = Genesis::CI::Marker::newest($git, $branch);
	if (defined $marker) {
		warning(
			"Branch #C{%s} has %d manual commit%s on top of the last propagation.",
			$branch, $depth, $depth == 1 ? '' : 's'
		) if $depth > 0;
		return ($marker, $depth);
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
# }}}
# pipeline_graph - write pipeline.md with Mermaid flowchart {{{
sub pipeline_graph {
	my ($layout) = @_;

	my $top = Genesis::Top->new('.');

	# For env-file topology, build the DAG directly.
	if ($top->pipeline_enabled) {
		my $topo = $top->pipeline_topology;
		my $md = _topology_to_mermaid_md($top, $topo->{nodes}, $topo->{edges});
		mkfile_or_fail('pipeline.md', $md);
		info("Wrote #C{pipeline.md}");
		exit 0;
	}

	# The one configuration source is the pipeline section of
	# .genesis/config, so the whole compiler runs and draws the graph from
	# what it finds there, and the parser refuses a repository that has no
	# pipeline section at all.  Nothing here chooses a provider, so Concourse stands
	# in for the drawing.
	my $result   = _compile_pipeline($top, 'concourse');
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

	my $top = Genesis::Top->new('.');

	# For env-file topology (manual provider or genesis-config CI),
	# build the DAG directly without the full compiler/provider chain.
	#
	# The source-control values come first, and only on this branch,
	# because a repository with no pipeline configured has nothing for the
	# derivations to read and should not be asked.
	if ($top->pipeline_enabled) {
		_describe_source_control($top);
		my $topo = $top->pipeline_topology;
		_describe_topology($top, $topo->{nodes}, $topo->{edges});
		exit 0;
	}

	# The one configuration source is the pipeline section of
	# .genesis/config, so the whole compiler runs and the description comes
	# from what it finds there, and the parser refuses a repository that
	# has no pipeline section at all.  Nothing here chooses a provider, so Concourse
	# stands in for the telling.
	my $result   = _compile_pipeline($top, 'concourse');
	my $ast      = $result->{ast};
	my $provider = $result->{provider};

	if ($provider->can('generate_description')) {
		$provider->generate_description($ast);
	} else {
		_describe_ast($ast, 'concourse');
	}
	exit 0;
}

# }}}
# diff - show compiled vs live pipeline delta {{{
sub diff {
	my $opts   = get_options;
	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, 'concourse');
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

	my $opts   = get_options;
	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, 'concourse');
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

	my $opts   = get_options;
	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, 'concourse');
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

	my $opts   = get_options;
	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, 'concourse');
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
### Refusals {{{

# assert_not_disowned - refuse a pipeline the configuration has disowned {{{
#
# D64: where pipeline-apply has left an applied record while pipeline.enabled
# reads false, the configuration disowns a pipeline that is still live, still
# watching its branches, and still deploying.  The command refuses and names
# the two remedies.  The check needs the record and not just the key, because
# a repository that never had a pipeline has neither, and that repository is
# not disowning anything: it falls through to the pre-flight, which has its
# own words for a repository with no pipeline at all.
sub assert_not_disowned {
	my ($top, $command) = @_;

	return 1 if $top->pipeline_enabled;

	my $applied = $top->applied_record or return 1;

	bail(
		{exitcode => CONFIG},
		"Refusing to run #C{genesis %s}.  The pipeline is disabled in ".
		"#C{.genesis/config}, but the applied record says ".
		"#C{pipeline-apply} applied it from control\@%s at %s, so the ".
		"configuration disowns a pipeline that is still live, still ".
		"watching its branches, and still deploying.  Set ".
		"#C{pipeline.enabled: true} again, or tear the pipeline down by ".
		"hand, which has no command yet.  Nothing was written.",
		$command, $applied->{control_commit} // '<unknown>',
		$applied->{at} // '<unknown>'
	);
}

# }}}
# assert_provider_gate - the propagate run's break-glass past the pipeline {{{
#
# D95: under an automated provider the pipeline owns propagation, so a bare
# run refuses before it walks and --force is the only way past.  With the
# flag at a terminal the operator acknowledges once; outside a terminal the
# refusal stands, because the pipeline's own job sets GENESIS_PIPELINE_TASK
# and nothing legitimate reaches the gate unattended.  --dry-run passes
# because it writes nothing, and -y answers the publish confirmation alone,
# which is why nothing here reads it.
sub assert_provider_gate {
	my ($top, $opts) = @_;

	my $provider = $top->pipeline_provider_type;
	return 1 unless defined $provider && $provider ne 'manual';
	return 1 if $ENV{GENESIS_PIPELINE_TASK};

	my $warning = sprintf(
		"The #C{%s} pipeline owns propagation for this repository.  ".
		"Running it by hand does the pipeline's work without taking any ".
		"of the pipeline's locks, so the pipeline has no way to see you.",
		$provider
	);

	if ($opts->{'dry-run'}) {
		warning($warning);
		return 1;
	}

	bail(
		{exitcode => NOPERM},
		"%s\n\nRun it with #C{--force} at a terminal if you mean to.",
		$warning
	) unless $opts->{force};

	bail(
		{exitcode => NOPERM},
		"%s\n\n#C{--force} needs a terminal, because the acknowledgement ".
		"cannot be given without one.",
		$warning
	) unless in_controlling_terminal();

	warning($warning);
	bail(
		{exitcode => ABORTED},
		"Aborted at your request.  Nothing was written."
	) unless prompt_for_boolean("Proceed anyway? [y|n]", 0);

	return 1;
}

# }}}
# }}}
### The Session {{{

# open_control_session - begin a session and stand it on control {{{
#
# D65: the run switches to control inside its session rather than refusing
# off it, and finish puts the operator back where they stood.  The switch is
# what makes the run read the same topology wherever the operator was
# standing, because the environment files are read off the working tree and
# a feature branch carries whichever of them its author happened to touch.
#
# Nothing here asks whether the local control ref is there, because every
# caller reaches this sub through Genesis::CI::Preflight::require_control,
# which refuses each state in which that ref could be missing.  A branch
# that exists on neither side is refused there as configuration, and one
# that is on the remote and not in this clone is refused there as data, so
# by the time the switch below runs the ref is always in hand.
#
# The session comes from the handle rather than being built here, because
# the handle memoises one session per working tree, and that is what makes
# the one-session-per-run claim of I9 checkable rather than asserted.
sub open_control_session {
	my ($top, $git) = @_;

	my $control = $top->control_branch;
	my $session = $git->session(control => $control);
	$session->begin;
	$session->switch($control);
	return $session;
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
# graph - deprecated; legacy graphviz, with pipeline-graph as the successor {{{
sub graph {
	warning("'genesis graph' is deprecated and will be removed in a future version.  Use 'genesis pipeline-graph' instead.");
	option_defaults(config => 'ci.yml');
	my $layout = $_[0];
	my $top    = Genesis::Top->new('.');

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

# _compile_pipeline - compile from the repository configuration {{{
#
# D27 leaves one configuration source, which is the pipeline section of
# .genesis/config, so there is no precedence to work through here and no
# legacy file to fall back to.  A leftover .genesis/ci/ directory is not
# read and is not named either, because a directory nothing consults is
# not worth a line of the operator's attention.
sub _compile_pipeline {
	my ($top, $platform) = @_;

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

	my $compiler = Genesis::CI::Compiler->new(top => $top);
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
# _apply_init_branches - create every missing deployment branch {{{
#
# D43 makes this command the only creator of a deployment branch, and D42
# gives the branch its shape, which is an orphan whose root commit adds a
# single init file and carries [ci skip], so the pipeline's git resource
# registers the head as a version and skips the commit.  The first commit it
# does not skip is the seed the propagate run delivers later.
#
# Both sides are asked whether the branch is there, because they answer
# differently and each answer means something.  A branch the remote carries
# is left exactly as it stands, whatever the clone holds.  A branch the clone
# holds and the remote lacks is published rather than refused, since the
# creation would refuse to recreate it and the operator would be left with a
# branch that never reaches anybody else.
#
# Every question and every write names the remote that
# pipeline.source_control.remote resolves to, under D29, because that is the
# repository's own answer to where its branches live.  Reading whichever
# remote git happens to list first would ask the wrong repository on a clone
# that has two, and git lists them alphabetically rather than in the order
# the operator added them.
#
# The publish goes through push_append_only, so a tip that would rewrite what
# the remote already carries is refused by name instead of being force-pushed
# or swallowed.
#
# D44's preview is the same stage asking the same two questions and making
# neither write, so a dry run reports the branches it would cut and the ones
# it would publish and leaves the clone and the remote as it found them.
sub _apply_init_branches {
	my ($top, $git, %opts) = @_;

	# The derivation behind this bails on its own where it cannot settle a
	# name, so what comes back here is always a name.  Whether the clone has
	# a remote by that name is a separate question, and this is where it is
	# asked.
	my $remote = $top->source_control_remote;

	# D31 makes R the home of every deployment branch, so a repository with
	# nowhere to publish to is turned away before the first branch is
	# written rather than after it.  Creating one and then failing on the
	# publish would leave an orphan standing in the clone and would leave
	# every environment behind the first with nothing at all.  A remote the
	# clone does not have is configuration rather than a crash, so the
	# refusal carries the configuration code.
	bail(
		{exitcode => CONFIG},
		"Refusing to apply.  This repository has no git remote named ".
		"#C{%s}, which is the remote #C{pipeline.source_control.remote} ".
		"resolves to, so there is nowhere to publish the deployment ".
		"branches to.\n\n".
		"Add that remote, or point #C{pipeline.source_control.remote} at a ".
		"remote the clone has, then run #C{genesis pipeline-apply} again.  ".
		"No branch was created and no pipeline was set.",
		$remote
	) unless $git->has_remote($remote);

	# The command names itself and what it has not written yet, because the
	# refresh defaults its wording to propagate and would otherwise tell the
	# operator to re-run a command they never ran.
	$top->fetch_pipeline_envs($git,
		command => 'pipeline-apply',
		outcome => 'No branch was created and no pipeline was set.');

	my %report = (created => [], published => [], standing => []);
	for my $name (@{$top->pipeline_topology->{order}}) {
		my $branch = $top->branch_for($name);

		if ($git->remote_branch_exists($branch, $remote)) {
			info("  #Gi{standing} #C{%s}", $branch);
			push @{$report{standing}}, $branch;
			next;
		}

		# A dry run branches at the write and nowhere else, so the preview
		# reads the clone and the remote exactly as the writing run does and
		# reports the same three answers under the same three headings.  A
		# preview that called every missing branch a creation would tell the
		# operator that a branch they already hold is about to be cut.
		if ($git->branch_exists($branch)) {
			if ($opts{dry_run}) {
				info("  #Y{would publish} #C{%s}", $branch);
			} else {
				$git->push_append_only($branch, remote => $remote);
				info("  #G{published} #C{%s}", $branch);
			}
			push @{$report{published}}, $branch;
			next;
		}

		if ($opts{dry_run}) {
			info("  #Y{would create} #C{%s}", $branch);
		} else {
			$git->create_orphan_branch($branch,
				files   => {init => INIT_FILE_BODY},
				message => sprintf('Initialize %s branch [ci skip]', $branch),
			);
			$git->push_append_only($branch, remote => $remote);
			info("  #G{created} #C{%s}", $branch);
		}
		push @{$report{created}}, $branch;
	}

	return \%report;
}

# }}}
# _protection_rules_for - derive one branch's protection from decided state {{{
#
# D45 derives the protection from state the repository has already decided
# and one key, so nothing here is configured twice.  Control and every
# deployment branch block force pushes and require linear history, which is
# what makes D31's append-only rule enforceable rather than a convention
# Genesis observes on its own side.  A deployment branch requires a pull
# request where its require_pr is true, and control where
# control_requires_pr is true, whose default is false.  D52 makes rebase the
# only merge method into a deployment branch, so the merger never gets the
# chance to rewrite the aggregate commit's message and lose its marker,
# while control keeps squash or rebase because user pull requests carry no
# markers.  Nothing here dismisses a stale approval, because D51 keeps
# review safety in the mechanism and an approval has to survive the rebuild
# a later run pushes.
#
# allowed_merge_methods is a parameter of GitHub's pull_request rule, and
# that rule type requires a pull request before merging, so asking for
# rebase-only on a branch that takes direct pushes would stop them.  D45
# serves "a PR-only site and a lab that pushes directly" both, so the rule
# is gated on require_pr the way control's is gated on control_requires_pr.
# Nothing is lost where it is off: non_fast_forward and
# required_linear_history already keep history unrewritten and every commit
# fast-forward on every branch, and the marker rebase-only protects can only
# be lost by squashing a pull request, which a branch in no PR mode does not
# have.  D52's recovery covers a pull request opened into such a branch by
# hand, taking the marker from the pull request's body.
sub _protection_rules_for {
	my ($top, $branch, %opts) = @_;

	my @rules = (
		{type => 'non_fast_forward'},
		{type => 'required_linear_history'},
	);

	if ($opts{control}) {
		push @rules, {
			type       => 'pull_request',
			parameters => {
				required_approving_review_count => 1,
				allowed_merge_methods           => ['squash', 'rebase'],
			},
		} if $top->config->get('pipeline.source_control.control_requires_pr');
		return \@rules;
	}

	push @rules, {
		type       => 'pull_request',
		parameters => {
			required_approving_review_count => 1,
			allowed_merge_methods           => ['rebase'],
		},
	} if $opts{require_pr};

	return \@rules;
}

# }}}
# _apply_branch_protection - ask the repository for the protection {{{
#
# One ruleset per branch, named for the branch, so a re-run replaces rather
# than accumulates and an operator reading the repository's settings can
# tell which rules Genesis owns.  A branch the token cannot protect is
# reported by name with the settings it needed, and the run carries on.
#
# The environment is never read here, because the caller has already derived
# every rule, so this sub takes the client, the pair, the branches it is to
# send, and whether it is to send them at all.  Under D44's preview it names
# each branch and the settings that branch would be given, and asks the
# repository for nothing.
sub _apply_branch_protection {
	my ($gh, $owner_repo, %opts) = @_;

	my %missing;
	for my $spec (@{$opts{branches} || []}) {
		# A dry run sends nothing, and the rules are named rather than
		# counted, because which settings a branch is about to be given is
		# the whole of what an operator is previewing here.  Nothing can be
		# reported missing, since the repository was never asked, so the
		# preview leaves the missing set empty.
		if ($opts{dry_run}) {
			info("  #Y{would protect} #C{%s} with %s",
				$spec->{branch},
				join(', ', map {$_->{type}} @{$spec->{rules} || []}));
			next;
		}

		my ($ok, $reason) = $gh->set_ruleset($owner_repo,
			name     => sprintf('genesis-%s', $spec->{branch}),
			target   => 'branch',
			patterns => [$spec->{branch}],
			rules    => $spec->{rules},
		);
		if ($ok) {
			info("  #G{protected} #C{%s}", $spec->{branch});
			next;
		}

		$missing{$spec->{branch}} = [map {$_->{type}} @{$spec->{rules}}];
		warning(
			"Could not protect #C{%s}: %s\n".
			"  needed: %s\n".
			"Hand that list to whoever holds admin on the repository.  ".
			"Everything else was applied.",
			$spec->{branch}, $reason, join(', ', @{$missing{$spec->{branch}}})
		);
	}

	return \%missing;
}

# }}}
# _apply_records - write what the apply learned to exodus {{{
#
# D103 splits the writes across two owners, because the deploy rewrites its
# own exodus record on every run and would clobber anything the apply left
# beside it.  The pipeline's own facts go to Genesis::Top's path, and each
# environment's compiled facts go beside that environment's own record.
#
# Neither this helper nor the command spells either address.  Each owner
# composes its own, so the two writers can never drift apart on where the
# facts live.
#
# The per-environment loop belongs above the return, so the sub keeps the
# shape of a stage with more than one write in it rather than the shape of
# a single call.
sub _apply_records {
	my ($top, %opts) = @_;

	# The record is written to the vault, and --skip-vault says the operator
	# has none to write to, so the stage stands aside rather than refusing a
	# run the flag asked for or dying on a handle that was never built.  The
	# warning names the record in words rather than by its vault address,
	# because composing that address reads the repository's exodus mount and
	# refuses where there is no environment to read it from, which would turn
	# the stage that stands aside into the stage that stopped the run.
	if ($opts{skip_vault}) {
		warning(
			"Not writing the applied record, because #C{--skip-vault} was ".
			"given and that record lives in the vault.  Until an apply ".
			"writes it, nothing can tell this pipeline from one nobody has ".
			"applied."
		);
		return 1;
	}

	# apply refuses a clone without the control branch before it reaches
	# here, so a value that is not a sha means something between that
	# refusal and this call went wrong.  The record is what every reader
	# compares against, so it takes a sha or nothing at all.
	bug(
		"_apply_records was given #C{%s} as the control commit, which is not ".
		"a commit sha.  Git answers an unresolvable ref with its own error ".
		"text rather than failing, and a record holding that text would ".
		"match no commit any reader of it knows.",
		defined $opts{control_commit}
			? join(' ', split(/\s+/, $opts{control_commit}))
			: '(undefined)'
	) unless ($opts{control_commit} // '') =~ m/^[0-9a-f]{40}$/;

	# A dry run branches at the vault call and nowhere else, so the preview
	# walks the same stage the writing run walks and differs only in what it
	# does when it gets there.  The record is named in words rather than by
	# its vault address, for the reason the skip-vault warning names it that
	# way, which is that composing the address is itself a read and a
	# preview should not make one to describe a write it is not making.
	if ($opts{dry_run}) {
		info("  #Y{would record} the applied pipeline");
	} else {
		$top->applied_record(
			control_commit => $opts{control_commit},
			provider       => $opts{provider},
		);
		info("  #G{recorded} the applied pipeline at #C{%s}",
			$top->applied_record_path);
	}

	# One pass over the topology computes each environment's set and writes
	# it, in the order the walk itself reads, so the report reads top down.
	# D103 puts each record beside that environment's own exodus record, and
	# the absence of that subpath is the membership test the walk uses in
	# place of a roster, so an environment this loop never reaches carries
	# none and reads as one the applied record does not know.
	for my $name (@{$top->pipeline_topology->{order}}) {
		my $env = eval {$top->load_env($name)};
		my ($deps, $complete) = ([], 0);

		if ($env) {
			($deps, $complete) = $env->dependency_set;
		} else {
			# An environment that will not load is the same case as one
			# that will not render, which D77 answers with a warning and an
			# incomplete mark rather than a refusal.  A failure here costs
			# the manifest and nothing else, so the declared half is still
			# read, and only the discovered half goes missing.
			#
			# Both the declared read and the record write go through a bare
			# environment, which resolves the whole of genesis.pipeline and
			# the record's own address on the merged hierarchy with no kit.
			# The record is written even so, because an environment
			# carrying none at all reads as one the apply never reached.
			# The recovery is guarded in its turn, because every call it
			# makes can raise on its own.  An environment whose files will
			# not merge at all refuses the bare read and the record's
			# address alike, and a failure while recovering from a failure
			# should still cost one environment rather than the whole run.
			# The address is asked for here rather than left to the write,
			# so that the one thing the write can still raise on is the
			# vault, which is a failure of the stage and not of this
			# environment.
			my $load_err = $@;
			$env = eval {
				my $bare = Genesis::Env->bare($name, $top);
				$deps = [$bare->_declared_dependencies];
				$bare->pipeline_record_path;
				$bare;
			};

			unless ($env) {
				warning(
					"Could not load #C{%s}, and could not read it bare ".
					"either, so nothing was recorded for it: %s\n".
					"Until an apply records it, the walk reads it as an ".
					"environment no pipeline knows.",
					$name, one_line($@)
				);
				next;
			}

			warning(
				"Could not load #C{%s}, so only its declared dependencies ".
				"are wired: %s\n".
				"Re-run #C{genesis pipeline-apply} once it loads.",
				$name, one_line($load_err)
			);
		}

		# The same branch again, at the same place.  The set was computed
		# above whichever way this run is going, so a dry run reports the
		# dependencies it counted and the incomplete mark it would have
		# written, and only the write itself is withheld.
		if ($opts{dry_run}) {
			info("  #Y{would record} #C{%s} with %d dependenc%s%s",
				$name, scalar(@$deps), (@$deps == 1 ? 'y' : 'ies'),
				($complete ? '' : ' #Y{(discovery incomplete)}'));
			next;
		}

		$env->pipeline_record(
			dependencies => $deps,
			discovery    => ($complete ? 'complete' : 'incomplete'),
		);
		info("  #G{recorded} #C{%s} with %d dependenc%s%s",
			$name, scalar(@$deps), (@$deps == 1 ? 'y' : 'ies'),
			($complete ? '' : ' #Y{(discovery incomplete)}'));
	}

	return 1;
}

# }}}
# _refuse_disabled_pipeline - D64's refusal on a pipeline nobody declared {{{
#
# The key is read straight off .genesis/config, the way
# Genesis::Top::pipeline_enabled reads it, and a Genesis::Top is not built
# to read it.  That is what puts the refusal ahead of the vault.  Building
# a Top connects one, and a repository with no pipeline has no reason to
# hold a vault it would then be asked for.
#
# pipeline.enabled is the only key read, so a false key and an absent
# block answer alike.  Enabling is a configuration change the operator
# commits to control, and a command that edits configuration on the
# operator's behalf is the wrong shape, so this refuses rather than
# writing the key itself.
sub _refuse_disabled_pipeline {
	return 1 if Genesis::Config->new('.genesis/config')->get('pipeline.enabled');

	bail(
		{exitcode => CONFIG},
		"Refusing to apply.  #C{pipeline.enabled} is false or absent in ".
		"#C{.genesis/config}, and #C{pipeline-apply} applies a configured ".
		"pipeline and never enables one.\n\n".
		"Set #C{pipeline.enabled: true} on control, commit it, then run ".
		"#C{genesis pipeline-apply} again.  Nothing was written."
	);
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

	my $name  = $top->config->get('pipeline.name') || $top->type;
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
# _describe_source_control - print each source-control value and its tier {{{
#
# D29 has pipeline-describe open with the resolved source-control values,
# so an override that has drifted away from what git says is visible
# rather than silent.  Genesis::Top resolves them and says which tier each
# came from; this only lays them out.
sub _describe_source_control {
	my ($top) = @_;

	my $rows = $top->source_control_resolved;

	# Both columns are sized from the rows the way the status table sizes
	# its own, and the tier comes before the value rather than after it.  A
	# remote url is routinely longer than what is left of an eighty-column
	# line, and output wraps on whitespace, so a value printed last takes
	# the next line by itself when it is too long.  Printed after the value
	# the tier is what moves instead, and it lands on a line with no key
	# beside it, which is the one thing this report exists to show.
	my ($key_width, $tier_width) = (0, 0);
	for my $row (@$rows) {
		my ($k, $t) = (length($row->{key}), length($row->{source}));
		$key_width  = $k if $k > $key_width;
		$tier_width = $t if $t > $tier_width;
	}
	my $format = sprintf('  %%-%ds #Yi{%%-%ds} %%s', $key_width, $tier_width);

	output "\n#G{Source control}";
	output $format, $_->{key}, $_->{source}, $_->{value} for @$rows;
	output "";

	return 1;
}

# }}}
# _describe_topology - human-readable env-file topology description {{{
sub _describe_topology {
	my ($top, $nodes, $edges) = @_;

	my $name = $top->config->get('pipeline.name') || $top->type;
	my $provider_type = $top->pipeline_provider_type // 'manual';
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
# Target resolution: explicit --target CLI opt > pipeline.provider.target config > pipeline name.
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

=item B<pipeline-apply> [--dry-run] [--paused]

Give the pipeline its shape.  It creates each missing deployment branch
and publishes it, asks the repository to protect control and every
deployment branch, records what it applied and what each environment
depends on, and then sets the pipeline on the provider the repository
chose.  Under the C<manual> provider it does all of that except set a
pipeline.  The provider is the C<type> the repository declares under
C<pipeline.provider> in C<.genesis/config>, and no flag overrides it.
C<--dry-run> reports every one of those steps and writes nothing to the
repository, the remote, or the vault, and C<--output-dir> writes the
compiled artifacts to a directory whether or not it is a dry run.  Under
the C<manual> provider the run exits before the compile, so neither
C<--output-dir> nor C<--debug-dir> has anything to write and each leaves
its directory empty.

=item B<pipeline-graph>

Compile pipeline and write C<pipeline.md> containing a Mermaid flowchart.
Where the repository configures a pipeline, the flowchart is drawn from
the environment files and no provider is compiled for at all.

=item B<pipeline-describe>

Print a human-readable ordered progression.  Where the repository
configures a pipeline, the report opens with the resolved source-control
values and the tier each of them came from, so an override that has
drifted away from what git says can be seen.  Where it configures none,
the legacy configuration is compiled first and the progression is read
off the compiled result, so the command prints in either case.

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

Legacy graphviz output.  Use C<pipeline-graph> for the Mermaid flowchart
the compiler writes.

=item B<describe> (deprecated)

Alias for C<pipeline-describe>.

=back

=head1 SEE ALSO

Genesis::CI::Compiler, Genesis::CI::Legacy

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
