package Genesis::Commands::Pipelines;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term qw/bullet boxed/;
use Genesis::Commands;
use Genesis::Exit qw/CONFIG ABORTED TEMPFAIL/;
use Genesis::Config;
use Genesis::Top;
use Genesis::Env;
use Genesis::CI::Legacy qw//;
use Genesis::CI::Compiler;
use Genesis::CI::Marker ();
use Genesis::CI::ProviderCompiler;
use Genesis::CI::Preflight;
use Genesis::CI::ProviderRegistry;
use Genesis::CI::Publish;
use Genesis::CI::PullRequest;
use Genesis::CI::Report;
use Genesis::CI::RunFailure qw/one_line/;
use Genesis::CI::Status;
use Genesis::CI::Walk;
use Service::Git;
use Service::Vault::Remote;

use File::Basename qw/dirname/;
use File::Path qw/rmtree/;
use JSON::PP;
use Sys::Hostname ();

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

	# Read raw, ahead of the vault _get_top connects to.
	_refuse_disabled_pipeline();

	my $top = _get_top($opts);
	$top->read_shape_from_worktree if $opts->{'dry-run'}; # a preview (D112)

	my $platform = $top->pipeline_provider_type // 'manual';

	my $git = $top->git;

	# Read once and handed to every stage, so none can disagree on what a dry run is.
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
	_preview_shape($top) if $dry_run;

	# rev-parse answers a missing ref with its own error text, which would be recorded.
	bail(
		{exitcode => CONFIG},
		"Refusing to apply.  The branch #C{%s} is not in this clone, and the ".
		"apply records the commit it applied from.\n\n".
		"Fetch it, or create it, then run #C{genesis pipeline-apply} again.  ".
		"No branch was created and no record was written.",
		$top->control_branch
	) unless $git->branch_exists($top->control_branch);

	# The host is asked about the repository before anything is cut (D118).
	Genesis::CI::Preflight::refuse_once(
		problems => [Genesis::CI::Preflight::host_repository_problems($top, $top->github_client)],
		action   => 'apply',
		outcome  => 'No branch was created and no pipeline was set.',
	) if $ENV{GITHUB_AUTH_TOKEN} && !$dry_run;

	# And the fly target, which is each operator's own (D86).
	if ($platform eq 'concourse' && !$dry_run) {
		my $found = $top->pipeline_provider(
			(defined $opts->{target} ? (target => $opts->{target}) : ()),
		)->target_found;
		Genesis::CI::Preflight::refuse_once(
			problems => [Genesis::CI::Preflight::problem(CONFIG, $found->{refusal})],
			action   => 'apply',
			outcome  => 'No branch was created and no pipeline was set.',
		) if $found->{refusal};
	}

	# Compiled, and fly checked where it will be run, before anything is written (T384).
	my $deploys = $platform eq 'concourse' && !$dry_run && !$opts->{'output-dir'};
	my $result  = $platform eq 'manual' ? undef : _compile_pipeline($top, $platform);
	$result->{provider}->check_prereqs() or exit 86 if $deploys;

	_apply_init_branches($top, $git, dry_run => $dry_run);

	if ($ENV{GITHUB_AUTH_TOKEN}) {
		my $owner_repo = $top->source_control_repository;
		my @branches = ({
			branch => $top->control_branch,
			rules  => _protection_rules_for($top, $top->control_branch,
				control => 1),
		});

		# The topology's normalised require_pr, the reader the pipeline runs by.
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
			$top->github_client, $owner_repo,
			branches => \@branches,
			dry_run  => $dry_run,
		);
	} else {
		info(
			"  #Yi{skipped} the branch protection, because ".
			"#C{GITHUB_AUTH_TOKEN} is not set"
		);
	}

	_apply_records($top,
		control_commit => $git->sha($top->control_branch),
		provider       => $platform,
		skip_vault     => $opts->{'skip-vault'},
		dry_run        => $dry_run,
	);

	if ($platform eq 'manual') {
		info("\n%s", _manual_pipeline_notice());
		exit 0;
	}

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
		my $compiler = $result->{compiler};

		if ($opts->{'dry-run'}) {
			my $yaml = $output->{'pipeline.yml'}
				or bail("Concourse provider did not produce pipeline.yml");
			output({raw => 1}, $yaml);
			exit 0;
		}

		# A target only where the operator names one; fly resolves it otherwise (D86).
		my %deploy_opts = (pause_after_set => $opts->{paused});
		$deploy_opts{target} = $opts->{target} if defined $opts->{target};
		$compiler->deploy(%deploy_opts, yaml => $output->{'pipeline.yml'},
			pipeline_name => $name, yes => $opts->{yes});

	} elsif ($platform eq 'github-actions') {
		# Unreached today: the registry refuses the type first.  See the POD.
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
# pipeline_status - report where every environment stands {{{
#
# The read model for the pipeline.  The command refreshes unless --no-refresh
# says otherwise, computes the deployment root's record from the walk, and
# renders it as JSON or as the tree.  It writes nothing.
sub pipeline_status {

	# A propagate in this clone stands on a deployment branch while it
	# delivers, and that branch holds no .genesis/config, so there is nothing
	# here for a status to open.  Where the lock file names such a run, the
	# status says so rather than that this is no repository at all (D115,
	# noted 2026-10-12).
	unless (Genesis::Top->is_repo('.')) {
		require Service::Git::Session;
		my $holder = eval {Service::Git::Session->lock_holder(Service::Git->new('.'))};
		bail({exitcode => TEMPFAIL},
			"Refusing to run #C{genesis pipeline-status}.  A propagate is in progress ".
			"in this clone (process %s: %s), and it stands on a deployment branch ".
			"while it delivers, so there is no pipeline here to read.  Run ".
			"#C{genesis pipeline-status} again once it finishes, or from another clone.",
			$holder->{pid}, $holder->{command} // 'genesis propagate'
		) if $holder;
	}

	my $top = Genesis::Top->new('.');

	# A disowned pipeline is refused by the read model, once it has read the
	# shape from R's control, and before anything reaches standard output.
	my $git     = Service::Git->new('.');
	my $refresh = get_options->{'no-refresh'} ? 0 : 1;

	# The refresh's events are said as the read model raises them, which is
	# before the walk runs, so a walk that refuses below still leaves the
	# operator an account of the control ref the refresh created.  They go to
	# standard error, because standard output carries the report alone and a
	# consumer reading the JSON off that stream should find nothing else on
	# it.
	my $record = Genesis::CI::Status::status_records($top,
		git       => $git,
		refresh   => $refresh,
		on_events => sub { info("  #Gi{%s}", $_) for @_ },
	);

	# The rendered text goes through a '%s' format, because output reads its
	# first argument as one and both a commit subject and a JSON string can
	# carry a percent sign.
	output({raw => 1}, '%s', get_options->{json}
		? Genesis::CI::Status::render_json($record)
		: Genesis::CI::Status::render_tree($record, stale => !$refresh));

	exit 0;
}

# }}}
# pipeline_hold - set the propagation hold on one environment or the root {{{
#
# The hold has two forms, one environment or every environment in the
# deployment root, and the reason is required in both.  The environment is the
# CLI's own <env> prefix, which set_top_path has already resolved by the time
# we are called, so two arguments mean an environment and a reason, and one
# argument is read against the deployment root to find out which of the two it
# is.  The two forms differ in what fills the list and in nothing else, so the
# body is written once.
#
# A pipeline that is not enabled is refused, because a hold only stops a
# propagation and such a pipeline has none to stop (D64, noted 2026-10-13).
# The disowned pipeline, disabled with an applied record, is asked first and
# keeps its own refusal.
sub pipeline_hold {
	my @args = @_;
	my $opts = get_options();
	my $top  = _get_top($opts);

	Genesis::CI::Preflight::assert_not_disowned($top,
		command => 'pipeline-hold');
	Genesis::CI::Preflight::assert_pipeline_enabled($top, nothing_to => 'hold');

	# Both `genesis <env> pipeline-hold` and `genesis pipeline-hold
	# "<reason>"` arrive here carrying one argument, and only the repository
	# can tell the two apart.  The CLI read the prefix as an environment
	# because a file of that name sits in the deployment root, so the same
	# question is asked here and the two never disagree about what the
	# operator named.  An environment with nothing after it is the missing
	# reason the refusal below names.
	#
	# A call carrying more than two arguments, which is what an unquoted
	# reason of several words arrives as, matches neither form and leaves
	# both names undefined, so it reaches that same refusal.  There is no
	# separate refusal for the arity, because one that answered with the same
	# code and the same usage block would differ only in its sentence, and
	# the sentence below names the quoting for whichever call arrives.
	my ($env_name, $reason);
	if (@args == 2) {
		($env_name, $reason) = @args;
	} elsif (@args == 1) {
		(my $named = $args[0]) =~ s/\.yml$//;
		if (length($named) && -f $top->path("$named.yml")) {
			$env_name = $args[0];

		# A lone argument that names a file this root holds but cannot
		# resolve as an environment is a mistyped environment and not a
		# reason.  Reading it as one would hold every environment in the
		# root and write the filename in as the reason, which is the worst
		# of the three things it could do, so it is refused by name.
		} elsif (-f $top->path($args[0])) {
			command_usage(1, sprintf(
				"#C{%s} is a file in this deployment root, not a reason, and ".
				"it is not an environment either, since Genesis reads an ".
				"environment out of #C{<env>.yml}.", $args[0]
			));
		} else {
			$reason = $args[0];
		}
	}

	# set_top_path hands the prefix on as the basename of the file it
	# resolved, suffix and all, and an operator may have written the suffix
	# themselves.  It comes off once here, so the record's address and the
	# sentence the operator reads name one environment however the
	# environment was written on the command line.  Only `.yml` comes off,
	# because `.yml` is the one suffix the rest of Genesis reads an
	# environment file by, and a strip that took more than the existence
	# test below tries would read a file it never found as a reason.
	$env_name =~ s/\.yml$// if defined $env_name;

	command_usage(1,
		"A propagation hold needs a reason, and a reason of more than one ".
		"word has to be quoted."
	) unless defined($reason) && $reason =~ /\S/;

	for my $name (defined($env_name) ? ($env_name) : _root_environments($top)) {
		my $env = Genesis::Env->bare($name, $top)->with_vault;
		$env->set_hold(reason => $reason);
		info(
			"Propagation to #C{%s} is held: %s\n".
			"Release it with #C{%s}.",
			$name, $reason, Genesis::CI::Report::release_command($name)
		);
	}
	return 0;
}

# }}}
# pipeline_release - clear the propagation hold on one environment or the root {{{
#
# The release deletes the record and keeps no released-by fields, because the
# release's identity is its own log line, so we say who ran it here and write
# nothing about them to vault.  This is the only way a hold is cleared, which
# is why no deploy and no flag reaches this sub.
#
# The argument is read the way pipeline_hold reads its own, and there is
# nothing to tell apart here, because the only argument this command takes is
# the environment: one argument names an environment and no argument is the
# whole deployment root.  The suffix comes off for the reason it comes off
# there, since set_top_path hands the prefix on as the basename of the file it
# resolved and an operator may have written the suffix themselves.
#
# A pipeline that is not enabled is refused as the hold refuses it, for
# consistency, so a record left from when it was enabled is cleared by enabling
# it again (D64, noted 2026-10-13).  The disowned pipeline is asked first.
sub pipeline_release {
	my @args = @_;
	my $opts = get_options();
	my $top  = _get_top($opts);

	Genesis::CI::Preflight::assert_not_disowned($top,
		command => 'pipeline-release');
	Genesis::CI::Preflight::assert_pipeline_enabled($top,
		nothing_to => 'release a hold on');

	command_usage(1,
		sprintf(
			"A propagation release takes one environment at most.  Run ".
			"#C{%s} to release one environment, or ".
			"#C{genesis pipeline-release} to release every environment in ".
			"the deployment root.",
			Genesis::CI::Report::release_command(undef)
		)
	) if @args > 1;

	my $env_name = $args[0];
	$env_name =~ s/\.yml$// if defined $env_name;

	my $who = sprintf('%s@%s',
		($ENV{USER} // 'unknown'), Sys::Hostname::hostname());

	for my $name (defined($env_name) ? ($env_name) : _root_environments($top)) {
		my $env = Genesis::Env->bare($name, $top)->with_vault;

		# The record is read before it is deleted, because the line below says
		# what had been standing and for how long, and after the delete there
		# is nothing left to say it from.
		my $record = $env->hold_record;
		unless ($env->clear_hold) {
			info("No propagation hold stands on #C{%s}.", $name);
			next;
		}
		info("Released the propagation hold on #C{%s}, by #M{%s}.",
			$name, $who);

		# clear_hold answers a path whose contents it could not read as
		# cleared, and that is the one state hold_record answers nothing for,
		# so the sentence that quotes the record is written only where there
		# is a record to write it from.
		info("It had been held since %s: %s", $record->{at}, $record->{reason})
			if $record;
	}
	return 0;
}

# }}}
# propagate - deliver each due control commit to the branches that want it {{{
sub propagate {
	command_usage(1) if @_; # the <env> argument retired with the cascade

	my $opts    = get_options;
	my $dry_run = $opts->{'dry-run'};
	my $top     = Genesis::Top->new('.');
	my $git     = Service::Git->new('.');
	my $control = $top->control_branch;

	# Every question first, against a snapshot of R, and one refusal (D115).
	my $checked = _propagate_check_first($top, $git, $opts);
	my %pr_branch_of = %{$checked->{pr_branch_of} || {}};

	my $refreshed = $checked->{refreshed}
		// $top->fetch_pipeline_envs($git, command => 'propagate');
	my $control_state = Genesis::CI::Preflight::require_control($top, $git,
		refreshed    => $refreshed,
		command      => 'propagate',
		preview      => $dry_run ? 1 : 0,
		permit_ahead => $dry_run ? 1 : 0);

	# A preview reads control's trees, so it opens no session (D112).
	my $session = $dry_run
		? $git->session(control => $top->control_branch)
		: open_control_session($top, $git);
	my $load_env = $dry_run
		? sub {$top->control_env($_[0])}
		: sub {$top->load_env($_[0])};

	# Closes the session, then speaks: the operator has their branch back first.
	my $refuse = sub { $session->finish; bail(@_) };

	# The pipeline's environments, as read from the control branch.
	my $topo = $top->pipeline_topology;
	$refuse->("No environments with pipeline metadata found.")
		unless %{$topo->{nodes}};

	my @dag_order = @{$topo->{order}};

	# The whole DAG, not a scope: the initial state is the repository's.
	my $initial = Genesis::CI::Preflight::initial_state($top, $git,
		envs      => \@dag_order,
		refreshed => $refreshed,
		control   => $control_state,
		command   => 'propagate',
		dry_run   => $dry_run);
	info("  #Gi{%s}", $_) for @{$initial->{events}};

	# Everything I11 lets the run read, read once; the banner's sha comes from it.
	my $state = Genesis::CI::Walk::read_durable_state(
		top       => $top,
		git       => $git,
		refreshed => $refreshed ? 1 : 0,
		refuse    => $refuse,
	);
	my $control_sha   = $state->{control}{commit};
	my $control_short = $git->sha($control_sha, short => 1);

	$refuse->({exitcode => CONFIG},
		"#C{genesis pipeline-apply} has never been run against this ".
		"repository: the vault holds no applied record at #C{%s}, so there is ".
		"no pipeline to propagate through.\n\n".
		"Run #C{genesis pipeline-apply} to apply the pipeline and record the ".
		"commit it was applied from, then run this again.  Nothing was written.",
		$top->applied_record_path
	) unless $state->{applied};

	info "\n#G{Propagating from} #C{%s} #G{@} #C{%s}",
		$control, $control_short;

	# The pull request environments the run's one client is decided from.
	my @in_scope = map {{
		env       => $_,
		branch    => $top->branch_for($_),
		pr_branch => $pr_branch_of{$_},
	}} grep {$topo->{nodes}{$_}{require_pr}} @dag_order;

	# The review state, once and ahead of the eval; the first stage's answer if it asked.
	my ($github, $owner_repo, $pr_state) = $checked->{github}
		? @{$checked->{github}}{qw/client owner_repo state_of/}
		: Genesis::CI::PullRequest::state_for_scope($top,
			envs    => \@in_scope,
			dry_run => $dry_run,
			refuse  => $refuse);
	$pr_state ||= {};
	my %pr_state_of = %$pr_state;

	my @publish_specs;
	my $publish;
	my $record;

	# Where an early end splits the outcome words.
	my $at;

	# One eval around the walk, the delivery and the push; abort_run answers it.
	my $ran = eval {
		# Writes nothing; the client lets a dropped marker come back from its pull request.
		$record = Genesis::CI::Walk::plan($top,
			git        => $git,
			state      => $state,
			branches   => $initial->{branches},
			github     => $github,
			state_of   => \%pr_state_of,
		);

		# Loaded before the first switch, while the tree still stands on control.
		my %env_of;
		for my $env_record (@{$record->{environments}}) {
			next if $env_record->{error};
			next unless @{$env_record->{pending}}
				|| $topo->{nodes}{$env_record->{env}}{require_pr};
			$env_of{$env_record->{env}} = $load_env->($env_record->{env});
		}

		for my $env_record (@{$record->{environments}}) {
			my $env_name = $env_record->{env};
			$at = $env_name;

			# Failed before branchless: a load failure outranks waiting for the apply.
			next if $env_record->{error};
			next unless $initial->{branches}{$env_name}; # awaiting the apply

			if ($topo->{nodes}{$env_name}{require_pr}) {
				my @pending = @{$env_record->{pending}};

				# Asked even with nothing due: a stale proposal is its to clear (D111).
				my $env = $env_of{$env_name} ||= $load_env->($env_name);
				Genesis::CI::Walk::walk_one(
					session => $session,
					record  => $env_record,
					writes  => $dry_run ? 0 : 1,
					deliver => sub {
						my $word = Genesis::CI::PullRequest::deliver(
							$session, $env_record,
							env     => $env,
							commits => \@pending,
							state   => $pr_state_of{$env_name}, # what the refusal stood on
							dry_run => $dry_run,
						);
						# A held environment is left for the report, which adds the qualifier.
						$env_record->{outcome} = $word
							if defined $word && !(
								$word eq 'idempotent'
								&& @{$env_record->{held} || []});
					},
				);
				next if ($env_record->{outcome} // '') eq 'failed';

				# expect is carried even undef: _push_one tests exists, and undef leases empty.
				push @publish_specs, {
					branch => $env_record->{pr}{branch},
					kind   => 'pr',
					env    => $env_name,
					expect => $env_record->{pr}{expected},
				} if !$dry_run && ($env_record->{pr}{action} // '') eq 'rebuild';
				next;
			}

			my @pending = @{$env_record->{pending}};
			next unless @pending; # the report settles held or idempotent

			my $env    = $env_of{$env_name};
			my $branch = $env_record->{branch};

			# The second stage: a delivery that dies halfway fails this environment alone.
			Genesis::CI::Walk::walk_one(
				session => $session,
				record  => $env_record,
				writes  => $dry_run ? 0 : 1,
				deliver => sub {
					# A preview never checks out: that would create a branch the clone lacks (D44).
					$session->switch($branch) unless $dry_run;
					Genesis::CI::Walk::deliver_pending(
						session => $session,
						env     => $env,
						record  => $env_record,
						dry_run => $dry_run,
						# Where the pre-flight would have moved the branch, else the branch.
						base    => $dry_run
							? ($initial->{branches}{$env_name}{assumed}
								// "refs/heads/$branch")
							: undef,
					);
				},
			);
			next if ($env_record->{outcome} // '') eq 'failed';

			# A preview leaves it null for its renderer's own verb.
			$env_record->{outcome} = 'propagated' unless $dry_run;
			push @publish_specs, {
				branch => $branch,
				kind   => 'deployment',
				env    => $env_name,
			} unless $dry_run;
		}

		# The third stage, inside the session so a gone remote is answered by the abort.
		if (@publish_specs) {
			my $remote = $git->pipeline_remote;
			$publish = Genesis::CI::Publish::publish_run(
				git     => $git,
				session => $session,
				control => $control,
				records => $record->{environments},
				specs   => \@publish_specs,
				yes     => $opts->{yes},
				# Classified here, beside the run, whose remedy each class earns.
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

			$record->{published} = $publish->{published} || []; # what _write_trailer_holds reads
		}

		# Only once the branch is on the remote: GitHub opens from what it holds.
		if ($github && $owner_repo && $publish) {
			my %published = map {($_ => 1)} @{$publish->{published} || []};
			for my $env_record (@{$record->{environments}}) {
				next unless $env_record->{pr};
				next unless $published{$env_record->{pr}{branch} // ''};
				Genesis::CI::PullRequest::sync_pull_request(
					$github, $owner_repo, $env_record,
					env => $env_of{$env_record->{env}});
			}
		}
		1;
	};
	my $failure = $@;

	# The two failure classes no environment survives; they differ only in status.
	Genesis::CI::Walk::abort_run(
		session => $session,
		record  => $record,
		envs    => \@dag_order,
		at      => $at,
		error   => $failure,
	) unless $ran;

	# Control moved under the run; an unaided retry fixes it, so TEMPFAIL.
	$refuse->({exitcode => TEMPFAIL}, '%s', $publish->{refused})
		if $publish && $publish->{refused};

	$session->finish; # nothing below reads the working tree

	# After the publish settles the delivery, before the report.
	_write_trailer_holds($top, $record) if $publish;

	# The preview's caveats, read off what the first two stages settled.
	$record->{warnings} = _preview_warnings($top->source_control_remote,
		$control, $control_state, $initial, \@dag_order) if $dry_run && $record;

	$dry_run
		? Genesis::CI::Report::render_preview($record, git => $git)
		: Genesis::CI::Report::render_run($record, git => $git);

	# Counted once the publish has settled each outcome; a preview counts its own verb.
	my $delivered = 0;
	my $due       = 0;
	for my $env (@{$record->{environments} || []}) {
		my $routed = scalar @{$env->{pending} || []};
		$due += $routed;
		$delivered += $routed if ($env->{outcome} // '') eq ($dry_run
			? Genesis::CI::Report::WOULD_PROPAGATE()
			: 'propagated');
	}

	if ($publish && $publish->{declined}) {
		info "\n#Yi{The publish was declined.  Every branch is back where ".
		     "the remote has it.}";
	} elsif ($delivered) {
		info "\n#G{Done.} %s %d commit%s.",
			$dry_run ? 'Would deliver' : 'Delivered',
			$delivered, $delivered == 1 ? '' : 's';
	} elsif (!$due) {
		# Only where nothing was due; the report has said the rest per environment.
		info "\n#Yi{No changes to propagate.}";
	}

	# Spent after the report, so it is read after what the run wrote.
	exit ABORTED if $publish && $publish->{declined};

	my $status = run_status($record);
	warning(
		"\nThe run was partial.  Everything the report says was published ".
		"still stands, and the next run repairs the rest."
	) if $status;
	exit $status;
}

# _write_trailer_holds - set the holds this run's deliveries carried {{{
#
# Propagate is the hold record's writer, and the write goes at delivery rather
# than at the deploy's exodus write, which closes the window between the BOSH
# step and that write.  The publish takes one branch at a time, so an
# environment whose push the remote refused was reset to T, delivered nothing,
# and takes no hold.
#
# The trailer is never read here, and it is never read twice.  gate_state is
# the one reader of the stage, and the walk asks it about each commit with the
# released set in hand, so the reason the hold form carries rides out on the
# delivered entry under hold_trailer_reason and this sub reads that.  Asking
# again from here, with a different set of arguments, is how one trailer comes
# to mean one thing to the walk and another to the writer: a gate the control
# branch has already reverted is delivered as an ordinary commit and would
# still have set a hold nothing on control accounts for.
#
# At most one entry per environment can carry the reason, because the walk
# delivers at most one unreleased gate to an environment in a run, so the
# assignment in the loop settles rather than competes.
#
# The record written here is the vault one and not the run's.  held_qualifier
# answers needs clearing off $record->{hold}, so filling that field would make
# this run's report call one environment delivered and held at once.  The run
# says what it did, under hold_set, and the next run reads the hold.
sub _write_trailer_holds {
	my ($top, $run) = @_;

	my %published = map {$_ => 1} @{$run->{published} || []};
	my @set;

	for my $env_record (@{$run->{environments} || []}) {
		next unless $published{$env_record->{branch} // ''};

		my $reason;
		for my $entry (@{$env_record->{pending} || []}) {
			next unless ($entry->{outcome} // '') eq 'delivered';
			$reason = $entry->{hold_trailer_reason}
				if defined $entry->{hold_trailer_reason};
		}
		next unless defined $reason;

		my $env = Genesis::Env->bare($env_record->{env}, $top)->with_vault;
		$env->set_hold(reason => $reason);
		$env_record->{hold_set} = $reason;
		push @set, $env->exodus_slug;
	}

	return \@set;
}

# }}}
# _preview_warnings - the three things a preview's answer rests on {{{
#
# There are three, and each is a fact one of the run's first two stages has
# already settled.  Control being ahead of its remote is what
# require_control would have refused had this been a run that writes, and a
# deployment branch with an assumed reset or an assumed fast-forward is one
# the pre-flight would have moved to its tracking ref before the walk.  All
# three come off those records rather than out of a second round of git
# reads.
#
# The pre-flight makes two assumed moves and names each on the record it
# leaves, so each is picked out by its name rather than inferred.  They earn
# a caveat apiece, and the fast-forward's says what a real run would move
# the branch up to rather than what it would discard, because a fast-forward
# discards nothing.
#
# Each caveat carries its own count, which the renderer says the noun and
# the verb of.  Every count was read once already, by the control check or
# by the classification, so none is asked of git again here.
sub _preview_warnings {
	my ($remote, $control, $control_state, $initial, $order) = @_;
	my @caveats;

	my $divergence = $control_state->{divergence} || {};
	push @caveats, {
		kind    => 'unpushed-control',
		branch  => $control,
		remote  => $remote,
		commits => $divergence->{ahead} || 1,
	} if ($divergence->{state} // '') eq 'ahead';

	# The three moves the stage assumes rather than makes, each in the order
	# the topology gives, so an operator reads the caveats in the order the
	# report goes on to name the environments.
	my %kind_of = (
		reset          => 'unreset-branch',
		'fast-forward' => 'unmoved-branch',
		create         => 'uncreated-branch',
	);
	for my $env (@$order) {
		my $branch = $initial->{branches}{$env} or next;
		my $kind = $kind_of{$branch->{assumed_move} // ''} or next;
		push @caveats, {
			kind    => $kind,
			branch  => $branch->{branch},
			remote  => $remote,
			commits => $branch->{assumed_commits} || 1,
		};
	}

	return \@caveats;
}

# }}}
# run_status - the exit status of the run's second stage {{{
#
# Zero is the run in which every environment ended published or held with
# its reason.  TEMPFAIL is a partial run, which the next run repairs, and
# sysexits defines it as a temporary failure with the user invited to retry.
#
# Three exits leave before this sub is reached and none of them is decided
# here.  The illegal initial state at DATAERR belongs to the first stage,
# because only a person can clear it.  The declined confirmation at ABORTED
# belongs to the publish.  So does the pre-publish re-check of control, which
# sits at TEMPFAIL, the same code for the same reason a partial run earns it,
# which is that the next run repairs the condition unaided.
#
# The whole outcome is matched, because the record carries
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
# A refused push has three known causes, which are the remote unreachable, the
# credential rejected, and the host answering with a server error, and where
# the cause is known the report names it.  The three want different things of
# the operator, so each carries a corrective step of its own and a report that
# said the remote was unreachable over a rejected credential would send them
# to the wrong one.
#
# Two of git's own words arrive here rather than one.  What git wrote to its
# standard error is classified first, because the phrases that name a class
# live in the hint text git prints beside a refusal, and the short reason off
# the porcelain line is read after it, where there was no standard error to
# read.  A push that answered nothing at all carries neither, and the
# unreachable wording is what an unmatched line and an absent one both earn.
sub _push_failure {
	my ($remote, $reason, $stderr) = @_;

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
# }}}
# pipeline_graph - print, or write, the Mermaid flowchart {{{
sub pipeline_graph {
	my ($layout) = @_;

	my $top = Genesis::Top->new('.', no_vault => 1); # a preview reads files only
	_preview_shape($top); # returns only on an enabled pipeline

	my $topo = $top->pipeline_topology;
	_emit_graph(_topology_to_mermaid_md($top, $topo->{nodes}, $topo->{edges}));
	exit 0;
}

# }}}
# _emit_graph - the drawing to standard output, or to the file --output names {{{
sub _emit_graph {
	my ($md) = @_;
	my $file = get_options->{output};
	return output({raw => 1}, $md) unless defined $file;
	mkfile_or_fail($file, $md);
	info("Wrote #C{%s}", $file);
}

# }}}
# pipeline_describe - human-readable pipeline progression {{{
sub pipeline_describe {
	my ($layout) = @_;

	my $top = Genesis::Top->new('.', no_vault => 1); # a preview reads files only
	_preview_shape($top); # returns only on an enabled pipeline

	_describe_source_control($top);
	my $topo = $top->pipeline_topology;
	_describe_topology($top, $topo->{nodes}, $topo->{edges});
	exit 0;
}

# }}}
# diff - show compiled vs live pipeline delta {{{
sub diff {
	my $opts   = get_options;
	my $top    = _get_top($opts, skip_vault => 1);
	_preview_shape($top);
	my $result = _concourse_compile($top, 'pipeline-diff');
	my $ast    = $result->{ast};
	my $output = $result->{output};

	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my $target = _concourse_target($result, $opts);

	my $compiled = $output->{'pipeline.yml'}
		or bail("Concourse provider did not produce pipeline.yml");

	my $dir = workdir;
	mkfile_or_fail("$dir/compiled.yml", $compiled);

	my ($live, $rc) = $result->{provider}->fly({target => $target},
		'get-pipeline', '-p', $name);
	if ($rc != 0) {
		info("#Y{Pipeline '%s' does not exist on target '%s', so there is ".
			"nothing to diff against.}",
			$name, $target);
		info("Run #C{genesis pipeline-apply} to deploy it first.");
		exit 0;
	}
	mkfile_or_fail("$dir/live.yml", $live);

	# Compared as data, since fly returns the pipeline in its own key order and
	# spells null its own way; JSON spells both sides alike.
	for my $side (qw/live compiled/) {
		my ($json, $rc, $err) = run({stderr => 0}, 'spruce json "$1"', "$dir/$side.yml");
		bail("Could not read the %s pipeline as data: %s", $side, $err // $json) if $rc;
		mkfile_or_fail("$dir/$side.json", $json);
	}
	my ($diff_out, $diff_rc) = run('spruce diff "$1" "$2"',
		"$dir/live.json", "$dir/compiled.json");

	if ($diff_rc == 0 && ($diff_out // '') !~ /\S/) {
		info("#G{No differences}.  The compiled pipeline matches the live ".
			"pipeline.");
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
	my $result = _concourse_compile($top, 'pipeline-jobs');
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my $target = _concourse_target($result, $opts);

	my ($json_out, $rc) = $result->{provider}->fly({target => $target},
		'jobs', '-p', $name, '--json');
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
	my $result = _concourse_compile($top, 'pipeline-pause');
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my $target = _concourse_target($result, $opts);

	if ($env) {
		$result->{provider}->fly({ interactive => 1, target => $target,
		      onfailure => "Could not pause job '$env' in pipeline '$name'" },
			'pause-job', '-p', $name, '-j', $env);
		info("Paused job #C{%s} in pipeline #C{%s}", $env, $name);
	} else {
		$result->{provider}->fly({ interactive => 1, target => $target,
		      onfailure => "Could not pause pipeline '$name'" },
			'pause-pipeline', '-p', $name);
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
	my $result = _concourse_compile($top, 'pipeline-resume');
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my $target = _concourse_target($result, $opts);

	if ($env) {
		$result->{provider}->fly({ interactive => 1, target => $target,
		      onfailure => "Could not resume job '$env' in pipeline '$name'" },
			'unpause-job', '-p', $name, '-j', $env);
		info("Resumed job #C{%s} in pipeline #C{%s}", $env, $name);
	} else {
		$result->{provider}->fly({ interactive => 1, target => $target,
		      onfailure => "Could not resume pipeline '$name'" },
			'unpause-pipeline', '-p', $name);
		info("Resumed pipeline #C{%s}", $name);
	}
	exit 0;
}

# }}}
# }}}
### The Session {{{

# _propagate_check_first - propagate's first stage: every question, then act {{{
sub _propagate_check_first {
	my ($top, $git, $opts) = @_;

	my $dry_run = $opts->{'dry-run'} ? 1 : 0;
	my $control = $top->control_branch;
	$top->assert_control_readable;

	# No pipeline section on the local control: nothing to ask R about (D64).
	if ($git->branch_exists("refs/heads/$control")) {
		# The deployment root's own config, which sits under the root's prefix
		# where the root is not the repository's top, as _topology_at reads it.
		my $path = (($git->prefixed(''))[0] // '') . '.genesis/config';
		my $blob = $git->read_blobs("refs/heads/$control", $path)->{$path};
		my $config = $blob ? eval {load_yaml($blob->{content})} : undef;
		bail({exitcode => CONFIG},
			"Refusing to run #C{genesis propagate}, because no pipeline is ".
			"configured on control: #C{.genesis/config} on #C{%s} has no ".
			"#C{pipeline} section.  Configure one on control, commit and push it, ".
			"run #C{genesis pipeline-apply}, then run this again.  Nothing was ".
			"written.", $control)
			unless ref($config) eq 'HASH' && exists $config->{pipeline};
	}

	my $remote  = $top->source_control_remote;
	my $ns      = "refs/genesis/preflight/$remote";
	my $session = $git->session(control => $control);
	$session->take_lock;

	my (@problems, $not_checked, $github);
	my ($topology, $pr_branch_of) = ({nodes => {}, order => []}, {});

	# A preview switches nothing, so only its own root's commits matter (D112).
	push @problems, $dry_run
		? ($git->preflight_problems,
		   Genesis::CI::Preflight::root_committed_problems($git, preview => 1))
		: Genesis::CI::Preflight::repository_problems($git);

	my $read = $git->snapshot_remote(remote => $remote, namespace => $ns,
		branches => [$control], globs => ['*/' . $top->type]);

	# Named below: whether its absence is a problem waits on the pipeline being enabled.
	my ($applied, @unapplied) = Genesis::CI::Preflight::applied_record_problems($top);

	my @reads_control = (
		'whether a provider pipeline owns propagation',
		'the environments',
		'the pull request branches',
		'the deployment branches',
		'the pull request reviews');

	if (!$read->{ok}) {
		my $because = $read->{kind} eq 'network'
			? 'the network or the remote is unreachable'
			: $read->{kind} eq 'auth'
			? 'the remote rejected our credentials'
			: 'the remote failed the request';
		push @problems, Genesis::CI::Preflight::problem(TEMPFAIL, sprintf(
			"Failed to reach #C{%s} to read the pipeline branches, because %s, ".
			"so nothing this command reads can be shown to be current.\n\n%s\n\n".
			"Restore access to #C{%s} and run the command again.",
			$remote, $because, ($read->{err} || 'no further detail') =~ s/\s+$//r,
			$remote));
		push @problems, @unapplied;
		$not_checked = {
			because => "nothing could be read from #C{$remote}",
			checks  => ["control's standing", @reads_control]};
	} elsif (my @standing = Genesis::CI::Preflight::control_problems($top, $git,
			tracking      => $ns,
			creates_local => $dry_run ? 0 : 1,
			preview       => $dry_run,
			permit_ahead  => $dry_run)) {
		push @problems, @standing, @unapplied;
		$not_checked = {
			because => 'the topology is read from control',
			checks  => \@reads_control};
	} else {
		# A preview with control ahead assumes it pushed, reading the local shape (D30).
		my $ahead = $dry_run && ((
			$git->resolve_branch($control, tracking => $ns) // {})->{state} // ''
		) eq 'ahead';
		$top->read_shape_from($ahead ? "refs/heads/$control" : "$ns/$control");
		info("There is no local #C{%s}, so this preview reads #C{%s/%s}.",
			$control, $remote, $control)
			if $dry_run && !$git->branch_exists("refs/heads/$control");

		# Not enabled ends the questions about it, the applied record's among them (D64).
		if (my @off = Genesis::CI::Preflight::pipeline_problems($top, $applied)) {
			push @problems, @off, grep {$_->{code} != CONFIG} @unapplied;
			$not_checked = {
				because => 'the pipeline is not enabled',
				checks  => \@reads_control};
		} else {
			push @problems, @unapplied;
			push @problems, Genesis::CI::Preflight::provider_gate_problems($top, $opts,
				dry_run => $dry_run);

			$topology = $top->pipeline_topology;
			push @problems, Genesis::CI::Preflight::problem(CONFIG,
				"No environments with pipeline metadata found.")
				unless %{$topology->{nodes}};

			my @prefix;
			($pr_branch_of, @prefix) = Genesis::CI::Preflight::prefix_problems($top,
				topology => $topology);
			my (undef, @initial) = Genesis::CI::Preflight::initial_state_problems($top, $git,
				envs     => $topology->{order},
				tracking => $ns);
			push @problems, @prefix, @initial;

			# The reviews are read by pull request branch, so a branch that
			# collides would be asked about under a name that is not its own.
			if (@prefix) {
				$not_checked = {
					because => 'the pull request branches collide',
					checks  => ['the pull request reviews']};
			} elsif ($ENV{GITHUB_AUTH_TOKEN}
					and grep {$topology->{nodes}{$_}{require_pr}} @{$topology->{order}}
					and my @host = Genesis::CI::Preflight::host_repository_problems($top, $top->github_client)) {
				# The reviews are read from the repository the host just refused.
				push @problems, @host;
				$not_checked = {
					because => 'the repository could not be asked about',
					checks  => ['the pull request reviews']};
			} else {
				my @github;
				($github, @github) = Genesis::CI::Preflight::github_problems($top,
					dry_run => $dry_run,
					envs    => [map {{
						env       => $_,
						branch    => $top->branch_for($_),
						pr_branch => $pr_branch_of->{$_},
					}} grep {$topology->{nodes}{$_}{require_pr}} @{$topology->{order}}]);
				push @problems, @github;
			}
		}
	}

	if (@problems) {
		$git->clear_snapshot(namespace => $ns);
		$session->release_lock;
		Genesis::CI::Preflight::refuse_once(
			problems => \@problems,
			action   => 'run #C{genesis propagate}',
			outcome  => 'Nothing was written.',
			($not_checked ? (not_checked => $not_checked) : ()));
	}

	Genesis::CI::Preflight::confirm_provider_gate($top, $opts, dry_run => $dry_run);

	# Not the pull request branches: their tracking refs are what a publish leases against.
	my @branches = ($control, map {$top->branch_for($_)} @{$topology->{order}});
	my $held     = $git->snapshot_refs(namespace => $ns);
	$git->promote_snapshot(remote => $remote, namespace => $ns,
		names => \@branches);

	# Never the branch the tree stands on, and none for a preview.
	my $here = $git->checked_out_branch // '';
	my (@fetched, @created, @absent);
	for my $branch (@branches) {
		push(@absent, $branch), next unless defined $held->{$branch};
		push @fetched, $branch;
		next if $dry_run
			|| $branch eq $here || $git->branch_exists("refs/heads/$branch");
		$git->create_branch($branch, $held->{$branch});
		push @created, $branch;
	}
	return {
		refreshed    => {ok => 1, kind => 'success', fetched => \@fetched,
		                 created => \@created, absent => \@absent},
		pr_branch_of => $pr_branch_of,
		github       => $github};
}

# }}}
# open_control_session - begin a session and stand it on control {{{
#
# The run switches to control inside its session rather than refusing off it,
# and finish puts the operator back where they stood.  The switch is what
# makes the run read the same topology wherever the operator was standing,
# because the environment files are read off the working tree and a feature
# branch carries whichever of them its author happened to touch.
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
# ci_pipeline_run_errand, which were the legacy pipeline task entry points,
# have been retired.  Their commands remain registered in bin/genesis with
# `retired => ...` so run_command bails at dispatch time and a legacy pipeline
# fails loudly instead of producing a silent-but-inconsistent deploy.  See
# lib/Genesis/Commands.pm run_command.

# }}}
# }}}
### Internal Compiler Helpers {{{

# _compile_pipeline - compile from the repository configuration {{{
sub _compile_pipeline {
	my ($top, $platform) = @_;

	my $compiler = Genesis::CI::Compiler->new(top => $top);
	my $result   = $compiler->compile(provider => $platform);

	if (my $debug_dir = get_options->{'debug-dir'}) {
		_dump_debug_artifacts($debug_dir, $result, $platform);
	}

	return $result;
}

# }}}
# _manual_pipeline_notice - what the manual provider means, and the way off it {{{
#
# Names a command rather than a hand edit of the generated configuration,
# and only the providers that can compile a pipeline.
sub _manual_pipeline_notice {
	my @types = Genesis::CI::ProviderRegistry->compilable_providers();
	my $type  = @types == 1 ? $types[0] : '<type>';
	return boxed('Manual Pipeline', [
		"This pipeline uses the #C{manual} provider.  #C{pipeline-apply} has cut ".
		"the deployment branches and recorded the pipeline, and sets no hosted ".
		"pipeline: you propagate and deploy from your terminal.",
		'',
		'[[  >>#G{genesis propagate}',
		'[[  >>#G{genesis <env> deploy}',
		'',
		"To have Genesis set an automated pipeline instead, choose the provider ".
		"and apply again".(@types == 1 ? ':' : sprintf(", where #C{<type>} is one of %s:",
			join(', ', map {"#C{$_}"} @types))),
		'',
		"[[  >>#G{genesis config --set pipeline.provider.type $type}",
		'[[  >>#G{genesis pipeline-apply}',
		'',
		"An automated provider needs its own #C{pipeline.*} settings, its source ".
		"control, vault, locker and shuttle; see ".
		"#C{docs/ci/user/configuration-reference.md} in the Genesis repository.",
	]);
}

# }}}
# _refuse_branch_collisions - refuse where a branch name blocks a deployment branch {{{
#
# A branch named for the environment alone, from before deployments had
# branches of their own (D66), blocks <env>/<type>: git cannot hold both.
# It may carry several deployment types' commits, so retiring it leads.
sub _refuse_branch_collisions {
	my ($git, $remote, @branches) = @_;
	my @lines;
	for my $branch (@branches) {
		for my $hit ($git->branch_name_collisions($branch, remote => $remote)) {
			my $x     = $hit->{name};
			my $where = join(' and ', ($hit->{here} ? 'here' : ()),
				($hit->{remote} ? "on #C{$hit->{remote}}" : ()));
			my $on    = $hit->{remote} // 'origin';
			push @lines, sprintf(
				"#C{%s} cannot be created: the branch #C{%s} (%s) is in the way, since git ".
				"cannot hold both.\n\n".
				"#C{%s} is probably a per-environment branch from before each deployment ".
				"had its own, and it may carry several deployment types' commits, which ".
				"#C{%s} must not inherit.  Delete it once nothing uses it, and the apply ".
				"cuts #C{%s} afresh for propagate to fill:\n\n".
				"[[    >>#C{git branch -D %s}\n[[    >>#C{git push %s :%s}\n\n".
				"Or, where it only ever carried this deployment's commits, rename it:\n\n".
				"[[    >>#C{git branch -m %s %s}\n[[    >>#C{git push %s :%s}\n".
				"[[    >>#C{git push -u %s %s}",
				$branch, $x, $where, $x, $branch, $branch,
				$x, $on, $x,
				$x, $branch, $on, $x, $on, $branch);
		}
	}
	bail({exitcode => CONFIG}, "%s\n\nNothing was written.", join("\n\n", @lines)) if @lines;
	return;
}

# }}}
# _apply_init_branches - create every missing deployment branch {{{
#
# This command is the only creator of a deployment branch, and the branch has
# one shape, which is an orphan whose root commit adds a single init file and
# carries [ci skip], so the pipeline's git resource registers the head as a
# version and skips the commit.  The first commit it does not skip is the seed
# the propagate run delivers later.
#
# Both sides are asked whether the branch is there, because they answer
# differently and each answer means something.  A branch the remote carries
# is left exactly as it stands, whatever the clone holds.  A branch the clone
# holds and the remote lacks is published rather than refused, since the
# creation would refuse to recreate it and the operator would be left with a
# branch that never reaches anybody else.
#
# Every question and every write names the remote source_control_remote
# finds by the repository it points at, or the clone's own pin, because that
# is where the repository's branches live.  Reading whichever remote git happens
# to list first would ask the wrong repository on a clone that has two, and
# git lists them alphabetically rather than in the order the operator added
# them.
#
# The publish goes through push_append_only, so a tip that would rewrite what
# the remote already carries is refused by name instead of being force-pushed
# or swallowed.
#
# The preview is the same stage asking the same two questions and making
# neither write, so a dry run reports the branches it would cut and the ones
# it would publish and leaves the clone and the remote as it found them.
sub _apply_init_branches {
	my ($top, $git, %opts) = @_;

	# A dry run without a remote (D118) reads the clone alone: nothing stands
	# on a remote it has not got.
	my $remote = !($opts{dry_run} && defined $top->source_control_problem);

	# The command names itself and what it has not written yet, because the
	# refresh defaults its wording to propagate and would otherwise tell the
	# operator to re-run a command they never ran.
	$top->fetch_pipeline_envs($git,
		command => 'pipeline-apply',
		outcome => 'No branch was created and no pipeline was set.') if $remote;

	# Asked of every branch before any is written, so a run that would stop
	# part way never starts, and the dry run reports what the run would hit.
	my @branches = map {$top->branch_for($_)} @{$top->pipeline_topology->{order}};
	_refuse_branch_collisions($git, $remote, @branches);

	my %report = (created => [], published => [], standing => []);
	for my $name (@{$top->pipeline_topology->{order}}) {
		my $branch = $top->branch_for($name);

		if ($remote && $git->remote_branch_exists($branch)) {
			info("  #Ki{already standing} #C{%s}", $branch);
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
				$git->push_append_only($branch);
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
				message => Genesis::CI::Marker::seed_subject($branch),
			);
			$git->push_append_only($branch);
			info("  #G{created} #C{%s}", $branch);
		}
		push @{$report{created}}, $branch;
	}

	return \%report;
}

# }}}
# _protection_rules_for - derive one branch's protection from decided state {{{
#
# The protection is derived from state the repository has already decided and
# one key, so nothing here is configured twice.  Control and every deployment
# branch block force pushes and require linear history, which is what makes
# the append-only rule enforceable rather than a convention Genesis observes
# on its own side.  A deployment branch requires a pull request where its
# require_pr is true, and control where control_requires_pr is true, whose
# default is false.  Rebase is the only merge method into a deployment branch,
# so the merger never gets the chance to rewrite the aggregate commit's
# message and lose its marker, while control keeps squash or rebase because
# user pull requests carry no markers.  Nothing here dismisses a stale
# approval, because review safety lives in the mechanism and an approval has
# to survive the rebuild a later run pushes.
#
# allowed_merge_methods is a parameter of GitHub's pull_request rule, and that
# rule type requires a pull request before merging, so asking for rebase-only
# on a branch that takes direct pushes would stop them.  The protection serves
# "a PR-only site and a lab that pushes directly" both, so the rule is gated
# on require_pr the way control's is gated on control_requires_pr.  Nothing is
# lost where it is off.  non_fast_forward and required_linear_history already
# keep history unrewritten and every commit fast-forward on every branch, and
# the marker rebase-only protects can only be lost by squashing a pull
# request, which a branch in no PR mode does not have.  The recovery covers a
# pull request opened into such a branch by hand, taking the marker from the
# pull request's body.
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
		} if $top->control_requires_pr;
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
# send, and whether it is to send them at all.  Under a preview it names each
# branch and the settings that branch would be given, and asks the repository
# for nothing.
sub _apply_branch_protection {
	my ($gh, $owner_repo, %opts) = @_;

	my %missing;
	for my $spec (@{$opts{branches} || []}) {
		my %ruleset = (
			name     => sprintf('genesis-%s', $spec->{branch}),
			target   => 'branch',
			patterns => [$spec->{branch}],
			rules    => $spec->{rules},
		);

		# A dry run reads what stands and sends nothing, so nothing can be
		# reported missing and the preview leaves the missing set empty.
		if ($opts{dry_run}) {
			my $change = $gh->ruleset_change($owner_repo, %ruleset);
			if ($change->{outcome} eq 'created') {
				info("  #Y{would protect} #C{%s} with %s",
					$spec->{branch},
					join(', ', map {$_->{type}} @{$spec->{rules} || []}));
			} else {
				_report_protection($spec->{branch}, $change, 1);
			}
			next;
		}

		my ($ok, $reason, $change) = $gh->set_ruleset($owner_repo, %ruleset);
		if ($ok) {
			_report_protection($spec->{branch}, $change, 0);
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
# _report_protection - say what the protection found and did for one branch {{{
sub _report_protection {
	my ($branch, $change, $dry_run) = @_;

	if ($change->{outcome} eq 'unchanged') {
		info("  #Ki{already protected} #C{%s}", $branch);
	} elsif ($change->{outcome} eq 'created') {
		info("  #G{protected} #C{%s}", $branch);
	} else {
		my @what = (
			(map {"adding $_"}   @{$change->{added}   || []}),
			(map {"removing $_"} @{$change->{removed} || []}),
			(map {"changing $_"} @{$change->{changed} || []}),
		);
		info("  %s #C{%s}%s",
			$dry_run ? '#Y{would update protection on}' : '#G{updated protection on}',
			$branch, @what ? ', '.join(', ', @what) : '');
	}
}

# }}}
# _apply_records - write what the apply learned to exodus {{{
#
# The writes are split across two owners, because the deploy rewrites its own
# exodus record on every run and would clobber anything the apply left beside
# it.  The pipeline's own facts go to Genesis::Top's path, and each
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

	# A record that cannot be read is answered as absent, so the writing run
	# writes it and the dry run says it would.
	my $had = eval {$top->applied_record} || {};
	my @moved = (
		(($had->{control_commit} // '') ne $opts{control_commit}
			? sprintf('moving control from #C{%s} to #C{%s}',
				substr($had->{control_commit} // '', 0, 8), substr($opts{control_commit}, 0, 8))
			: ()),
		(($had->{provider} // '') ne ($opts{provider} // '')
			? sprintf('moving the provider from #C{%s} to #C{%s}',
				$had->{provider} // '', $opts{provider} // '')
			: ()),
	);
	if (!%$had) {
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
	} elsif (!@moved) {
		info("  #Ki{already recorded} the applied pipeline at #C{%s}",
			$top->applied_record_path);
	} elsif ($opts{dry_run}) {
		info("  #Y{would update} the applied pipeline, %s", join(', ', @moved));
	} else {
		$top->applied_record(
			control_commit => $opts{control_commit},
			provider       => $opts{provider},
		);
		info("  #G{updated} the applied pipeline at #C{%s}, %s",
			$top->applied_record_path, join(', ', @moved));
	}

	# One pass over the topology computes each environment's set and writes
	# it, in the order the walk itself reads, so the report reads top down.
	# Each record goes beside that environment's own exodus record, and the
	# absence of that subpath is the membership test the walk uses in place of
	# a roster, so an environment this loop never reaches carries none and
	# reads as one the applied record does not know.
	for my $name (@{$top->pipeline_topology->{order}}) {
		my $env = eval {$top->load_env($name)};
		my ($deps, $complete) = ([], 0);

		if ($env) {
			($deps, $complete) = $env->dependency_set;
		} else {
			# An environment that will not load is the same case as one that
			# will not render, and both are answered with a warning and an
			# incomplete mark rather than a refusal.  A failure here costs the
			# manifest and nothing else, so the declared half is still read,
			# and only the discovered half goes missing.
			#
			# Both the declared read and the record write go through a bare
			# environment, which resolves the whole of genesis.pipeline and
			# the record's own address on the merged hierarchy with no kit.
			# The record is written even so, because an environment
			# carrying none at all reads as one the apply never reached.
			# The bare read is not guarded: the configuration load has
			# already merged and validated every environment's files, so a
			# failure here is no environment's and is left to stop the run.
			my $load_err = $@;
			$env  = Genesis::Env->bare($name, $top);
			$deps = [$env->_declared_dependencies];

			warning(
				"Could not load #C{%s}, so only its declared dependencies ".
				"are wired: %s\n".
				"Re-run #C{genesis pipeline-apply} once it loads.",
				$name, one_line($load_err)
			);
		}

		# The set was computed above whichever way this run is going, so a
		# dry run reports what it counted and only the write is withheld.
		my $discovery = $complete ? 'complete' : 'incomplete';
		my $counted   = sprintf("#C{%s} with %d dependenc%s%s",
			$name, scalar(@$deps), (@$deps == 1 ? 'y' : 'ies'),
			($complete ? '' : ' #Y{(discovery incomplete)}'));
		my $was = eval {$env->pipeline_record};
		my @was = $was ? (
			(join(',', @{$was->{dependencies} || []}) ne join(',', @$deps)
				? sprintf('was %d: %s', scalar(@{$was->{dependencies} || []}),
					join(', ', @{$was->{dependencies} || []}) || 'none')
				: ()),
			($was->{discovery} ne $discovery
				? "discovery was $was->{discovery}" : ()),
		) : ();

		if ($was && !@was) {
			info("  #Ki{already recorded} %s", $counted);
			next;
		}
		if ($opts{dry_run}) {
			info("  #Y{%s} %s%s", $was ? 'would update' : 'would record',
				$counted, @was ? ' ('.join('; ', @was).')' : '');
			next;
		}

		$env->pipeline_record(dependencies => $deps, discovery => $discovery);
		info("  #G{%s} %s%s", $was ? 'updated' : 'recorded',
			$counted, @was ? ' ('.join('; ', @was).')' : '');
	}

	return 1;
}

# }}}
# _refuse_disabled_pipeline - refuse to apply a pipeline nobody declared {{{
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
# _root_environments - the deployment root's environments, in DAG order {{{
#
# Both hold commands have a form with no environment argument, over the
# deployment root and not the repository, because two roots can share an
# environment name and holding the wrong `prod` would be worse than holding
# nothing.  The topology is the same enumeration the walk reads, so the run
# and the two commands never disagree about what the root holds.
#
# pipeline_topology answers every field empty where no environment file
# declares one, so an empty order is the one state worth a sentence, since a
# command that silently held nothing would read as success.  A disabled
# pipeline empties it too, but both callers refuse that first in its own words
# (D64, noted 2026-10-13), so the sentence names the one cause left.
sub _root_environments {
	my ($top) = @_;

	my @envs = @{$top->pipeline_topology->{order} || []};
	bail(
		{exitcode => CONFIG},
		"No environments with pipeline metadata were found in this ".
		"deployment root: no environment file here declares a ".
		"#C{genesis.pipeline} block."
	) unless @envs;
	return @envs;
}

# }}}
# _get_top - create Genesis::Top, optionally skipping vault {{{
sub _get_top {
	my ($opts, %defaults) = @_;

	my $skip = $opts->{'skip-vault'} || $defaults{skip_vault};
	if ($skip) {
		return Genesis::Top->new('.', no_vault => 1);
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
# _preview_shape - read the shape a preview shows, under its banner {{{
sub _preview_shape {
	my ($top) = @_;
	my $ref = get_options->{from};
	my $where;
	if (defined $ref) {
		$top->read_shape_from($ref);
		my $short = substr($top->shape_commit, 0, 7);
		info("Reading the pipeline's shape from #C{%s} at #C{%s}, not from control.",
			$ref, $short);
		return if $top->pipeline_enabled;
		$where = "at #C{$ref} (#C{$short})";
	} else {
		$top->read_shape_from_worktree;
		_refuse_no_pipeline($top) unless $top->config->is_set('pipeline');
		_worktree_banner($top);
		return if $top->pipeline_enabled;
		$where = 'in the working tree';
	}

	output("The pipeline is disabled %s: #C{pipeline.enabled} is not true in ".
		"its #C{.genesis/config}.", $where);
	exit 0;
}

# }}}
# _concourse_compile - the compile a command that works a live Concourse pipeline makes {{{
sub _concourse_compile {
	my ($top, $command) = @_;
	bail({exitcode => CONFIG},
		"Refusing to run #C{genesis %s}: the pipeline is not enabled, so there is no ".
		"live pipeline to work.  Set #C{pipeline.enabled true}, then run ".
		"#C{genesis pipeline-apply}.", $command)
		unless $top->pipeline_enabled;
	my $type = $top->pipeline_provider_type // 'manual';
	bail({exitcode => CONFIG},
		"Refusing to run #C{genesis %s}: it works a Concourse pipeline, and this ".
		"pipeline's provider is %s.", $command, $type)
		unless $type eq 'concourse';
	$top->pipeline_topology; # the prior_env graph is refused here, by name
	return _compile_pipeline($top, 'concourse');
}

# }}}
# _refuse_no_pipeline - a preview of a repository that configures no pipeline {{{
sub _refuse_no_pipeline {
	my ($top) = @_;
	my $v2 = ($top->config->get('version') // '') eq '2';
	bail({exitcode => CONFIG},
		"No pipeline is configured: #C{.genesis/config} has no #C{pipeline} section, ".
		"so there is nothing to preview.%s",
		$v2
			? "  This repository's configuration is version 2, which takes no ".
			  "pipeline; move it to version 3 with #C{genesis config --set version 3}, ".
			  "then configure the pipeline with #C{genesis config --set pipeline.<key> <value>}."
			: "  Configure one with #C{genesis config --set pipeline.<key> <value>}, ".
			  "starting with #C{pipeline.enabled true}.");
}

# }}}
# _worktree_banner - name each gap between the previewed tree and control on T {{{
sub _worktree_banner {
	my ($top) = @_;
	my $gaps    = $top->worktree_gaps;
	my $control = $top->control_branch;
	my $the     = sub {$_[0] == 1 ? 'the commit' : "the $_[0] commits"};

	my @lines;
	push @lines, sprintf("#Y{This preview assumes the uncommitted changes to }#C{%s}#Y{ are committed.}",
		join(', ', @{$gaps->{uncommitted}})) if @{$gaps->{uncommitted}};
	push @lines, sprintf("#Y{This preview assumes }#C{%s}#Y{ is merged into }#C{%s}#Y{.}",
		$gaps->{branch}, $control) if $gaps->{branch};
	push @lines, sprintf("#Y{This preview assumes %s on }#C{%s}#Y{ %s pushed.}",
		$the->($gaps->{ahead}), $control, $gaps->{ahead} == 1 ? 'is' : 'are') if $gaps->{ahead};
	push @lines, sprintf("#Y{This preview does not include %s on }#C{%s}#Y{ that this tree lacks.}",
		$the->($gaps->{behind}), $gaps->{tracking}{ref}) if $gaps->{behind};
	if (my @failed = $top->control_config_problems) {
		push @lines, sprintf("#Y{Control at }#C{%s}#Y{ fails the configuration checks, so this ".
			"preview does not read it:}%s", substr($gaps->{tracking}{commit} // '', 0, 7),
			join('', map {"\n[[".bullet('', inline => 1, indent => 2).">>$_"} @failed));
	}
	return unless @lines;

	my $t = $gaps->{tracking};
	warning(join("\n",
		sprintf("#Y{This preview reads the working tree of }#C{%s}#Y{, not control on the remote.}%s",
			($top->git->prefixed(''))[0] || './',
			$t ? sprintf("  #C{%s} at #C{%s}, as last fetched, is what a real apply reads.",
				$t->{ref}, substr($t->{commit}, 0, 7)) : ''),
		'', @lines, '',
		"A real apply reads only what is committed and in step with the remote, so ".
		"what follows is what it would set once that is true."));
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
# pipeline-describe opens with the resolved source-control values, so an
# override that has drifted away from what git says is visible rather than
# silent.  Genesis::Top resolves them and says which tier each came from; this
# only lays them out.
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

	my $name = $top->pipeline_name || $top->type;
	my $provider_type = $top->pipeline_provider_type // 'manual';
	output "\n#G{Pipeline}: #C{%s}", $name;
	output "  #Yi{Provider}: %s", $provider_type;
	if ($provider_type eq 'concourse') {
		# Reported, never refused: a describe says what is missing (D86).
		my $found = $top->pipeline_provider->target_found;
		output "  #Yi{Target}: %s", defined $found->{target}
			? "#C{$found->{target}} ($found->{how})"
			: '(none): ' . (split /\n/, $found->{refusal} // '')[0];
	}
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
		# An automated provider deploys an environment on its branch unless it
		# is manual (contract c1); under the manual provider nothing does.
		push @flags, $node->{manual} ? '#Y{manual}' : '#G{automatic}'
			if $node->{manual} || $provider_type ne 'manual';
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
# _concourse_target - the fly target a command talks to {{{
sub _concourse_target {
	my ($result, $opts) = @_;
	return $opts->{target} // $result->{provider}->resolve_target;
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

Compile pipeline and print a Mermaid flowchart, or write it to the file
C<--output> names.
Where the repository configures a pipeline, the flowchart is drawn from
the environment files and no provider is compiled for at all.

=item B<pipeline-describe>

Print a human-readable ordered progression.  Where the repository
configures a pipeline, the report opens with the resolved source-control
values and the tier each of them came from, so an override that has
drifted away from what git says can be seen.  Where it configures none,
the legacy configuration is compiled first and the progression is read
off the compiled result, so the command prints in either case.

=item B<pipeline-diff> [--from REF] [--target TARGET]

Compare the pipeline compiled from the working tree, or REF, against the live
pipeline via C<fly get-pipeline>, as data through C<spruce diff>.

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
