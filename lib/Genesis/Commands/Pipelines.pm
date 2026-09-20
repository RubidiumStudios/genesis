package Genesis::Commands::Pipelines;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Commands;
use Genesis::Exit qw/CONFIG ABORTED TEMPFAIL/;
use Genesis::Config;
use Genesis::Top;
use Genesis::Env;
use Genesis::CI::Legacy qw//;
use Genesis::CI::Compiler;
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
use Service::Github;
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

	# A pipeline nobody declared is refused first, because the command applies
	# a configured pipeline and never enables one.  The refusal reads
	# .genesis/config raw and builds no Genesis::Top of its own, so it lands
	# ahead of the vault connection _get_top makes.  The dispatch gate already
	# holds a handle built without a vault, so this is only the first read
	# that could ask for one.  A repository with no pipeline has no reason to
	# hold a vault, and bailing on the vault first would name the wrong thing.
	_refuse_disabled_pipeline();

	my $top = _get_top($opts);

	# --platform is gone, so the provider is the one the repository is
	# configured for and nothing else, and an absent type is the manual
	# provider.  The refusal above has already turned away the repository that
	# declares no pipeline at all, so what reaches here is a pipeline the
	# operator enabled and chose a provider for.
	my $platform = $top->pipeline_provider_type // 'manual';

	my $git = Service::Git->new('.');

	# The propagate run has a preview that writes nothing of its own, and a
	# preview worth reading follows the same rule everywhere.  The flag is
	# read once here and handed to every stage below, so no stage has to reach
	# into the options for itself and none of them can disagree about what a
	# dry run is.
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

	# The branch work belongs to every provider and the pipeline work to the
	# automated ones alone, so the branches are made before the provider is
	# asked for anything.  A manual repository still delivers through these
	# branches, and the operator deploys from their own terminal.
	#
	# This sits ahead of every exit the compile and the provider stages
	# make, --output-dir included, so a run that only means to write the
	# compiled artifacts out still creates and publishes any deployment
	# branch the remote lacks.  A dry run reports the same branches and
	# writes none of them.  The POD says so where each option is described.
	_apply_init_branches($top, $git, dry_run => $dry_run);

	# The repository is asked to enforce the append-only rule Genesis observes
	# on its own side, because Genesis cannot prevent a rewrite it does not
	# perform and a rewrite that drops a commit leaves every marker naming it
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

	# The pipeline's own facts are recorded once the branches are in place,
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
		# The prerequisites check is the provider's and the emitting is the
		# compiler's.  They were one object and one of them was answering for
		# the other.
		my $provider = $result->{provider};
		my $compiler = $result->{compiler};

		if ($opts->{'dry-run'}) {
			my $yaml = $output->{'pipeline.yml'}
				or bail("Concourse provider did not produce pipeline.yml");
			output({raw => 1}, $yaml);
			exit 0;
		}

		$provider->check_prereqs() or exit 86;

		my %deploy_opts = %{ $compiler->normalize_provider_opts(
			$result->{provider_cli_opts} || {}
		) };
		$deploy_opts{target}          //= $opts->{target} // $layout // $name;
		$deploy_opts{pause_after_set} //= $opts->{paused};
		$compiler->deploy(%deploy_opts, yes => $opts->{yes});

	} elsif ($platform eq 'github-actions') {
		# No run reaches this arm today, because the provider registry
		# refuses the type before the dispatch is asked about it.  It is
		# kept as the seam the provider class for GitHub Actions lands
		# in, so a reader can see the shape the dispatch takes when a
		# second platform arrives.
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

	my $top = Genesis::Top->new('.');

	# An applied record standing while pipeline.enabled is false means the
	# configuration disowns a pipeline that is still live, still watching its
	# branches, and still deploying.  Every pipeline command refuses that
	# repository, this one included, and it refuses above everything else, so
	# nothing of the report reaches standard output ahead of the refusal.
	Genesis::CI::Preflight::assert_not_disowned($top,
		command => 'pipeline-status');

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
# The refusal of a disowned pipeline is the group's and not ours, and the
# legacy gate runs before we are reached, so there is no third refusal here on
# pipeline.enabled saying what those two already say.
sub pipeline_hold {
	my @args = @_;
	my $opts = get_options();
	my $top  = _get_top($opts);

	Genesis::CI::Preflight::assert_not_disowned($top,
		command => 'pipeline-hold');

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
# The refusal of a disowned pipeline belongs to the group and not to us, as it
# does for the hold, and the legacy gate runs before we are reached, so there
# is no third refusal here on pipeline.enabled.
sub pipeline_release {
	my @args = @_;
	my $opts = get_options();
	my $top  = _get_top($opts);

	Genesis::CI::Preflight::assert_not_disowned($top,
		command => 'pipeline-release');

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
#
# The run stands itself on control, refreshes, settles every deployment
# branch, and then walks control once per environment, from the marker that
# environment's branch carries to control's own tip.  A branch that carries no
# marker has never been delivered to, and it is walked from the commit that
# introduced the environment instead, which is routed and held like any other.
# Each commit that touches the environment's set is delivered on its own, in
# control order, as one commit on the deployment branch.
#
# The run takes no argument and sources control's tip, always.
sub propagate {
	# The <env> argument retired together with the cascade it scoped, because
	# one run walks every environment and a commit held behind an ancestor is
	# released by the next bare run rather than by a run aimed at it.  A
	# caller that still passes one is told so, rather than having it quietly
	# ignored.  Nothing below can see an argument from here on, so the cascade
	# the variable feeds is unreachable until the walk replaces it.
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
	Genesis::CI::Preflight::assert_not_disowned($top, command => 'propagate');
	# The gate is the deploy's as well, so it lives beside the other shared
	# refusal and takes this run's words for what the pipeline owns from its
	# defaults.  --dry-run is passed by the name the gate reads it under,
	# because the option's own spelling is this command line's and not a
	# fact about the gate.
	Genesis::CI::Preflight::assert_provider_gate($top, $opts,
		dry_run => $dry_run);

	my $git     = Service::Git->new('.');
	my $control = $top->control_branch;

	# The run's first stage begins here, and control is its first question,
	# because the topology is read from control and a control nobody refreshed
	# makes every later answer worthless.  It stands ahead of the branch
	# check, since a branch that exists nowhere is not one the operator can be
	# asked to stand on.
	#
	# The refresh brings R into T for every branch in scope, control included,
	# before the first read of any of them.  There is no flag, because a
	# report that quietly rested on a stale tracking ref is the thing this
	# removes.
	my $refreshed = $top->fetch_pipeline_envs($git, command => 'propagate');
	# The stage's events are not printed here.  The whole list is printed
	# once, where the deployment branches are settled, and a line printed
	# twice is worse than a line printed late.
	#
	# A preview is let past a control branch that is ahead of its remote, and
	# warns under its own banner that its answer assumes the push, which is
	# the preview's first caveat.  Every other divergence is refused here for
	# a preview as it is for a run, because a stale control makes the topology
	# the preview reports on the wrong one.
	my $control_state = Genesis::CI::Preflight::require_control($top, $git,
		refreshed    => $refreshed,
		command      => 'propagate',
		permit_ahead => $dry_run ? 1 : 0);

	# The run stands itself on control rather than asking the operator to.
	# Everything below reads the environment files off the working tree, so
	# the switch is what makes a run from a feature branch read the same
	# topology as a run from control, and finish puts the operator back on the
	# branch they started from.
	#
	# The clean-tree refusal that stood beside the branch refusal has moved
	# rather than gone.  It now lives in the session's own begin, which names
	# the files it found, and it is the same guard stated in one place.  It
	# applies to a dry run as it does to a writing one, because a dry run
	# switches to control like any other run and the clean assertion sits on
	# the switch.

	# The pull request branch of every environment is named once, before the
	# session opens, because pr_branch_for refuses a prefix that collides
	# with a deployment branch or with control and that refusal exits CONFIG.
	# Raised below the switch it would die inside the run's own eval, where
	# the named exit becomes a bare 1 and the operator is told nothing about
	# the key they have to change.
	#
	# The topology is read once for the whole loop rather than once per
	# environment, because building it walks every environment file.
	#
	# This reading is the working tree's, and a run started from a feature
	# branch reads that branch's environment files rather than control's, so
	# the same question is asked a second time below once the session has
	# stood the run on control.  Neither reading is redundant: the first is
	# what keeps the exit named for a repository whose control is checked
	# out, and the second is what catches a collision that exists only in
	# control's files.
	#
	# The environment names go in with each ask, because the refusal compares
	# the composed branch against every deployment branch in the pipeline and
	# would otherwise build a topology of its own for each environment it is
	# asked about.
	my $pr_topology = $top->pipeline_topology;
	my @pr_names    = keys %{$pr_topology->{nodes}};
	$top->pr_branch_for($_, envs => \@pr_names) for grep {
		$pr_topology->{nodes}{$_}{require_pr}
	} @{$pr_topology->{order}};

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

	# The collision, asked again on control's own files.  The pre-session
	# reading above answers about whatever branch the operator was standing
	# on, so a prefix that collides only in control's files would otherwise
	# reach pr_branch_for inside the walk, where its named exit becomes a
	# bare 1.  The refusal goes through the closure, which closes the session
	# first, so the operator is back on their branch and the exit survives.
	#
	# What it composes is kept, because the pre-flight below wants the same
	# names and asking a second time rebuilds the topology once per
	# environment.  The message it caught is quoted through bail_text: a bail
	# raised inside an eval arrives already bannered and already wrapped, and
	# re-raising it whole put a second [FATAL] in the middle of a paragraph.
	my %pr_branch_of;
	my @control_names = keys %{$topo->{nodes}};
	for my $env_name (grep {$topo->{nodes}{$_}{require_pr}} @dag_order) {
		my $pr_branch = eval {
			$top->pr_branch_for($env_name, envs => \@control_names)
		};
		$refuse->({exitcode => CONFIG}, "%s", bail_text($@))
			unless defined $pr_branch;
		$pr_branch_of{$env_name} = $pr_branch;
	}

	# The rest of the first stage, now that the topology is known.  Every
	# refusal below is collected before anything is written, so a run that
	# stops here has left nothing partial behind.  It classifies the whole DAG
	# rather than the cascade's scope, because the initial state is a property
	# of the repository and not of the run, and it stands ahead of the
	# creation guard further down, which makes a deployment branch the remote
	# has never had and never publishes it, and so builds the very shape the
	# first of the two refusals below exists to refuse.
	my $initial = Genesis::CI::Preflight::initial_state($top, $git,
		envs      => \@dag_order,
		refreshed => $refreshed,
		control   => $control_state,
		command   => 'propagate',
		dry_run   => $dry_run);
	info("  #Gi{%s}", $_) for @{$initial->{events}};

	# The cascade is retired, so the run always sources control's own tip.
	# What each environment receives is decided commit by commit by the walk,
	# from the marker its own branch carries, rather than by one diff taken
	# against that tip.  Collapsing everything outstanding into one diff made
	# an urgent change to one environment wait behind an unrelated earlier
	# change to a shared file.
	#
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

	# The fourth reading, said once for the repository.  An applied record
	# that is absent is legitimately absent until genesis pipeline-apply has
	# run, so the run reads it rather than refusing over it, and it says which
	# reading it took, because a reading nobody prints is one the operator
	# cannot act on.
	warning(
		"The pipeline has never been applied to this repository, so every ".
		"environment reads #C{not-propagated}.  Run #C{genesis ".
		"pipeline-apply} to record the commit it was applied from."
	) unless $state->{applied};

	info "\n#G{Propagating from} #C{%s} #G{@} #C{%s}",
		$control, $control_short;

	# The run's one GitHub client, and the only one this command builds.  It
	# is built where an environment in scope needs the API and not at all
	# where none does, so a repository that delivers to nobody by pull request
	# makes no call on a job that runs on every control change.
	#
	# Everything the build decides, refuses, and warns about lives in
	# client_for_run, and the refusal goes through the run's own closure so
	# the operator is back on their branch before they are told why it
	# stopped.
	#
	# The records the decision reads are composed here rather than taken from
	# the walk, because the walk is below this and wants the client itself,
	# since an environment whose merge dropped the marker takes it back from
	# the pull request that merged.  Each one carries the pull request branch
	# this environment's own policy asked for, seeded from the names composed
	# above, which is what the walk seeds its own record's pr from, so the two
	# readings cannot disagree about which environments would deliver into a
	# pull request.  The proposed record is the walk's to read, and an
	# environment that would not deliver into a pull request has no use for
	# the client that a stale proposal of its own could give it.
	my @in_scope = map {{
		env       => $_,
		branch    => $top->branch_for($_),
		pr_branch => $pr_branch_of{$_},
	}} grep {$topo->{nodes}{$_}{require_pr}} @dag_order;

	# The review refusal, read once for the whole run and ahead of it.  What a
	# reviewer decided is what decides whether an environment's pull request
	# branch is rebuilt or frozen, so a run that cannot read it cannot know
	# what it would do with any of them, and it refuses rather than guess.
	#
	# The read stands here rather than beside the arm for two reasons.  The
	# refusal is whole-run, so it has to happen before the first environment
	# is written; and a refusal raised inside the eval below comes back out of
	# the abort as a bare 1, where this one earns UNAVAILABLE.  It goes
	# through the run's own refusal closure, so the operator is put back on
	# the branch they started from before they are told why it stopped.
	#
	# The two branch names are composed from the same accessors the walk
	# composes its record from, so the state read here and the record the arm
	# is handed cannot disagree about which branches an environment owns.
	#
	# The pair the client was built against comes back beside it, for the
	# pull request sync at the end of the run.  The walk takes the client
	# alone and never the pair, because the recovery reads the merged pull
	# requests out of the answer this run already has.
	my ($github, $owner_repo, $pr_state) =
		Genesis::CI::PullRequest::state_for_scope($top,
			envs   => \@in_scope,
			refuse => $refuse);
	my %pr_state_of = %$pr_state;

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
	# what answers it.  The partial write is named and discarded, every branch
	# this session committed to goes back to where the remote has it, and the
	# operator is put back on the branch they started from.
	#
	# The walk is inside it rather than in an eval of its own.  A walk that
	# cannot read what it needs ends the run exactly as a delivery that cannot
	# write does, under the same two failure classes, and two evals reading
	# the same error two ways is how the two come to disagree about a status.
	my $ran = eval {
		# The walk reads durable state and writes nothing at all.  Everything
		# it decides stands in the record, and the delivery below is the only
		# thing here that touches a branch.
		#
		# The client and the state read above go in with it, because a
		# deployment branch whose merge dropped the marker takes it back from
		# the pull request that merged, and that pull request is in the answer
		# this run already has.
		$record = Genesis::CI::Walk::plan($top,
			git        => $git,
			state      => $state,
			branches   => $initial->{branches},
			github     => $github,
			state_of   => \%pr_state_of,
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
			# An environment that delivers into a pull request is loaded
			# whether or not anything is due for it, because the arm is
			# asked either way and a branch or a proposed record left over
			# from a pull request that has since merged is its to retire.
			next unless @{$env_record->{pending}}
				|| $topo->{nodes}{$env_record->{env}}{require_pr};
			$env_of{$env_record->{env}} = $top->load_env($env_record->{env});
		}

		for my $env_record (@{$record->{environments}}) {
			my $env_name = $env_record->{env};
			$at = $env_name;

			# The second stage as the walk already resolved it.  An error the
			# walk confined to this environment is this environment's outcome,
			# and it is named as one rather than as a warning standing beside
			# the report, because I8 asks that every environment in scope end
			# with an outcome and a warning is not one.  The walk wrote failed
			# on the record as it caught the error, and the report carries the
			# error beneath it.
			#
			# It is read ahead of the branchless check below, because an
			# environment can be in both states at once and only one of the
			# two answers is worth printing.  The walk loads the environment
			# before it decides anything else, so an environment with no
			# branch that also fails to load arrives here failed, with the
			# error under it, and the wait for the apply written over that
			# would send an operator to a command that reads the same file
			# and fails on it again.
			next if $env_record->{error};

			# The environment takes the awaiting outcome here.  genesis
			# pipeline-apply is the one command that cuts a deployment branch,
			# so the run carries on past the environment without writing, and
			# the report says what it is waiting for.  Nothing is decided
			# here, because a run and a preview that decided it separately are
			# two outputs that can disagree about a word.
			next unless $initial->{branches}{$env_name};

			# The pull request arm starts here.  An environment whose
			# repository policy says its branch may only receive a proposal
			# takes its delivery on the pull request branch, and the commits
			# it is given are the same ones the direct arm would have
			# delivered.
			if ($topo->{nodes}{$env_name}{require_pr}) {
				my @pending = @{$env_record->{pending}};

				# The arm is asked even where nothing is due, because a
				# branch and a proposed record left over from a pull request
				# that has since merged are its to retire.
				my $env = $env_of{$env_name} ||= $top->load_env($env_name);
				Genesis::CI::Walk::walk_one(
					session => $session,
					record  => $env_record,
					writes  => $dry_run ? 0 : 1,
					deliver => sub {
						# The state the pre-flight read, handed to the arm
						# rather than fetched here, so the arm takes its
						# decision from the same answer the refusal above
						# already stood on.
						my $word = Genesis::CI::PullRequest::deliver(
							$session, $env_record,
							env     => $env,
							commits => \@pending,
							state   => $pr_state_of{$env_name},
							# A preview reads everything the run reads and
							# writes none of it, so the arm is told which
							# kind of run it is in rather than left to
							# cut a branch and commit onto it under one.
							dry_run => $dry_run,
						);
						# An environment with a hold standing over it is
						# left for the report to settle, which writes
						# held with the qualifier that says what it
						# waits for.  The arm answers idempotent for
						# anything with nothing due, and a word written
						# here takes _settle's first return and the
						# qualifier with it.
						$env_record->{outcome} = $word
							if defined $word && !(
								$word eq 'idempotent'
								&& @{$env_record->{held} || []});
					},
				);
				next if ($env_record->{outcome} // '') eq 'failed';

				# The arm's lease.  The expected tip is the one the arm read
				# before it rewrote anything, and the key is carried even
				# where it is undef, because _push_one reads it with exists
				# and a spec that dropped it would be pushed with no lease at
				# all.  An undef there is a branch the remote has never had,
				# which leases the empty object name.
				push @publish_specs, {
					branch => $env_record->{pr}{branch},
					kind   => 'pr',
					env    => $env_name,
					expect => $env_record->{pr}{expected},
				} if !$dry_run && ($env_record->{pr}{action} // '') eq 'rebuild';
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

			# This is the run's second stage.  A delivery that dies halfway
			# ends this environment and nothing else: the branch goes back to
			# T so that no part of the delivery survives, the environment
			# records failed, and the run walks on to the next one.  A
			# run-fatal or unsurvivable failure is not caught, and it reaches
			# the run's own eval below, which aborts everything.
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

		# The removals, which are the pull request branches this run retires.
		# They are gathered once the walk is over rather than beside each arm,
		# because a removal is a push like any other and every push waits for
		# the whole walk to finish.
		push @publish_specs, Genesis::CI::PullRequest::_nothing_due_specs(
			git     => $git,
			records => $record->{environments},
		) unless $dry_run;

		# This is the run's third stage.  The publish is held to the end of
		# the walk, so a run that failed halfway has put nothing on the
		# remote.
		#
		# The push set is the deployment branches alone.  Control is the run's
		# input and never its output, so what the publish does with control is
		# read it once more before the first push and refuse where it has
		# moved.  It is named to the stage for that reading and for nothing
		# else.
		#
		# It is inside the session rather than after it, because a remote that
		# has gone away is an unsurvivable failure and the answer to one is
		# the abort.  A run that could publish nothing leaves nothing
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
					# The publish's ask arrives here.  The delta every push
					# would carry is shown either way, and this answers the
					# question that follows it.
					yes     => $opts->{yes},
					# The two shapes reach one reading.  git push failing to
					# run at all raises, and a remote nobody can resolve comes
					# back as a refused push per ref, so a run where nothing
					# landed and no result named a ref is the remote being
					# gone, where a run holding a result that landed or that
					# named a ref is those branches' own quarrel with it
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

				# What _write_trailer_holds reads, put on the record where
				# the publish settles it, so the writer takes one record
				# rather than arguments that can come to disagree about one
				# run.  It is all the writer needs, because the trailer's
				# own reason rides out on the delivered entry the walk
				# wrote.
				$record->{published} = $publish->{published} || [];
			}
		}

		# The pull request is opened or updated once its branch is on the
		# remote, because GitHub opens one from a branch the remote holds,
		# and a run whose push was refused has nothing to open one from.
		# The proposed record is written here for the same reason: it points
		# at a pull request, and until the branch publishes there is none to
		# point at.
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

	# The two failure classes, which are the errors no environment survives.
	# Both abort the same way and differ only in the status they exit with,
	# and both leave through here, because everything an environment could
	# survive was answered inside the walk and never reached this eval.
	Genesis::CI::Walk::abort_run(
		session => $session,
		record  => $record,
		envs    => \@dag_order,
		at      => $at,
		error   => $failure,
	) unless $ran;

	# The in-sync rule, answered a second time by the publish and spent here.
	# Control moving under the run leaves every marker the run wrote naming a
	# commit computed from a tip that has already moved, so the run refuses
	# rather than publishing it.  Nothing went to the remote and every branch
	# the run committed to is back where the remote has it, so the refusal
	# leaves the repository as it found it.
	#
	# The status is TEMPFAIL, because a code says whether an unaided retry
	# fixes the condition.  Nothing the operator wrote is wrong here.  Another
	# clone moved control while this run was walking, and the next run the
	# pipeline job cuts starts from a fresh clone, so it refreshes, walks from
	# what is there now, and succeeds with nobody doing anything first.  An
	# operator running from a clone of their own keeps a control branch a
	# commit behind, and the run there is refused for an illegal initial state
	# until they pull.  That is the rejected push this refusal resembles,
	# which is the same event on a different ref.
	$refuse->({exitcode => TEMPFAIL}, '%s', $publish->{refused})
		if $publish && $publish->{refused};

	# The walk is over, so the operator goes back on the branch they started
	# this run from, before a word of the summary is printed.  Nothing below
	# reads the working tree.
	$session->finish;

	# The hold sequence, spent here.  A commit that carries a hold trailer
	# sets the hold as it is delivered rather than as it is deployed, so the
	# write goes after the publish, which is what settles whether the delivery
	# landed, and before the report, which says what this run did.  A preview
	# publishes nothing and so writes nothing here either.
	_write_trailer_holds($top, $record) if $publish;

	# I8's three axes, printed once the run has finished writing.  Every
	# environment in scope carries one outcome, every routed control commit
	# one of its own, and every overwritten hand edit a third.  It is one
	# call rather than lines scattered through the walk, because
	# pipeline-status renders the same record through the same helpers and
	# two outputs composing one phrase twice are two that can disagree.
	#
	# The preview and the run's own report are one report, composed from one
	# record by one renderer, so the two cannot disagree about a word.  The
	# preview enters through its own sub because it has a banner and one verb
	# of its own, and everything under those is the run's.
	#
	# The preview's three caveats, gathered here and said by the report.
	# The run has already asked git every one of those questions, to decide
	# whether to refuse the control branch and to decide whether to reset or
	# to fast-forward a deployment branch, so the answers are read off what
	# those two stages settled rather than asked again.  The renderer prints
	# them under its banner, which is the only place a caveat about a
	# preview can stand and still be read before the report it is about.
	$record->{warnings} = _preview_warnings($git, $control, $control_state,
		$initial, \@dag_order) if $dry_run && $record;

	$dry_run
		? Genesis::CI::Report::render_preview($record, git => $git)
		: Genesis::CI::Report::render_run($record, git => $git);

	# The decline is read before the count, because a run the operator
	# stopped wrote its branches and then put every one of them back, and
	# what that earns is the sentence saying so rather than a count of
	# nothing.  A delivered count standing directly above a report that says
	# nothing was published is the one number in the run that contradicts
	# everything under it, and the operator who stopped the run is the last
	# person who should have to work out which of the two to believe.
	#
	# The count is read off the record here, once the publish has settled
	# every environment's outcome, so a branch the remote refused
	# contributes none of its commits.  Counting them where the walk routed
	# them said the run had delivered work the remote never took, directly
	# under a report saying it had not.
	#
	# A preview publishes nothing, so there is no publish to settle an
	# outcome and the word the count reads is the one the preview itself
	# wrote.  Genesis::CI::Report::render_preview puts would propagate on
	# every environment it routed commits to, and it has already run by the
	# time the count is taken, so the count asks that sub's own constant for
	# the word rather than spelling it here or reading the null the walk
	# left, which is no longer null by now.
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
		# A run that had something due and published none of it has said so
		# per environment already, and a line reading no changes on top of
		# that would be the second thing the operator has to choose between.
		info "\n#Yi{No changes to propagate.}";
	}

	# The decline, which is the one status the publish decides rather than the
	# run's second stage.  It is the number every shell user reads as the
	# person having stopped it, and it is spent here rather than beside the
	# ask so the operator reads the report of what the run wrote before they
	# read the status of the run they stopped.  Every branch that work went
	# onto is already back where the remote has it.
	exit ABORTED if $publish && $publish->{declined};

	# The run's second stage, decided in one place and spent here.  The run's
	# own status is the only thing a caller reads, so the reading is not
	# repeated beside the report.  The report says which environment ended
	# which way, and the sentence below says what the whole of that means for
	# the next run.  It names nobody, because naming an environment twice
	# sends an operator looking for two different problems.
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

	# The two moves the stage assumes rather than makes, each in the order
	# the topology gives, so an operator reads the caveats in the order the
	# report goes on to name the environments.
	my %kind_of = (
		reset          => 'unreset-branch',
		'fast-forward' => 'unmoved-branch',
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
# _verify_deployed - check that an env's propagated state was deployed {{{
#
# Compares the env branch HEAD against the git.commit field in the
# latest successful deployment's exodus audit data.  Requires vault.
# Warns and allows cascade if vault is unavailable.
sub _verify_deployed {
	my ($env_name, $env, $git) = @_;

	my $branch_head = $git->sha($env_name);

	# Vault access is required, and this soft-fails if it is unavailable
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
		# Pre-pipeline deployment (no git context in exodus), so warn only
		warning(
			"Environment #C{%s} was deployed before pipeline tracking was enabled.\n".
			"Cannot verify deployment state.  Ensure it has been deployed.",
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
	# The drawing is an emitted artefact, so it comes off the compiler.
	my $result   = _compile_pipeline($top, 'concourse');
	my $compiler = $result->{compiler};

	# A compile hands back a compiler and every compiler that emits a
	# Concourse pipeline defines graph_md, so there is nothing here to
	# ask about first.
	my $md = $compiler->graph_md();

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
	# The telling is an emitted artefact too, so it comes off the
	# compiler rather than off the provider beside it.
	my $result   = _compile_pipeline($top, 'concourse');
	my $ast      = $result->{ast};
	my $compiler = $result->{compiler};

	# A compile hands back a compiler and every compiler that emits a
	# Concourse pipeline defines generate_description, so there is
	# nothing here to ask about first.
	$compiler->generate_description($ast);
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
		info("#Y{Pipeline '%s' does not exist on target '%s', so there is ".
			"nothing to diff against.}",
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
### The Session {{{

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
#
# There is one configuration source, which is the pipeline section of
# .genesis/config, so there is no precedence to work through here and no
# legacy file to fall back to.  A leftover .genesis/ci/ directory is not read
# and is not named either, because a directory nothing consults is not worth a
# line of the operator's attention.
sub _compile_pipeline {
	my ($top, $platform) = @_;

	# Parse provider-specific CLI flags
	my %provider_cli_opts;
	{
		require Genesis::CI::ProviderCompiler;
		my @argv = ();
		Genesis::CI::ProviderCompiler->parse_cli_opts(
			\@argv, \%provider_cli_opts, $platform
		);
		for my $key (Genesis::CI::ProviderCompiler->cli_opt_keys($platform)) {
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
# Every question and every write names the remote that
# pipeline.source_control.remote resolves to, because that is the repository's
# own answer to where its branches live.  Reading whichever remote git happens
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

	# The derivation behind this bails on its own where it cannot settle a
	# name, so what comes back here is always a name.  Whether the clone has
	# a remote by that name is a separate question, and this is where it is
	# asked.
	my $remote = $top->source_control_remote;

	# R is the home of every deployment branch, so a repository with nowhere
	# to publish to is turned away before the first branch is written rather
	# than after it.  Creating one and then failing on the publish would leave
	# an orphan standing in the clone and would leave every environment behind
	# the first with nothing at all.  A remote the clone does not have is
	# configuration rather than a crash, so the refusal carries the
	# configuration code.
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
# pipeline_topology answers every field empty where the pipeline is disabled
# or where no environment file declares one, so an empty order is the one
# state worth a sentence, since a command that silently held nothing would
# read as success.  The sentence names both causes, because the two are
# indistinguishable from here and an operator whose pipeline is switched off
# would otherwise be sent to read their environment files.
sub _root_environments {
	my ($top) = @_;

	my @envs = @{$top->pipeline_topology->{order} || []};
	bail(
		{exitcode => CONFIG},
		"No environments with pipeline metadata were found in this ".
		"deployment root.  Either #C{pipeline.enabled} is false in ".
		"#C{.genesis/config}, or no environment file here declares a ".
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
# _concourse_fly_flags - derive (target, k_flag) from compiled result + CLI opts {{{
#
# Target resolution: explicit --target CLI opt > pipeline.provider.target config > pipeline name.
# k_flag is ' -k' when insecure is set, '' otherwise.
sub _concourse_fly_flags {
	my ($result, $opts, $name) = @_;
	# The resolved options are the compiler's, which is where
	# provider_option reads them through the provider it holds.  Both
	# derivations below move together, because the second one becomes the
	# -k flag and a rewrite that took only the first would drop it for
	# four commands.  A compile hands back a compiler and every compiler
	# inherits provider_option from Genesis::CI::ProviderCompiler, so
	# there is nothing here to ask about first.
	my $compiler = $result->{compiler};
	my $target   = $opts->{target}
		// $compiler->provider_option('target')
		// $name;
	my $insecure = $compiler->provider_option('insecure') // 0;
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
