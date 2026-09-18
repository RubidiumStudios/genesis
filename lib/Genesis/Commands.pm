package Genesis::Commands;

# TODO: Should this be a class with a registry of command objects?
# - define_command becomes new that adds the new command object to the class's
#   internal list of registered clommands
# - prepare_command changes to class method select to return sets the selected
#   command and register it as the selected command, and then add an instance
#   method for prepare.
# - commands becomes class method list
# - current_command becomes class method current
# - has_command becomes class method exists
# - everything else becomes an instant method (renaming to drop _command)
#
# Will explore once this is working.

use strict;
use warnings;

use base 'Exporter';
our @EXPORT = qw/
	commands
	define_command
	prepare_command
	set_top_path
	build_command_environment
	current_command
	current_command_alias
	known_commands
	run_command
	has_command
	is_equivalent_command
	equivalent_commands
	command_help
	command_usage
	show_global_options
	command_properties
	get_args
	get_options
	has_option
	option_defaults
	append_options
	has_scope
	check_embedded_genesis
	check_prereqs
	at_exit
/;

# Core Modules
use Getopt::Long qw/GetOptionsFromArray/;
use File::Basename qw/dirname basename/;
use Cwd qw/getcwd abs_path/;

use Genesis;
use Genesis::State;
use Genesis::Term qw/wrap terminal_width csprintf decolorize csize/;
use Genesis::Log;
use Genesis::Exit qw/CONFIG/;

our ($COMMAND, $CALLED, %RUN, %PROPS, %GENESIS_COMMANDS, @COMMANDS, @COMMAND_ARGS);
our $COMMAND_OPTIONS = {};
our $END_HOOKS = [];

use constant { # {{{
	# Functional Areas (and Submodule)
	# Used for help generation, and default command module identifier
	ENVIRONMENT => {order =>  0, module => "Env",        label => "Environment Management"},
	BOSH        => {order =>  1, module => "Bosh",       label => "BOSH Actions"},
	INFO        => {order =>  2, module => "Info",       label => "Informative"},
	REPOSITORY  => {order =>  3, module => "Repo",       label => "Repository Management"},
	KIT         => {order =>  4, module => "Kit",        label => "Kit Management"},
	PIPELINE    => {order =>  5, module => "Pipelines",  label => "Pipeline Management"},
	GENESIS     => {order =>  6, module => "Core",       label => "Genesis Management"},
	UTILITY     => {order => -1, module => "Utility",    label => "Script Callback Helper"},
	DEPRECATED  => {order => -2, module => "Deprecated", label => "Deprecated"},
	DEV         => {order => -3, module => "Core",       label => "Development"},
  WIP         => {order => -4, module => "Wip",        label => "Work in Progress"},

	# Option Groups
	BLANK_OPTIONS => 0,
	BASE_OPTIONS  => 1,
	REPO_OPTIONS  => 2,
	ENV_OPTIONS   => 3,

	# Branch classes (D81)
	#
	# Every pipeline-aware command belongs to one of these two, declared at
	# its registration beside its scope and group.  The one declaration
	# drives the refusal off a forbidden branch and the marker in the help
	# listing, so the two can never disagree about what a command expects.
	PRE_DEPLOY     => 'pre-deploy',
	DEPLOYED_STATE => 'deployed-state',
}; # }}}

# The branch a command says it goes to of its own accord, which exempts it
# from the gate.  Control is the only one, because it is the only target the
# gate compares against, and a declaration naming anything else would exempt
# a command from nothing while reading as though it had.
use constant BRANCH_TARGETS => ('control'); # {{{
# }}}

# DEPLOYED_TARGET_HELP - the one sentence both deployed-commit flags print {{{
#
# D87 gives the deployed commit two selections and forbids a third spelling,
# so the two declarations read from one constant rather than each carrying
# its own wording.
use constant DEPLOYED_TARGET_HELP =>
	"Target the deployed commit, which is the commit recorded in this ".
	"environment's last successful deployment and so the version it is ".
	"actually running, rather than the tip of its deployment branch.  The ".
	"commit is checked out detached inside the branch session, and the ".
	"branch you started on is restored when the command finishes.";

# }}}

# What a command says about the refresh the branch-class gate would otherwise
# make on its behalf.  D40 has every pipeline command refresh before it reads
# anything, and D81 keeps every fact about a command's branch handling at its
# registration, so the two commands that read and resolve nothing say so here
# rather than being named inside the gate.
#
# `optional` is a refresh the operator may skip, which they do with
# --no-refresh, and the gate makes it wherever they did not.  `never` is a
# command that answers out of the repository's own files, holds no ref a
# refresh could make current, and offers no flag to ask with, so the gate
# makes none for it at all.  A command that declares nothing is refreshed as
# it always was.
use constant REFRESH_MODES => ('optional', 'never'); # {{{
# }}}

our @global_options = ( # {{{
	[
		"help|h" =>
			"Show this help screen.",

		"help-full" =>
			"Show help screen with all available options including global options.",

		"helpful" =>
			"Show help screen with all available options including global options (same as --help-full, but more fun!).",

		"globals" =>
			"Show only the global options available to all commands.",
	],
	[
		"color!" =>
			"Enable [or disable] color output",

		'log|L=s' =>
			"Set the log level.  Valid values are NONE, ERROR, WARN, DEBUG, INFO, ".
			"and TRACE.  Default is WARN",

		"quiet|q" =>
			"Suppress informative output (errors will still be displayed)",

		"debug|D" =>
			"Enable debugging, printing helpful message about what Genesis is doing, ".
			"to standard error.\n\n".
			"Deprecated; use --log=DEBUG instead.",

		# REFACTOR: Remove debug and trace, but ensure if used, they provide an infomative message

		"trace|T" =>
			"Deeper level of debugging.  Any trace commands within the Genesis ".
			"codebase will be printed, along with identifying the line they were ".
			"encountered.\n\n".
			"Deprecated; use --log=TRACE instead.",

		"show-stack|S+" =>
			"Will show stack trace when displaying any log messages.  Specifying it ".
			"twice will show only the current line, while specifying it once will ".
			"show the whole stack.",
	],
	[
	  "cwd|C=s" =>
			"Effective working directory.  You can also specify the environment YAML ".
			"file to use, in which case the working directory is the one containing ".
			"the specified file.  Defaults to '.'"
	],
	[
		"bosh-env|e=s" =>
			"Which BOSH environment (aka director) to use.  If not specified, it ".
			"will use the value in genesis.bosh or genesis.env in that order.  Can ".
			"also be provided using either \$GENESIS_BOSH_ENVIRONMENT env variables.".
			"\n".
			"As of v2.8.0, the BOSH director information is read from Exodus data ".
			"instead of the local .bosh/config, and as such, expect the deployment ".
			"type of the bosh director to be 'bosh'.  If this is not the case, you ".
			"can specify the deployment type after the deployment name, separated ".
			"by a '/' (ie c-aws-myenv/new-bosh).  This will inform the system where ".
			"to find the Exodus data.",

		"config|c=s@" =>
			"Specify a YAML file to be used as a config instead of fetching it from ".
			"the BOSH director.  This option can be specified multiple times for ".
			"different configurations.  The syntax for specifying the config is:".
			"\n".
			"[<type>[@<name>]=]<path>".
			"\n".
			"The type defaults to 'cloud', and name defaults to 'default' if not ".
			"given.  In this way, it maintains its backwards compatibility of the ".
			"original #y{-c} option for specifying the cloud config file.",

		"cpi=s" =>
			"Specify the CPI explicitly.  Normally, this is determined from the BOSH ".
			"director, but can be specified using this option if the BOSH director ".
			"is not available."

	]
); # }}}

sub define_command { # {{{
	my ($name, $props, $fn);
	$name = shift;
	$props = ref($_[0]) eq 'HASH' ? shift : {};
	$fn = scalar(@_) ? shift : undef;

	my $default_props = {
		scope              => 'any',
		no_vault           => 0,
		function_group     => GENESIS,
		option_group       => BASE_OPTIONS,
		option_passthrough => 0,
		# D87: a deployed-state command declares which commit it means, and
		# every command that says nothing means the branch tip.
		default_target     => 'tip',
		branch_class       => undef,
		branch_target      => undef,
		branch_fast_forward => 0,
		commits            => undef,
		refresh            => undef,
	};

	$PROPS{$name} = {%$default_props, %$props};

	# A misspelled class would silently gate nothing, which is the failure
	# mode D81's single declaration exists to rule out, so it is a bug.
	bug(
		"Command #C{$name} declares the branch class #y{%s}; ".
		"the only classes are #y{%s} and #y{%s}.",
		$PROPS{$name}{branch_class}, PRE_DEPLOY, DEPLOYED_STATE
	) if defined($PROPS{$name}{branch_class})
		&& $PROPS{$name}{branch_class} ne PRE_DEPLOY
		&& $PROPS{$name}{branch_class} ne DEPLOYED_STATE;

	bug(
		"Command #C{$name} declares a branch target without a branch class."
	) if defined($PROPS{$name}{branch_target})
		&& !defined($PROPS{$name}{branch_class});

	# A misspelt target reads as the tip, because that is what the resolver
	# makes of every word that is not #y{deployed}, so the command would take
	# the commit its author declared it did not mean and nothing downstream
	# could tell the typo from a deliberate #y{tip}.  The registration is the
	# only place that can catch it, which is the same reason the class above
	# is checked here.
	bug(
		"Command #C{$name} declares the default target #y{%s}; ".
		"the only targets are #y{%s} and #y{%s}.",
		$PROPS{$name}{default_target}, 'tip', 'deployed'
	) if ($PROPS{$name}{default_target} // 'tip') ne 'tip'
		&& $PROPS{$name}{default_target} ne 'deployed';

	# A commit declared outside the pre-deploy class is read by nobody.
	# Only the pre-deploy assertion asks the question, so the attribute on
	# any other registration reads as though the command had been exempted
	# from the control_requires_pr refusal when it was never subject to it.
	bug(
		"Command #C{$name} declares that it commits on control without ".
		"the #y{%s} branch class.",
		PRE_DEPLOY
	) if $PROPS{$name}{commits}
		&& ($PROPS{$name}{branch_class} // '') ne PRE_DEPLOY;

	# The fast-forward is the gate's one write, and it is declared rather
	# than assumed, so that a command which only reads the deployment branch
	# cannot acquire a ref move by sharing a gate with one that deploys.
	# Declared outside the class the gate switches for, it would be read by
	# nobody and would read as though the command moved a ref it never
	# touches.
	bug(
		"Command #C{$name} declares that it fast-forwards its deployment ".
		"branch without the #y{%s} branch class.",
		DEPLOYED_STATE
	) if $PROPS{$name}{branch_fast_forward}
		&& ($PROPS{$name}{branch_class} // '') ne DEPLOYED_STATE;

	# A target the gate never compares against would silently gate the
	# command it was meant to exempt, which is the same failure the class
	# check above rules out.  Control is the only target the gate reads
	# today; a step that teaches it a second one adds that name here.
	bug(
		"Command #C{$name} declares the branch target #y{%s}; ".
		"the only target is #y{%s}.",
		$PROPS{$name}{branch_target}, join('#y{, }', BRANCH_TARGETS)
	) if defined($PROPS{$name}{branch_target})
		&& !grep {$_ eq $PROPS{$name}{branch_target}} BRANCH_TARGETS;

	# A refresh mode the gate never compares against would leave the command
	# refreshed as though it had declared nothing, which is the same silent
	# failure the class check above rules out.
	bug(
		"Command #C{$name} declares the refresh mode #y{%s}; ".
		"the only modes are #y{%s}.",
		$PROPS{$name}{refresh}, join('#y{ and }', REFRESH_MODES)
	) if defined($PROPS{$name}{refresh})
		&& !grep {$_ eq $PROPS{$name}{refresh}} REFRESH_MODES;

	# A refresh declared outside the pre-deploy class is read by nobody, so
	# the attribute on any other registration reads as though the command had
	# been exempted from a fetch it was never subject to.
	bug(
		"Command #C{$name} declares a refresh mode without the #y{%s} ".
		"branch class.",
		PRE_DEPLOY
	) if defined($PROPS{$name}{refresh})
		&& ($PROPS{$name}{branch_class} // '') ne PRE_DEPLOY;

	# extended_handlers implies option_passthrough: the main parser
	# must leave unrecognised flags in @args for the handlers to claim.
	if ($PROPS{$name}{extended_handlers}) {
		$PROPS{$name}{option_passthrough} = 1;
	}

	# retired and deprecated are mutually exclusive — retired's refuse-to-run
	# always trumps deprecated's warn-and-run, so declaring both is a bug.
	bug(
		"Command #C{$name} declares both #y{retired} and #y{deprecated}; ".
		"use #y{retired} alone once the command no longer runs."
	) if $PROPS{$name}{retired} && defined($PROPS{$name}{deprecated});

	my $fn_require = '';
	if (ref($fn) ne "CODE") {
		if (defined($fn)) {
			$fn =~ m/(.*)::[^:]*$/;
			$fn_require = $1;
		} else {
			my ($fn_label, $fn_submodule) = @{($PROPS{$name}{function_group})}{qw(label module)};
			(my $fn_name = $name) =~ s/-/_/g;
			$fn_submodule ||= $fn_label;
			$fn_require = "Genesis::Commands::$fn_submodule";
			$fn = $fn_require.'::'.$fn_name;
		}
		$fn_require =~ s/::/\//g;
		$fn_require =~ s/(\.pm)?$/.pm/;
	}

	$RUN{$name} = sub {
		$ENV{GENESIS_COMMAND} = $name;
		$ENV{GENESIS_CALLED_COMMAND} = $CALLED;
		$ENV{GENESIS_NO_VAULT} = 1 if $PROPS{$name}{no_vault};
		if ($fn_require) {
			require $fn_require;
			$fn = \&{$fn};
		}
		$fn->(@_);
	};
	push @COMMANDS, $name; # FIXME: This is denormalized from keys of $GENESIS_COMMANDS, could be a potential bug -- is it needed, or can we just use commands() and return the keys of $GENESIS_COMMANDS where key equals value?
	$GENESIS_COMMANDS{$name} = $name;
	$GENESIS_COMMANDS{$_} = $name for @{$PROPS{$name}{aliases} || (defined($PROPS{$name}{alias}) ? [$PROPS{$name}{alias}] : [])};
	return;
} # }}}

sub commands { # {{{
	return (@COMMANDS);
} # }}}

sub current_command { # {{{
	return $COMMAND;
} # }}}

sub current_command_alias { # {{{
	return $CALLED;
} # }}}

# FIXME:  What's the difference between commands and known commands?  known_commands is only used by Env, to deterime if a string conflicts with a command name to add .yml to the end -- shouldn't this apply to aliases as well?
sub known_commands { # list the known genesis commands specified by define_command {{{
	return grep {$_ eq $GENESIS_COMMANDS{$_}} keys %GENESIS_COMMANDS;
} # }}}

sub prepare_command { # {{{
	($CALLED, my @args) = @_;
	$COMMAND = $GENESIS_COMMANDS{$CALLED};
	trace "Preparing genesis command '$COMMAND'".($CALLED ne $COMMAND ? ' (called as $CALLED)':'');
	parse_options(\@args);
	set_logging_state();
	return 1;
} # }}}

sub run_command { # {{{
	command_help("Unrecognized command '$CALLED'")
		unless defined($RUN{$COMMAND});
	if (my $retired = command_properties()->{retired}) {
		my $reason = ref($retired) ? ($retired->{message} // '') : $retired;
		bail(
			"The #G{$COMMAND} command has been retired and cannot be run.%s",
			$reason ? "\n\n$reason" : ''
		);
	}
	if (defined(command_properties()->{deprecated})) {
		my $msg =
			"The #G{$COMMAND} command has been deprecated, and will be ".
			"removed in a future version of Genesis.";
		if (my $replacement = command_properties()->{deprecated}) {
			$msg .= "  It has been replaced by #G{$replacement}"
		}
		warning({label => "DEPRECATED"}, $msg);
	}
	_gate_pipeline_on_legacy_ci_yml();

	# The branch gate is handed the command rather than returning to it,
	# because a deployed-state command reads inside a branch session and
	# that session has to close where the function returns.  A session
	# closed from an exit hook closes too late: the session hangs its own
	# last-resort net on END when it opens, a hook registered after that
	# one runs after it, and a bail out of END replaces the status the
	# command chose with 1.
	my $status = _gate_branch_class(sub {$RUN{$COMMAND}(@COMMAND_ARGS)});

	# A deployed-state command returns its status rather than exiting with
	# it, for the same reason: an exit from inside the command leaves the
	# session open behind it.  So the status arrives here as a value and
	# the process exits on it, once the gate has closed the session.  Every
	# command outside the class exits zero on a normal return, as it always
	# has, because nothing else promises to return a status at all.
	exit((command_properties()->{branch_class} // '') eq DEPLOYED_STATE
		? ($status // 0) : 0);
} # }}}

# branch_session - the session the deployed-state gate opened, if any {{{
#
# A command reaches the gate's session through this rather than through
# $git->session, because that builds a fresh session on a handle that never
# opened one and a fresh session answers finish_if_clean false for a tree
# that is perfectly clean.  Undef means the gate opened none, which is a
# command outside the pipeline surface, a pre-deploy command, or a
# deployed-state command whose environment has no deployment branch it can read.
our $BRANCH_SESSION;
sub branch_session { $BRANCH_SESSION }

# }}}
# branch_carries_repository - does this branch hold the deployment root {{{
#
# The repository configuration is what is asked about, because every delivery
# mirrors it and nothing else on the branch is guaranteed.  A branch that
# answers no is one pipeline-apply cut and no propagate run has delivered to,
# so there is nothing on it to read.
#
# The gate asks before it switches, so that a command is not left looking at a
# tree with no configuration in it, and the deploy asks again as it classifies
# the branch, so that a deploy the gate left standing on control refuses rather
# than certifying a commit no propagation routed there.  One answer for both,
# because two readings of one question are two chances to disagree about which
# branches are deployable.
#
# What the branch holds is read off the local ref where there is one, and off
# the remote-tracking ref otherwise, which is how the checkout chooses too.
# The local ref rather than the tracking ref, because the checkout takes the
# working tree to the commit the local ref names and the tree is what the
# command then reads: a question answered off the tracking ref would pass a
# branch this clone holds at the init commit, and the command would be stood
# on an empty tree with the answer saying it had a repository on it.
#
# Nothing is written and nothing is fetched here.  This answers a question,
# and the one ref move a stale clone needs belongs to the command that
# deploys; every other deployed-state command reads, and a read moves no ref.
#
# The deployment root is named as a path under the git root, which is empty
# where the two are the same directory.
#
# Both paths are resolved the same way before they are compared.  A deployment
# root reached through a symlink, or named as /var where git answers
# /private/var, is the same directory under two spellings, and a comparison
# made on the spellings would ask the branch for a .genesis/config at the
# repository root instead.  That answers "this branch carries no repository"
# for a branch that carries it perfectly well, and the command then runs
# unswitched without anybody being able to see why.  A root that really is
# outside the repository is a defect rather than something an operator did, so
# it is said outright.
sub branch_carries_repository {
	my ($top, $git, $branch) = @_;

	my $remote = $git->default_remote // 'origin';
	my $root   = Cwd::realpath($git->root) // $git->root;
	my $path   = Cwd::realpath($top->path) // $top->path;
	my $read   = $git->branch_exists($branch) ? $branch : "$remote/$branch";

	my $under_root = '';
	if ($path ne $root) {
		bail(
			"The deployment root #C{%s} is not inside the repository at ".
			"#C{%s},\nso there is no path on #C{%s} to read it from.",
			$top->path, $git->root, $branch
		) unless index($path, "$root/") == 0;
		$under_root = substr($path, length($root) + 1);
	}

	return $git->ls_tree($read,
		join('/', grep {length} $under_root, '.genesis/config')) ? 1 : 0;
}

# }}}
# _gate_context - the Top and the git handle the two gates read {{{
#
# Both gates ask the same two questions of the same directory, and loading a
# Top is not free of consequence: it names GENESIS_ROOT, GENESIS_TARGET_VAULT
# and SAFE_TARGET in the environment, and the memo behind Service::Vault
# answers every later caller with whatever the first load chose.  Loading it
# twice for the four commands that meet both gates is therefore two
# announcements of one thing, so the answer is built once and kept.
#
# It is kept per directory rather than per process, because a caller that
# runs a gate against one repository and then against another wants each
# repository's own answer and gets it.
#
# Each load has its own eval.  A directory that is no repository at all
# still has a Top the first gate can refuse from, and the git handle bails
# on its own when there is no repository root, so a failure there hands back
# undef and the branch-class gate stands aside rather than speaking before
# the command's own refusal.
#
# A directory is only a stable key while the tree in it holds still, and the
# deployed-state switch moves it: it checks out the environment's branch in
# this same process, so the repository configuration and the environment
# files under that directory become another branch's.  A Top kept from
# before the switch would answer for the branch the operator stood on, so
# _reset_gate_context drops what is kept and the next caller loads the tree
# as it now is.  _gate_deployed_state calls it on both sides of the command,
# once after the switch and once after the session restores.
{
	my %CONTEXT;
	sub _gate_context {
		my $dir = getcwd();
		return @{$CONTEXT{$dir}} if $CONTEXT{$dir};

		require Genesis::Top;
		require Service::Git;
		my $top = eval { Genesis::Top->new('.', no_vault => 1) };
		my $git = $top ? eval { Service::Git->new('.') } : undef;

		$CONTEXT{$dir} = [$top, $git];
		return @{$CONTEXT{$dir}};
	}

	sub _reset_gate_context {
		%CONTEXT = ();
		return;
	}
} # }}}

# _gate_pipeline_on_legacy_ci_yml - refuse PIPELINE-group commands in a repo still carrying a legacy ci.yml {{{
sub _gate_pipeline_on_legacy_ci_yml {
	# Only PIPELINE-group commands need the gate.
	my $fg = command_properties()->{function_group} // {};
	return unless ($fg->{module}//'') eq 'Pipelines';

	# Only meaningful when the command has a repo context to load a
	# Top from.  Commands like `help`, `version`, `ping` don't.
	return unless has_scope('repo', 'env');

	my ($top) = _gate_context();
	return unless $top;                 # if Top load itself failed
	return unless $top->has_legacy_ci_yml;

	Genesis::bail({exitcode => CONFIG},
		"This repository still has a legacy CI configuration at #C{ci.yml}.\n".
		"Pipeline commands are unavailable until it is migrated to the v3\n".
		"repository configuration.  To migrate:\n\n".
		"  1. Read the pipeline: block in ci.yml and note the provider, the\n".
		"     git URI, the branch, the pipeline name and the vault URL.\n".
		"  2. Write them into the #C{pipeline:} block of\n".
		"     #C{.genesis/config}, which declares every one of them.\n".
		"  3. Remove ci.yml (#g{git rm ci.yml}).\n\n".
		"That restores pipeline commands."
	);
} # }}}

# deployed_target - the commit this run targets, or undef for the tip {{{
#
# Under D87 a deployed-state command declares its default target at its
# registration, and the two flags select the deployed commit where the default
# does not.  Under D88 both flags refuse when the pipeline is not enabled,
# because the session that makes a detached checkout safe opens only under a
# pipeline, which is H38.
#
# The name and the root come in rather than an environment object, because the
# gate asks this of every classified command and genesis new names an
# environment whose file it is about to write.  An environment built to ask a
# question about flags would refuse that run over a file that is missing
# exactly as intended, so the reader of the deployed record builds one where
# it needs one, below this question rather than above it.
sub deployed_target {
	my ($name, $top) = @_;
	my $props = command_properties();

	my $flagged = has_option('redeploy') || has_option('as-deployed');
	my $wanted  = $flagged || (($props->{default_target} // 'tip') eq 'deployed');
	return undef unless $wanted;

	unless ($top->pipeline_enabled) {
		return undef unless $flagged;
		bail(
			{exitcode => CONFIG},
			"Refusing to target the deployed commit for #C{%s}.\n\n".
			"The deployed commit is recorded in every repository, but the ".
			"branch session that makes checking it out safe opens only under a ".
			"pipeline, so there is nothing here to assert the tree clean, to ".
			"hold the switch lock, or to put you back where you started.\n\n".
			"Set #C{pipeline.enabled: true} in #C{.genesis/config} to use this ".
			"flag, or run the command without it.  Nothing was changed.",
			$name
		);
	}

	# The environment's file has to be in the tree before an environment can
	# be built on it.  Genesis::Env->bare runs the name and file-existence
	# checks, so a name whose file is not here dies there, and an operator
	# standing on one environment's deployment branch and naming another is
	# in exactly that state, because a deployment branch carries its own
	# environment file and no other.  A run that resolved its target from its
	# registration's default is not asking for the deployed commit in so many
	# words, so it yields and the gate switches to the branch, where the file
	# it wants is the one that was delivered.  A run that named a flag asked
	# outright, and is told why the answer cannot be given here.
	#
	# The guard is a file test rather than an eval around the builds below.
	# An eval catches every way a build can fail, and a vault the repository
	# cannot reach is one of them, so a run whose vault is down would quietly
	# take the tip instead of saying so.  The one state that has to be told
	# apart here is a file that is not in this tree, and a file test asks
	# that and nothing else, which leaves every other failure loud.
	unless (-f $top->path("$name.yml")) {
		return undef unless $flagged;

		my $branch = $top->branch_for($name);
		bail(
			{exitcode => CONFIG},
			"Refusing to target the deployed commit for #C{%s}.\n\n".
			"There is no #C{%s.yml} in the tree you are standing on, so there ".
			"is no environment here to read a deployed commit for.  That file ".
			"travels on control and on the environment's own deployment ".
			"branch, #C{%s}, and the branch you are on carries neither.\n\n".
			"Stand on #C{%s}, or on #C{%s}, and run the command again.  ".
			"Nothing was changed.",
			$name, $name, $branch, $top->control_branch, $branch
		);
	}

	# Reading the record and answering the commit is D87's other half.  The
	# bare environment that reader needs is built here, below the question
	# and below the refusal, so that a run which named no flag never builds
	# one and a flagged run under no pipeline is refused before it pays for
	# one.
	#
	# The root the gate keeps carries no vault, because it is loaded with
	# no_vault so that reading a command's class announces no vault target,
	# which is a side effect a gate has no business having.  The record is in
	# the vault, so it is read through a root loaded again with the vault the
	# repository configures, which is the root the command itself is about
	# to load a moment later and is paid for only by a run that named the
	# deployed commit.
	require Genesis::Top;
	require Genesis::Env;
	my $env = Genesis::Env->bare($name, Genesis::Top->new($top->path));

	# An environment that has never deployed successfully names no commit,
	# and neither does a record written before the field existed, so both
	# take the tip, which is where they stood before the flags existed.  A
	# flagged run is not refused for it, because the operator asked for the
	# deployed commit of an environment that has none, and the command's own
	# reading of an undeployed environment says more than a refusal could.
	my $record = $env->deployed_record;
	return undef unless $record && $record->{git} && $record->{git}{commit};

	# The path the commit was read from goes back beside it, because D94 has
	# the refusal name the record as well as the commit.  The record is the
	# input, and an operator told only which commit is missing is not told
	# which of their records to go and correct.  It is answered here rather
	# than worked out again by the caller, because this environment is the
	# one that read it and a second one built in the gate merely to ask for
	# the path would announce a vault target the gate has no business
	# announcing.  A caller that wants the commit alone asks in scalar
	# context and is answered exactly as it was before.
	return wantarray
		? ($record->{git}{commit}, $env->exodus_base . '/deployments')
		: $record->{git}{commit};
} # }}}

# _gate_branch_class - run a command under its declared class {{{
#
# D81 puts the class at the registration so that one declaration drives both
# the refusal and the help marker, which means the enforcement belongs here,
# beside the legacy ci.yml gate, and not inside each command.
#
# The command's own function comes in as $fn and every path here runs it.  A
# pre-deploy command is refused before it runs or runs where it stands, and a
# deployed-state command runs inside a branch session, which is why the gate
# runs the function rather than returning to a caller that would.
sub _gate_branch_class {
	my ($fn) = @_;

	my $class = command_properties()->{branch_class};
	return $fn->() unless $class;

	# propagate switches to control inside the session it already has, so
	# the gate leaves it where it stands (D65, D81).  The exemption is read
	# before anything is loaded, because loading a Top names the root and
	# the vault target in the environment and a command the gate never gates
	# should not be handed those as a side effect.
	return $fn->() if (command_properties()->{branch_target} // '') eq 'control';

	# Only meaningful when the command has a repository to read a Top from.
	return $fn->() unless has_scope('repo', 'env');

	# One root and one handle, built once and read by both arms.  The
	# pre-deploy assertion classifies the branch through the handle and the
	# deployed-state switch opens its session on it, and two handles onto
	# one working tree would key two sessions, which is what I9 forbids.
	my ($top, $git) = _gate_context();
	return $fn->() unless $top && $git;

	# D88: the two deployed-commit flags refuse where no session opens, so
	# the resolver is asked above the return that leaves every other command
	# alone with the pipeline off.  It answers the commit the run targets,
	# or undef where the run targets the tip, which is every run that named
	# neither flag under a registration declaring no deployed default.
	#
	# The name derivation lives here rather than in _gate_deployed_state,
	# for the reason the comment there gave, which is that two derivations
	# of one name are two chances to disagree, and now two callers want it.
	# An operator may name the environment by a path, so the leading
	# directories and the suffix both come off, which is what the deploy does
	# to the same argument in Genesis::Commands::Env::deploy.  set_top_path
	# has already turned a path resolving to a file into its basename by the
	# time this runs, so the directory half earns its place by keeping the
	# two derivations identical rather than by the work it does here.
	#
	# The record the target came out of comes back with it, in list context,
	# so that a commit the repository cannot reach is refused by the name of
	# the record an operator has to go and correct (D94).  The resolver reads
	# that record already, and this is the only caller that knows which one
	# this run was answered from.
	my $name = $COMMAND_ARGS[0];
	my ($target, $record);
	if (defined($name) && length($name)) {
		$name =~ s{^.*/}{};
		$name =~ s/\.ya?ml$//;
		($target, $record) = deployed_target($name, $top);
	}

	# Outside a pipeline every command behaves as it always has, on any
	# branch, which is D80's last sentence and D81's silent premise.
	return $fn->() unless $top->pipeline_enabled;

	# D87 makes the secrets family pre-deploy by class and lets
	# --as-deployed opt it into the deployed commit, so a run that resolved
	# a target is sent down the deployed-state arm whatever class its
	# registration declares.  It is read before the class, because the flag
	# is the operator saying which of the two questions they are asking and
	# the class is only the default answer.
	return _gate_deployed_state($top, $git, $fn, $name,
			target => $target, record => $record)
		if defined($target) || $class eq DEPLOYED_STATE;

	if ($class eq PRE_DEPLOY) {
		# Two pre-deploy commands make no network call of their own, and
		# the gate makes none for them either.  Each says so at its own
		# registration rather than by name here, because a list of command
		# names inside the gate is the second declaration D81 exists to
		# prevent: it drifts from the help text, from the command's own
		# reading, and from whatever the next such command declares.
		#
		# pipeline-status declares an optional refresh, which is one the
		# operator skips with --no-refresh and which the gate makes
		# wherever they did not.  pipeline-describe declares that it never
		# refreshes, because it answers out of the repository's own files
		# and a fetch would refuse offline what it can always read from
		# disk.  The option is still the gate's to read, since the
		# registration says the refresh may be skipped and the flag is how
		# an operator says to skip it.
		my $mode = command_properties()->{refresh} // '';
		my $refresh = $mode eq 'never' ? 0
		            : $mode eq 'optional' && get_options()->{'no-refresh'} ? 0
		            : 1;

		# Whether the command commits goes down too.  D45 speaks of a
		# commit that cannot reach control through a pull request, and
		# most pre-deploy commands make none: pipeline-apply writes to
		# the provider, pipeline-status and pipeline-describe only read,
		# and the secrets commands write to the vault.  Only create
		# declares it today, and it is read off the registration for
		# the same reason the refresh mode above it is.
		#
		# genesis new is about to add an environment whose name may be the
		# branch it stands on, and that collision is one the gate cannot
		# see from the branch alone, so the name the command was given
		# goes down with it.
		my $adding;
		$adding = $COMMAND_ARGS[0] if is_equivalent_command(create => $COMMAND)
			&& defined($COMMAND_ARGS[0]);
		$adding =~ s/\.yml$// if defined $adding;

		require Genesis::BranchClass;
		Genesis::BranchClass::assert_pre_deploy($top, $git,
			refresh => $refresh, adding => $adding,
			commits => command_properties()->{commits});
		return $fn->();
	}

	return $fn->();
} # }}}

# _gate_deployed_state - run a command on the environment's branch {{{
#
# D81: a deployed-state command operates on what an environment is running
# or is about to run, so it reads <env>/<type> inside a session, because
# that branch holds exactly what was delivered and the hooks need a working
# tree.  The session is opened here rather than inside each command, so that
# deploy, info, and the bosh subcommands share one switch.
sub _gate_deployed_state {
	my ($top, $git, $fn, $name, %opts) = @_;

	# The name is derived once, in _gate_branch_class, and comes down here
	# already stripped of its leading directories and its suffix.  The
	# deployed-commit resolver wants the same name off the same argument,
	# and two derivations of one name are two chances to disagree.
	return $fn->() unless defined($name) && length($name);

	# The environment's deployment branch, which every question below is
	# asked of: whether there is one, whether it carries a repository, and
	# how far behind the remote this clone holds it.  Which commit on it the
	# session stands on is a different question, and deployed_target has
	# already answered that one.
	my $branch = $top->branch_for($name);

	# D80 settles the trigger as "will switch", so a command already standing
	# on the branch it would switch to opens no session, takes no switch
	# lock, and asserts no cleanliness.  A session exists to leave a branch
	# and come back, and there is nothing here to leave.  That is what lets
	# an operator edit a file on the deployment branch and deploy it in
	# place, which is the qualifier I3 carries and the one thing they need in
	# order to test a change before committing it.
	#
	# It says so, as the two arms below do, because this is the arm an
	# operator is likeliest to be in without having meant to be: standing on
	# a deployment branch is an easy state to arrive at, and a deploy of the
	# working tree as it stands reads no differently from any other until
	# something in it was not meant to ship.
	#
	# The words avoid calling it a deployment branch, and that is not an
	# accident: t/integration-tests/branch_class-deployed_state.t reads this
	# arm's output for the absence of that phrase, because the pre-deploy
	# refusal this class must never meet is the one that says a branch "is a
	# deployment branch".  Saying it here would answer that row with our own
	# line.
	#
	# It yields to a resolved target.  A run that named a flag, or whose
	# registration means the deployed commit, asked for one commit and not
	# for another, and the branch the operator happens to be standing on is
	# no answer to that, because the tip of the branch is where they are
	# standing while the deployed commit is what they asked for.  So the arm
	# is for the runs that mean the tip, which is every run that resolved no
	# target, and a plain deploy is one of them, which is what leaves I3's
	# edit in place deployable from the branch itself.
	if (!defined($opts{target}) && ($git->current_branch // '') eq $branch) {
		info(
			"Already standing on #C{%s}, so no branch change is made and this ".
			"runs on the working tree as it stands.",
			$branch);
		return $fn->();
	}

	# An environment that has never been delivered has no branch to read,
	# and switching to a name nothing resolves refuses at DATAERR with a
	# sentence about a commit rewritten on the remote.  Every clause of
	# that is wrong for an environment that simply has not deployed yet,
	# so the command runs where it stands and says in its own words that
	# there is no deployment to report.  Both halves the switch would ask
	# about are asked here, because git's own checkout makes a local branch
	# out of one it has only fetched and the switch knows that too.
	#
	# It says which arm it took before it runs, because a command that reads
	# the branch and a command that reads wherever the operator is standing
	# answer different questions and an operator cannot tell the two apart
	# from the answer alone.  Saying so is all that happens here: the
	# refusals belong to each command's own classification of the state.
	my $remote = $git->default_remote;
	unless ($git->branch_exists($branch)
			|| ($remote && $git->branch_exists("$remote/$branch"))) {
		info(
			"Not reading the deployment branch #C{%s}: it does not exist yet, ".
			"so this runs on #C{%s}.",
			$branch, $git->current_branch // 'the current commit');
		return $fn->();
	}

	require Service::Git::Session;
	my $session = $git->session(control => $top->control_branch);
	$session->begin;

	# A branch that pipeline-apply cut and no propagate run has delivered to
	# carries its init file and nothing else, so there is no repository on it
	# to read and the switch would leave the command looking at a tree with
	# no configuration in it.  That is the same state as having no branch at
	# all, and it is answered the same way: the session closes without having
	# moved anything and the command runs where it stands, where it says in
	# its own words that there is nothing deployed.
	#
	# An environment awaiting its first delivery and a clone nobody has
	# pulled since the apply cut the branch look alike from the local ref,
	# and they are not alike at all: the second has a delivery waiting for it
	# on the remote.  The distance between the two refs is what tells them
	# apart, and it is read here for both the move below and the line that
	# stands in its place where no move is made.
	my $d = $remote
		? $git->resolve_branch($branch, remote => $remote) : undef;
	my $behind = ($d && $d->{state} eq 'behind') ? $d->{behind} : 0;

	# The one ref the gate moves, and only for a command that declares it.
	# A command that reads the deployment branch answers a question about
	# what was delivered and has no business moving anything, so it must not
	# acquire a ref move by sharing a gate with a command that deploys; the
	# registration says which is which (D81's single declaration).
	#
	# The move is made before the question below, because the branch is the
	# working tree the command reads: the checkout stands the tree on the
	# commit the local ref names, so a clone that has not pulled would be
	# stood on the init commit and asked to deploy from it.  It is made on
	# the one state that promises a fast-forward, so it creates and discards
	# nothing, which is the ref move D35's span allows and the one the
	# deploy's own --ff-only pull was the precedent for (D5).  Nothing is
	# fetched: the refresh is its own step under D40.
	if ($behind && command_properties()->{branch_fast_forward}) {
		info(
			"Fast-forwarding #C{%s} to #C{%s/%s}, %s behind.",
			$branch, $remote, $branch, Genesis::count_nouns($behind, 'commit'));
		$git->set_branch_ref($branch, "refs/remotes/$remote/$branch");
		$behind = 0;
	}

	# The question is asked after begin rather than before it, because it
	# runs a git command of its own and begin is where the pre-flight
	# classifies the failures a git command otherwise hides (D80).  Asked
	# first, a repository git declines to trust would answer with the
	# listing's complaint instead of the pre-flight's sentence.
	#
	# It yields to a resolved target, the way the standing-on-the-branch arm
	# above it does, and for the same reason.  The question here is what the
	# branch carries now, and a run that resolved a target is not switching
	# onto what the branch carries now.  It switches onto the commit its
	# record names, and that commit carried the repository when it was
	# deployed whatever a rewrite has since done to the branch.  A commit
	# this repository no longer holds is refused by switch under D94, which
	# names the commit and the record, and that is the refusal such an
	# operator needs rather than a sentence about a branch waiting for a
	# delivery.
	if (!defined($opts{target})
			&& !branch_carries_repository($top, $git, $branch)) {
		# Where no move was made, the distance goes into the line instead, so
		# an operator reads whether they are waiting for a propagation or for
		# a pull of their own.
		info(
			"Not reading the deployment branch #C{%s}: it carries no ".
			"repository yet%s, so this runs on #C{%s}.",
			$branch,
			$behind
				? sprintf(" and this clone holds it %s behind #C{%s/%s}",
				          Genesis::count_nouns($behind, 'commit'),
				          $remote, $branch)
				: '',
			$git->current_branch // 'the current commit');
		$session->finish;
		return $fn->();
	}

	$BRANCH_SESSION = $session;

	# D94 gives both flags one code path, which is switch on a commit rather
	# than on a branch, and finish restores the operator's branch either
	# way.  A run that resolved no target stands on the branch, as every run
	# did before the flags existed.
	#
	# The record the target was read from goes down with it, because switch
	# asks whether a commit is here before it moves anything and refuses at
	# DATAERR where it is not, and D94 has that refusal name the record as
	# well as the commit.  A run standing on the branch tip carries none,
	# which is right, because a branch is not read out of a record and switch
	# asks the question of a commit alone.
	$session->switch($opts{target} // $branch, record => $opts{record});

	# The directory now holds another branch's files, so the root the gate
	# kept is dropped.  The $top and $git above are the gate's own and go
	# no further than this sub, but _gate_context hands its answer to
	# whoever asks next, and after the switch that answer would describe
	# the branch the operator came from.  The command loads its own root
	# from the tree it is standing on.
	_reset_gate_context();

	# The command runs inside the session and the session closes where the
	# function returns.  Nothing here is left to an exit hook.  The session
	# hangs its own last-resort net on END when it opens, so a hook
	# registered afterwards runs second and finds the session already
	# aborted, and a bail out of END replaces the status the command chose
	# with 1.  A command that refuses therefore exits with its own code and
	# the net puts the working tree back, which is the job the net exists
	# for.
	my @result = $fn->();
	$session->finish;
	$BRANCH_SESSION = undef;

	# The tree has moved back, so what was loaded on the environment's
	# branch is dropped in its turn.
	_reset_gate_context();

	return wantarray ? @result : $result[0];
} # }}}

sub has_command { # {{{
	my $cmd = shift;
	return defined($GENESIS_COMMANDS{$cmd});
} # }}}

sub is_equivalent_command {
	my ($cmd1,$cmd2) = @_;
	return ($GENESIS_COMMANDS{$cmd1}//'') eq ($GENESIS_COMMANDS{$cmd2}//'');
}
sub equivalent_commands { # {{{
	my ($cmd) = @_;
	my @results = ();
	my $base_cmd = $GENESIS_COMMANDS{$cmd} || '';
	if ($base_cmd) {
		@results = grep {$GENESIS_COMMANDS{$_} eq $base_cmd} keys %GENESIS_COMMANDS;
	}
	return wantarray ? @results : \@results;
} # }}}

sub command_properties { # {{{
	my $cmd = $GENESIS_COMMANDS{$_[0]||''} || $COMMAND;
	bug "No active or given command -- cannot return command_properties"
		unless $cmd;

	return $PROPS{$cmd};
} # }}}

sub parse_options { # {{{

	my $args = shift;
	my $args_copy = [@$args];

	# Validate extended handlers once, up front, before any option
	# parsing.  This is the single gateway for both command execution
	# and help rendering (prepare_command always calls parse_options
	# first), so we validate here rather than duplicating in
	# command_help.  Each handler class must be loadable and must
	# implement the required contract methods.
	if (my $handlers = $PROPS{$COMMAND}{extended_handlers}) {
		for my $class (@$handlers) {
			(my $file = $class) =~ s|::|/|g;
			eval { require "$file.pm" };
			bail(
				"Extended handler #C{%s} for command #C{%s} could not be loaded:\n%s",
				$class, $COMMAND, $@
			) if $@;
			for my $method (qw(parse_opts opts_help opts_slot)) {
				bail(
					"Extended handler #C{%s} for command #C{%s} does not implement ".
					"the required #C{%s} method.",
					$class, $COMMAND, $method
				) unless $class->can($method);
			}
		}
	}

	my @base_spec = keys %{({map {@$_} @global_options[0..$PROPS{$COMMAND}{option_group}]})};

	my @opts_spec = (
		keys %{{ @{$PROPS{$COMMAND}{options} || []} }},
		grep {/^[^\^]/} keys %{{ @{$PROPS{$COMMAND}{deprecated_options} || []} }} #ignore deprecated option references
	);
	trace "Supported Options:".join("\n  ",(''),@base_spec,@opts_spec);

	# Workaround - genesis helper always injects -C option, but many commands
	# don't use -C (not repo/env scoped)  Inject it and ignore it for those with
	# option_group < Genesis::Commands::REPO_OPTIONS
	push @base_spec, "no_cwd|cwd|C=s" if $PROPS{$COMMAND}{option_group} < Genesis::Commands::REPO_OPTIONS;

	# Clean out any special formatting noise
	@opts_spec = map {$_ =~ s/^~//r} grep {$_ ne '-section-break-'} @opts_spec;

	$COMMAND_OPTIONS->{color} = 1 unless exists $COMMAND_OPTIONS->{color};

	my $order = $PROPS{$COMMAND}{option_require_order} ? 'require_order' : 'permute';
	my @passthrough = $PROPS{$COMMAND}{option_passthrough}
		? qw(pass_through no_auto_abbrev)
		: qw(no_pass_through auto_abbrev);

	# Getopt::Long rejects a fixed arity while bundling, whatever the
	# option is named.  See _parse_two_pass.
	my @arity_spec = grep {/\{\d/} @opts_spec;

	Getopt::Long::Configure(
		qw(no_ignore_case bundling), @passthrough, $order
	) unless @arity_spec;

	my $parsing_ok = 1;
	my @option_warnings = ();
	{
		$COMMAND_OPTIONS = {};
		local $SIG{__WARN__} = sub { push @option_warnings, @_; };
		$parsing_ok = @arity_spec
			? _parse_two_pass($args, [@base_spec,@opts_spec], $order)
			: GetOptionsFromArray($args, $COMMAND_OPTIONS, (@base_spec,@opts_spec));
	}

	unless ($parsing_ok) {
		set_logging_state();
		debug(
			"[[Option Parsing Warning: >>%s",
			join("", @option_warnings)
		);
		command_usage(1, join("\n", map {chomp; $_} @option_warnings) || "Error parsing options");
	}

	shift @$args if ($args->[0]||'') eq '--';
	@COMMAND_ARGS = (@$args);

	# Extended handlers: each registered handler class gets a chance to
	# consume its flags from @COMMAND_ARGS and populate a slot in
	# $COMMAND_OPTIONS.  Handlers run in declared order so each sees
	# only what prior handlers left behind.  The classes were already
	# required and validated at the top of this sub.
	if (my $handlers = $PROPS{$COMMAND}{extended_handlers}) {
		for my $class (@$handlers) {
			my %slot;
			$class->parse_opts(\@COMMAND_ARGS, \%slot);
			$COMMAND_OPTIONS->{$class->opts_slot()} = \%slot;
		}

		# After all handlers have run, anything still looking like an
		# option is unclaimed -- reject it the same way the main parser
		# would without option_passthrough.
		my @unknown = grep { /^-/ } @COMMAND_ARGS;
		if (@unknown) {
			command_usage(1, sprintf(
				"Unknown option%s: %s",
				@unknown > 1 ? 's' : '',
				join(', ', @unknown)
			));
		}
	}

	# Extract Core options
	$ENV{NOCOLOR}        = 'y' if defined($COMMAND_OPTIONS->{color}) && !delete($COMMAND_OPTIONS->{color});
	$ENV{QUIET}          = 'y' if  delete($COMMAND_OPTIONS->{quiet});

	# Remove workaround options
	dump_var 'Received Options' => $COMMAND_OPTIONS;
	delete($COMMAND_OPTIONS->{no_cwd});
	dump_var 'Received Arguments' => \@COMMAND_ARGS;
	return;
} # }}}

sub _parse_two_pass { # {{{
	my ($args, $specs, $order) = @_;

	my @without_arity = grep {!/\{\d/} @$specs;

	# Bundling off so the arity specs are legal; pass_through leaves
	# anything unrecognised -- notably short-flag clusters -- in place.
	Getopt::Long::Configure(
		qw(no_ignore_case no_bundling pass_through no_auto_abbrev), $order
	);
	my $ok = GetOptionsFromArray($args, $COMMAND_OPTIONS, @$specs);

	# Bundling on for what is left, arity specs withheld so the guard has
	# nothing to object to.  Unknown options still fail here.
	Getopt::Long::Configure(
		qw(no_ignore_case bundling no_pass_through auto_abbrev), $order
	);
	return GetOptionsFromArray($args, $COMMAND_OPTIONS, @without_arity) && $ok;
} # }}}

sub get_options { # {{{
	return $COMMAND_OPTIONS unless scalar(@_);
	my %slice;
	for (@_) {
		if (exists($COMMAND_OPTIONS->{$_})) {
			$slice{$_} = $COMMAND_OPTIONS->{$_};
		} elsif ($_ =~ '_') {
			my $__ = _u2d($_);
			$slice{$_} = $COMMAND_OPTIONS->{$__} if exists($COMMAND_OPTIONS->{$__});
		}
	}
	return \%slice
} # }}}

sub get_args { # {{{
	# TODO: Ideally, this should use the arguments defined in the command properties
	# to build a hash map of the arguments, and return that.  This would allow
	# for the arguments to be accessed by name, rather than by index.  It will also
	# allow for pre-validation of the arguments, and for special arguments to be
	# instantiated such as environment objects, etc.
	return wantarray ? @COMMAND_ARGS : die "hashref not yet implemented";
} # }}}

sub has_option { # {{{
	# Returns 0 if the option does not exists
	# Returns 1 if it does and no test is provided
	# Compares the content of the option to the test if provided,
	# which can be undef (returns true if the option is also undef),
	# a string (returns true if the option is equal to the string),
	# or a regex (returns true if the option matches the regex).
	my $option = shift;
	return 0 unless exists($COMMAND_OPTIONS->{$option});
	return 1 unless @_;
	my $test = shift;
	if (!defined($COMMAND_OPTIONS->{$option}) || !defined($test)) {
		return !defined($COMMAND_OPTIONS->{$option}) && !defined($test)
	} elsif (ref($test) eq "Regexp") {
		return $COMMAND_OPTIONS->{$option} =~ $test ? 1 : 0;
	} else {
		return $COMMAND_OPTIONS->{$option} eq $test ? 1 : 0;
	}
} # }}}

sub option_defaults { # {{{
	while (@_) {
		(my $k, my $v, @_) = @_;
		next if defined($COMMAND_OPTIONS->{$k});
		$COMMAND_OPTIONS->{$k} = $v;
	}
} # }}}

sub append_options { # {{{
	my %extra_options = @_;
	$COMMAND_OPTIONS->{$_} = $extra_options{$_} for (keys %extra_options);
	return $COMMAND_OPTIONS;
} # }}}

# _branch_class_marker - the help marker for a command's declared class {{{
#
# D81 asks that an operator reading `genesis help` sees which commands
# expect control and which expect an environment.  The marker is computed
# from the same property the gate reads, so the listing and the refusal
# cannot drift apart.
sub _branch_class_marker {
	my ($cmd) = @_;
	# Asked through exists, because reading a key of %PROPS for a name this
	# module has never registered would give that name an empty registration
	# of its own, and a later `defined $PROPS{$name}` would then answer for a
	# command nobody declared.
	return '' unless defined($cmd) && exists($PROPS{$cmd});
	my $class = $PROPS{$cmd}{branch_class} or return '';
	return " #Ci{[control]}"    if $class eq PRE_DEPLOY;
	return " #Mi{[env branch]}" if $class eq DEPLOYED_STATE;
	return '';
}

# }}}

sub command_help { # {{{
	my ($msg, $rc) = @_;
	$rc = $msg ? 1 : 0 unless defined($rc);

	# Usage and option errors exit 2, whatever number the caller passed.
	# Every caller here means the same thing by a non-zero code, and a
	# caller that cannot tell a usage error from a crash cannot act on
	# either.  D98 keeps 2 because it is Genesis precedent.
	$rc = 2 if $rc;

	$msg ||= ''; # TODO: a summary blurb about genesis

	my $hr = "#${\($rc ? 'r' : 'K')}\{" . ("=" x terminal_width) ."}";
	my $bc = $Genesis::BUILD =~ /\+\)/ ? 'R' : 'G';
	my $ver = "#gi{genesis v$Genesis::VERSION}#${bc}i{$Genesis::BUILD}\n";

	# TODO: use named colors that are dark/light aware.

	info "$hr\n";

	if ($rc) {
		fatal {show_stack => 'default'}, "$msg\n"
	}

	my $out =
		wrap(
			"#g{${\(humanize_bin)}} [<global options...>] #G{<command>} [<command options and args...>]"
			,terminal_width,"#Wku{Usage:} ", 7
		)."\n".
		"\n".
		wrap(
			"The following Genesis commands are grouped by function areas, and marked ".
			"by the context they run against.  Some commands can run against multiple ".
			"contexts; see the help (-h) for the command for how to use it in the".
			"different contexts.", terminal_width
		)."\n".
		"\n";

	# Retired commands stay registered so dispatch bails with a targeted
	# message, but they don't belong in the default operator-facing help
	# catalog.  Parallel to the DEPRECATED function group: hidden by default,
	# surfaced by --all.
	my @commands = grep {
		defined($PROPS{$_})
		&& $PROPS{$_}{function_group}{order} >= 0
		&& !$PROPS{$_}{retired}
	} (commands);
	push @commands, (grep {
		defined($PROPS{$_})
		&& ($PROPS{$_}{function_group}{order} < 0 || $PROPS{$_}{retired})
	} (commands)) if get_options->{all};

	my %function_groups;
	$function_groups{$_->{order} < 0 ? 100 - $_->{order} : $_->{order}} = $_->{label} || $_->{module} for (
		map {$PROPS{$_}{function_group}}
		@commands
	);

	my $cmd_width = (sort {$b <=> $a} map {length($_)} @commands)[0];

	my %applicable_scopes = (
		env => { o => 1, c => "M", i => "E",
			d => "Targets a Genesis environment file (with or without .yml suffix)"},
		repo => { o => 2, c => "g", i => "R",
			d => "Must be run in a Genesis Environment repository, or use -C to target one.", },
		kit => { o => 3, c => "C", i => "K",
			d => "Must be run in a Genesis Kit repository.", },
		empty => { o => 4,c => "y", i => "N",
			d => "Cannot be run in an existing Genesis Environment or Kit repository.", },
		pipeline => { o => 5, c => "R", i => "P",
			d => "Can only be run in a Genesis pipeline by task running on a Concourse worker.", }
	);
	my @scopes = (sort {$applicable_scopes{$a}{o} <=> $applicable_scopes{$b}{o}} keys %applicable_scopes);
	my $scope_width = scalar(@scopes);
	my $cont_prefix = "#-k{".(' ' x $scope_width)."}";
	$out .= "#ui{Context:}\n";
	for my $scope (@scopes) {
		my $label = "#-k{" . (' ' x ($applicable_scopes{$scope}{o} - 1)) . "}";
		$label .=   "#$applicable_scopes{$scope}{c}k{$applicable_scopes{$scope}{i}}";
		$label .=   "#-k{" . (' ' x (5 - $applicable_scopes{$scope}{o})) . "} ";
		$out .= wrap(
			"#i{$applicable_scopes{$scope}{d}}",
			terminal_width, $label, $scope_width + 1, $cont_prefix
		)."\n";
	}

	for my $order (sort {$a <=> $b} keys %function_groups) {
		my $section = $function_groups{$order};
		$section .= ' ' x (terminal_width() - length($section));
		$out .= "\n#Wku{$section}\n";
		my $fixed_order = $order > 100 ? -($order - 100) : $order;
		for my $cmd (grep {$PROPS{$_}{function_group}{order} == $fixed_order} @commands) {
			my $scope_filter = $PROPS{$cmd}{scope};
			$scope_filter = [$scope_filter] unless ref($scope_filter) eq 'ARRAY';
			my @cmd_scopes = sort map {ref($_) eq 'ARRAY' ? (ref($_->[1]) eq 'ARRAY' ? @{$_->[1]} : ($_->[1])) :($_)} @${scope_filter};
			my $label = '';
			for my $scope (@scopes) {
				my $icon = "#$applicable_scopes{$scope}{c}k{ }";
				$icon = "#$applicable_scopes{$scope}{c}k{$applicable_scopes{$scope}{i}}"
					if (scalar(grep {$_ eq 'any'} @cmd_scopes ) && $scope ne 'pipeline')
					|| (scalar(grep {$scope eq $_} @cmd_scopes) && $applicable_scopes{$scope}{i});
				$label .= $icon;
			}
			$label .= " #G{$cmd}  ";
			my $summary = ($PROPS{$cmd}{summary} || '-- no summary provided -- ');
			if ($PROPS{$cmd}{alias} || $PROPS{$cmd}{aliases}) {
				my @aliases = grep {defined($_)} ($PROPS{$cmd}{alias}, @{$PROPS{$cmd}{aliases}||[]});
				$summary .= " #G{(alias".(@aliases > 1 ? 'es' : '').": ".join(', ',@aliases).")}";
			}
			# The marker goes on after the wrap, so that it lands on the
			# line the command's own name is on.  Appended to the summary
			# beforehand it travelled with the last words of the summary,
			# and at an ordinary width four of the ten marked commands
			# carried it onto a continuation line, where it names no command
			# and a reader scanning the left column cannot tell whose it is.
			# The wrap is given the room the marker will take, so the line it
			# lands on still fits the terminal.
			my $marker = _branch_class_marker($cmd);
			my $entry = wrap(
				$summary, terminal_width - csize($marker), $label,
				$cmd_width+3+$scope_width, $cont_prefix
			);
			if (length($marker)) {
				$entry =~ s/\n/$marker\n/ or $entry .= $marker;
			}
			$out .= $entry."\n";
		}
	}

	$out .= "\n$ver$hr\n";
	info({raw => 1}, $out);
	exit $rc;
} # }}}

sub command_usage { # {{{
	my ($rc, $msg, $show_global) = @_;

	# The same rule as command_help: a non-zero code here is a usage or an
	# option error, and it exits 2.
	$rc = 2 if $rc;

	my $called = $CALLED;
	my $command = $GENESIS_COMMANDS{$called};

	my $hr = "#K{" . ("=" x terminal_width) ."}";
	my $bc = $Genesis::BUILD =~ /\+\)/ ? 'R' : 'G';
	my $ver = "#gi{genesis v$Genesis::VERSION}#${bc}i{$Genesis::BUILD}\n";

	# TODO: use named colors that are dark/light aware.
	my $usage="";
	my @usage_lines = $PROPS{$command}{usage} ? split("\n",$PROPS{$command}{usage}, -1) : ($called);
	for (@usage_lines) {
		s/^$command($| )/#G{$CALLED}$1/;
		s/^<env> $command($| )/#M{<env>} #G{$CALLED}$1/;
		$usage .= "#g{${\(humanize_bin)}} ".$_."\n";
	}
	chomp $usage;

	info "\n$hr";
	my $out = "";
	$out .= wrap($PROPS{$command}{summary} || '', terminal_width, "#G{$CALLED} - ")."\n\n"
		if $PROPS{$command}{summary};

	$out .= wrap($usage,terminal_width,"#Wku{Usage:} ", 7)."\n";
	$out .= "\n".wrap(
		"#Gi{$called}#i{ is an alias to the }#Gi{$command}#i{ command}",
		terminal_width," #i{Note:} ", 7
	)."\n" unless $command eq $called;

	# TODO: List all the aliases (or other aliases if alias was used)

	if ($rc && !under_test) {
		$out .= wrap(
			"\nTo see full description with arguments and option, run ".
			"#g{${\(humanize_bin)}} #G{$called} #y{-h}",
			terminal_width
		);
		info $out;
		$msg = defined($msg)
			? "#r{".csprintf($msg)."}"
			: "#g{${\(humanize_bin)}} #G{$CALLED} was called incorrectly: $ENV{GENESIS_FULL_CALL}";

		fatal {show_stack => 'default'}, "\n$msg\n";
		info "$ver$hr\n";
		exit $rc;
	}

	$out .= wrap("\n$PROPS{$command}{description}",terminal_width)."\n"
		if ($PROPS{$command}{description});

	my @sources = (
		[args    => $PROPS{$COMMAND}{arguments} || [], 'Argument'],
		[vars    => $PROPS{$COMMAND}{variables} || [], 'Environmental Variable'],
		[command =>$PROPS{$COMMAND}{options} || [], 'Option'],
		[legacy  => $PROPS{$COMMAND}{deprecated_options} || []],
	);

	# Only add global options if explicitly requested or if we're checking help from command line
	if ($show_global || (!defined($show_global) && get_options->{help})) {
		push @sources, [global  => [(map {@$_} @global_options[0..$PROPS{$COMMAND}{option_group}])]];
	}
	my (%options_desc, %options_def, %options_order);
	my $opt_width=0;

	for my $source_details (@sources) {
		my ($source,$options,$label) = @{$source_details};
		my $type = $label || 'Option';
		my $section=0;
		# Walk the pairs rather than consume them: these are the live
		# command definition, not a copy of it.
		for (my $i = 0; $i < @$options; $i += 2) {
			my ($opt_def, $opt_desc) = @{$options}[$i, $i+1];

			my $opt_arg;
			if (ref($opt_desc) eq "HASH") {
				$opt_arg = $opt_desc->{argument};
				$opt_desc = $opt_desc->{description};
			}
			if ($opt_def eq '-section-break-') {
				my $sec = '-'.$section++.'-';
				push @{$options_order{$source}}, $sec;
				$options_desc{$sec} = "$opt_desc";
				next;
			}
			push @{$options_order{$source}}, $opt_def;
			$options_desc{$opt_def} = $opt_desc;

			$opt_def =~ /\^?(~?[\|a-zA-Z0-9_-]*)([\?!\+=:].*)?$/;
			bug "$type definition for $COMMAND invalid: $opt_def" unless $1;
			my ($ext,@flags) = ($2 || '', split(/\|/,$1));

			my @short_flags = grep {/^.$/} @flags;
			my @long_flags = grep {$_ !~ /^~/} grep {/^../} @flags;
			my $opt_color = $source eq 'legacy' ? 'r' : 'y';

			if ($source =~ /^(args|vars)$/) {
				my $c = $source eq 'vars' ? 'c' : $long_flags[0] eq 'env' ? 'M' : 'B';
				$options_def{$opt_def} = "#${c}{$long_flags[0]}".(
					$ext eq '?' ? " #Yi{(optional)}" : ""
				);
				next;
			}

			if ($ext eq '!') {
				$options_def{$opt_def} = "    #${opt_color}{--[no-]$long_flags[0]}";
				next;
			}

			my $opt_label = scalar(@short_flags) ? "-${\(shift @short_flags)}, " : "    ";
			$opt_label .= "--${\(shift @long_flags)}" if scalar(@long_flags);
			$opt_label =~ s/, $//; # trim comma if no long option
			unless ($opt_arg) {
				if ($ext =~ /^=([si])\@?$/) {
					$opt_arg = $1 eq 's' ? " <str>" : " <N>";
				} elsif ($ext =~ /^:([si])$/) {
					$opt_arg = $1 eq 's' ? "[=<str>]" : "[=<N>]";
				} elsif ($ext eq '+') {
					$opt_arg = ""; # TODO: find out how to indicate multiple flags allowed
				} else {
					$opt_arg = "";
				}
			}
			$options_def{$opt_def} = "#${opt_color}{$opt_label}#B{$opt_arg}";
			# TODO: save extra long and short options, and print them after the given
			# description.  Right now, they're just undocumented
		}
	}
	# A command can declare no arguments, no variables, and no options at
	# all, and then there is no definition to measure.  The empty set reads
	# as zero here so that such a command renders its help quietly.
	my $def_width =
		((sort {$b <=> $a} map {csize($_)} values(%options_def))[0] // 0) + 4;

	for my $source_details (@sources) {
		my ($source,$options,$label) = @{$source_details};
		next unless (defined $options_order{$source});
		($label = ($label ? $label.'s' : $source.' Options')) =~ s/.*/\u$&/; #title case;
		$out .= "\n#Wku{$label}\n";
		for (@{$options_order{$source}}) {
			if ($_ =~ /^-\d+-$/) {
				if ($options_desc{$_}) {
					$out .= "\n#i{".wrap($options_desc{$_},terminal_width)."}\n";
				} else {
					$out .= "\n";
				}
				next;
			}
			$out .= "\n".wrap($options_desc{$_}, terminal_width, "  ".$options_def{$_}, $def_width)."\n";
		}
	}

	# Add notice about global options if they're not being shown
	if (!$show_global && defined($show_global)) {
		$out .= "\n#i{To see all options including global ones, use }#g{${\(humanize_bin)}} #G{$command} #y{--help-full}#i{ or }#y{--helpful}\n";
		$out .= "#i{To see only global options, use }#g{${\(humanize_bin)}} #y{--globals}\n";
	}

	# Extended usage: render help from registered handlers (preferred),
	# or fall back to legacy extended_usage closure if no handlers are
	# registered.
	# Extended handlers were already required and validated in
	# parse_options (which always runs before command_help via
	# prepare_command).
	if (my $handlers = $PROPS{$command}{extended_handlers}) {
		my $extended_usage = '';
		for my $class (@$handlers) {
			my $help = $class->opts_help();
			if ($help) {
				$help =~ s/\s*$//s;
				$extended_usage .= $help . "\n";
			}
		}
		if ($extended_usage =~ /\S/) {
			$out .= "\n#Wku{Extended Usage Information}\n";
			$out .= "\n$extended_usage\n";
		}
	} elsif (ref($PROPS{$command}{extended_usage}) eq "CODE") {
		my $extended_usage = $PROPS{$command}{extended_usage}->();
		if ($extended_usage) {
			$extended_usage =~ s/\s*$//s;
			$out .= "\n#Wku{Extended Usage Information}\n";
			$out .= "\n$extended_usage\n";
		}
	}

	info {raw => 1}, $out."\n$ver$hr\n";
	exit ($rc || 0);
} # }}}

sub show_global_options { # {{{
	my $hr = "#K\{" . ("=" x terminal_width) ."}";
	my $bc = $Genesis::BUILD =~ /\+\)/ ? 'R' : 'G';
	my $ver = "#gi{genesis v$Genesis::VERSION}#${bc}i{$Genesis::BUILD}\n";

	info "\n$hr";
	my $out = "";
	$out .= wrap("#G{Global Options} - Available to all Genesis commands", terminal_width)."\n\n";
	$out .= wrap("#g{${\(humanize_bin)}} [<global options...>] #G{<command>} [<command options and args...>]",terminal_width,"#Wku{Usage:} ", 7)."\n";

	my (%options_desc, %options_def, %options_order);
	my $section = 0;
	for my $global_opt_group (@global_options) {
		my @options = @$global_opt_group;
		while (my ($opt_def, $opt_desc) = splice(@options,0,2)) {
			if ($opt_def eq '-section-break-') {
				my $sec = '-'.$section++.'-';
				push @{$options_order{global}}, $sec;
				$options_desc{$sec} = "$opt_desc";
				next;
			}
			push @{$options_order{global}}, $opt_def;
			$options_desc{$opt_def} = $opt_desc;

			$opt_def =~ /\^?(~?[\|a-zA-Z0-9_-]*)([\?!\+=:].*)?$/;
			bug "Global option definition invalid: $opt_def" unless $1;
			my ($ext,@flags) = ($2 || '', split(/\|/,$1));

			my @short_flags = grep {/^.$/} @flags;
			my @long_flags = grep {$_ !~ /^~/} grep {/^../} @flags;

			if ($ext eq '!') {
				$options_def{$opt_def} = "    #y{--[no-]$long_flags[0]}";
				next;
			}

			my $opt_label = scalar(@short_flags) ? "-${\(shift @short_flags)}, " : "    ";
			$opt_label .= "--${\(shift @long_flags)}" if scalar(@long_flags);
			$opt_label =~ s/, $//; # trim comma if no long option
			my $opt_arg = "";
			if ($ext =~ /^=([si])\@?$/) {
				$opt_arg = $1 eq 's' ? " <str>" : " <N>";
			} elsif ($ext =~ /^:([si])$/) {
				$opt_arg = $1 eq 's' ? "[=<str>]" : "[=<N>]";
			} elsif ($ext eq '+') {
				$opt_arg = ""; # TODO: find out how to indicate multiple flags allowed
			}
			$options_def{$opt_def} = "#y{$opt_label}#B{$opt_arg}";
		}
	}

	# The same empty set can reach here, so it reads as zero here too.
	my $def_width =
		((sort {$b <=> $a} map {csize($_)} values(%options_def))[0] // 0) + 4;

	if (defined $options_order{global}) {
		$out .= "\n#Wku{Global Options}\n";
		for (@{$options_order{global}}) {
			if ($_ =~ /^-\d+-$/) {
				if ($options_desc{$_}) {
					$out .= "\n#i{".wrap($options_desc{$_},terminal_width)."}\n";
				} else {
					$out .= "\n";
				}
				next;
			}
			$out .= "\n".wrap($options_desc{$_}, terminal_width, "  ".$options_def{$_}, $def_width)."\n";
		}
	}

	info {raw => 1}, $out."\n$ver$hr\n";
	exit 0;
} # }}}

sub set_top_path { # {{{
	# Set up current repo and env file if specified
	if (!$COMMAND_OPTIONS->{cwd} && scalar(@COMMAND_ARGS)) {
		if (has_scope('env') &&  (-f $COMMAND_ARGS[0] || -f $COMMAND_ARGS[0].'.yml')) {
			$COMMAND_OPTIONS->{cwd} = shift(@COMMAND_ARGS);
		} elsif (is_equivalent_command(create => $COMMAND) && $COMMAND_ARGS[0] =~ /(.*)\/[^\/]+?(.yml)?$/ && -d $1) {
			$COMMAND_OPTIONS->{cwd} = shift(@COMMAND_ARGS);
		}
	}
	if ($COMMAND_OPTIONS->{cwd}) {
		my $requested_cwd = delete($COMMAND_OPTIONS->{cwd});
		my $cwd = abs_path($requested_cwd);
		bail(
			"Path '%s' specified in -C option does not exist",
			$requested_cwd
		) unless $cwd;

		if ( -f $cwd || -f "${cwd}.yml" ) {
			if (! has_scope('env')) {
				# Allow gracefull degradation of specifying a file as an argument when
				# the command is repo scoped and using search target mode.
				if ($ENV{GENESIS_PREFIX_TYPE} eq 'search' && has_scope('repo','any','all')) {
					$cwd = dirname($cwd);
				} else {
					bail(
						"#B{%s %s} cannot be called specifying a file as an argument",
						humanize_bin, $CALLED
					);
				}
			} else {
				unshift(@COMMAND_ARGS, basename($cwd));
				$cwd = dirname($cwd);
			}
		} elsif ($COMMAND eq 'create' && ! -d $cwd) {
			unshift(@COMMAND_ARGS, basename($cwd));
			$cwd = dirname($cwd);
		}

		# TODO: create top and env objects if in a repo or env context, and put them
		# in the args hash (currently only the args array is used - see get_args)

		chdir_or_fail($cwd);
		return 1;
	}
	return;
} # }}}

sub set_logging_state { # {{{

	# Logging
	my $log_level = delete($COMMAND_OPTIONS->{log});
	my $debug = delete($COMMAND_OPTIONS->{debug}) || 0;
	my $trace = delete($COMMAND_OPTIONS->{trace}) || 0;

	# TODO: make this obsolete in 3.0.0
	if ($log_level) {
		warning "Option --log|-l takes precedence over -D and -T options"
			if ($debug || $trace);
		$log_level = Genesis::Log::find_log_level($log_level)
	} else {
		$log_level = 'DEBUG' if ($debug);
		$log_level = 'TRACE' if ($trace);
	}
	$log_level ||= 'INFO';

	$ENV{GENESIS_DEBUG}  = 'y' if Genesis::Log::meets_level($log_level, 'DEBUG');
	$ENV{GENESIS_TRACE}  = 'y' if Genesis::Log::meets_level($log_level, 'TRACE');

	my $stack_trace = delete($COMMAND_OPTIONS->{'show-stack'});
	$ENV{GENESIS_STACK_TRACE} = $stack_trace if defined($stack_trace);

	$Logger->configure_log(
		level => $log_level,
		style => $ENV{GENESIS_LOG_STYLE} // $Genesis::RC->get('output_style','plain'),
		show_stack => ($stack_trace ? ($stack_trace == 1 ? 'fatal' : $stack_trace == 2 ? 'current' : 'full' ) : undef),
	);
} # }}}

sub build_command_environment  { # {{{

	# spruce debugging
	my $spruce_log = delete($COMMAND_OPTIONS->{'spruce-log'});
	if ($spruce_log) {
		my @spruce_log_levels = grep {$_ =~ qr/^$spruce_log.*/i} (qw[debug trace]);
		bail "--spruce-log is expected to be one of TRACE or DEBUG"
			if (scalar(@spruce_log_levels) == 0);

		$spruce_log = $spruce_log_levels[0];
		$ENV{DEBUG} = 'y' if $spruce_log ;
		$ENV{TRACE} = 'y' if $spruce_log eq 'trace';
	}

	$ENV{GENESIS_EXECUTABLE_ENVS} = $Genesis::RC->get('executable_envs', 0);
	$ENV{GENESIS_BOSH_ENVIRONMENT} = delete($COMMAND_OPTIONS->{'bosh-env'}) if $COMMAND_OPTIONS->{'bosh-env'};
	$ENV{GENESIS_BOSH_ENVIRONMENT} ||= '';

	# Set BOSH CPI for debugging/testing purposes - name is due to legacy usage by testkit Golang library
	$ENV{GENESIS_TESTING_BOSH_CPI} = delete($COMMAND_OPTIONS->{'cpi'}) if $COMMAND_OPTIONS->{'cpi'};

	if ($COMMAND_OPTIONS->{config} && ref($COMMAND_OPTIONS->{config}) eq 'ARRAY') {
		my %configs;
		for (@{$COMMAND_OPTIONS->{config}}) {
			my ($type,$name,$path) = $_ =~ m/^(?:(cc|rc|[a-z0-9_-]*?)(?:@([^=]*))?=)?(.*)$/;
			$type = 'cloud' if !defined($type) || $type eq 'cc';
			$type = 'runtime'  if $type eq 'rc';
			$type =~ s/-config$//;
			$path = Cwd::abs_path($path)
				or bail "$path: no such file or directory";
			my $var = uc("GENESIS_${type}_CONFIG") . ($name ? "_$name" : '');
			$ENV{$var} = $path;
			$configs{$type."@".($name||'default')} = $path;
		}
		delete($COMMAND_OPTIONS->{config});
		$COMMAND_OPTIONS->{config} = {%configs} if %configs;
	}
} # }}}

sub has_scope { # {{{
# Fragments are OR'd: a fragment whose conditions hold but whose scopes
# don't cover the request falls through rather than deciding the answer.
#
# TODO: support combining forms -- has_scope([all => [...]]), [any => [...]],
#       [none => [...]], [not => [...]].  Workable today by composing calls:
#       all is && , any is the current default for a list, none/not are
#       negations of those.
	my @allowed_scopes = @_;
	my $command_scopes = $PROPS{$COMMAND}{scope} or return 0; # no scope required
	$command_scopes = [$command_scopes] unless ref($command_scopes) eq 'ARRAY';

	my %requested_scopes;
	$requested_scopes{$_}=1 for (@allowed_scopes);

	for my $scope_fragment (@$command_scopes) {
		if (ref($scope_fragment) eq 'ARRAY') {
			bug('Incorrectly defined scope for command $COMMAND') unless scalar(@$scope_fragment) == 2;
			my ($opt_names, $opt_scopes) = @$scope_fragment;
			$opt_names = [$opt_names] unless ref($opt_names) eq 'ARRAY';
			$opt_scopes = [$opt_scopes] unless ref($opt_scopes) eq 'ARRAY';
			my $match = 1;
			for my $opt_name (@$opt_names) {
				(my $negate,$opt_name,my $value) = $opt_name =~ m/^(!)?([^=]*)(?:=(.*))?$/;
				my $check = defined($value)
					? defined($COMMAND_OPTIONS->{$opt_name}) && $COMMAND_OPTIONS->{$opt_name} eq $value
					: $COMMAND_OPTIONS->{$opt_name};
				$match = $match && ($check xor $negate);
			}
			return 1 if $match && scalar(grep {$requested_scopes{$_}} @$opt_scopes);
		} else {
			return 1 if $requested_scopes{$scope_fragment};
		}
	}

	return;
} # }}}

sub check_embedded_genesis { # {{{

	return if envset("GENESIS_IS_HELPING_YOU");
	return if $Genesis::RC->get('embedded_genesis','ignore') eq 'ignore';
	return unless has_scope qw(repo env);

	require Genesis::Top;
	my $top = Genesis::Top->new('.', no_vault => 1);
	my $embedded_genesis = $top->path('.genesis/bin/genesis');
	return unless -f $embedded_genesis;
	return if envset("GENESIS_USING_EMBEDDED");
	return if $ENV{GENESIS_CALLBACK_BIN} eq $embedded_genesis;

	# Get embedded contents
	open my $fh,  '<',  $embedded_genesis;
	while(<$fh>) {last if /^__(END|DATA)__$/};
	my $sha = <$fh>;
	my $contents = do { local $/; <$fh> };
	close $fh;

	# Check if embedded genesis is present, compressed, and valid
	unless (require MIME::Base64) {
		debug "Can't import MIME::Base64 - can't check embedded genesis";
		return;
	}
	MIME::Base64->import(qw(decode_base64));
	unless (require IO::Uncompress::Gunzip) {
		debug "Can't import IO::Uncompress::Gunzip - can't check embedded genesis";
		return;
	}
	IO::Uncompress::Gunzip->import(qw(gunzip $GunzipError));

	my $bincontents = decode_base64($contents);
	my $z = IO::Uncompress::Gunzip->new( \$bincontents );
	my $tar = do { local $/; <$z>};
	close $z;

	# pack rewrites the `$VERSION //= ...` default in Genesis.pm to a literal
	# `$VERSION = "X.Y.Z";`, so that is the marker a released build carries.
	# Copies embedded by earlier releases wrote `$Genesis::VERSION = "..."`
	# instead, so accept both forms.
	my ($embedded_version) = map {
		/^\$(?:Genesis::)?VERSION\s*=\s*"([^"]*)"/ ? ($1) : ()
	} split("\n", $tar);
	unless (defined $embedded_version) {
		debug "Could not determine the version of the embedded genesis - skipping check";
		return;
	}
	return if ($embedded_version eq $Genesis::VERSION);
	if ($Genesis::RC->get('embedded_genesis','ignore') ne "use" || command_properties->{no_use_embedded_genesis}) {
		warning(
			"Embedded genesis is $embedded_version, current version is $Genesis::VERSION"
		);
		return;
	}

	info "#Y{Running embedded Genesis ($embedded_version)...}\n";
	my $embedded_root = workdir();
	open my $bin, "|-", "tar -xzf - -C $embedded_root"
		or bail("Could not use extract embedded Genesis");
	print $bin $bincontents;
	close $bin;

	# run it!
	$ENV{GENESIS_CALLBACK_BIN}   = "$embedded_root/genesis";
	$ENV{GENESIS_LIB}            = "$embedded_root/lib";
	$ENV{GENESIS_USING_EMBEDDED} = 1;
	chmod 0755, "$embedded_root/genesis";
	exit(system "$embedded_root/genesis", @ARGV);
} # }}}

sub check_version { # {{{
	my $opts = {};
	%$opts = (%$opts, %$_) for (grep {ref($_) eq 'HASH'} @_);
	my ($name, $min, $cmd, @remainder) = grep {ref($_) ne 'HASH'} @_;
	my ($version, $regex, $url, $path);
	if ($cmd) {
		($regex, $url, my $path_src) = @remainder;
		($version) = run({ stderr => undef }, $cmd);
		$path_src = (grep {$_ !~ /=/} split(" ", $cmd))[0] unless $path_src;
		($path) = run({stderr => undef}, 'type -p $1', $path_src);
	} else {
		($version, $path, $url) = @remainder;
	}

	$url ||= "your platform package manager";

	return "#R{Missing `$name`} -- install from #B{$url}"
		if !$version || $version =~ /not found/;

	if (envset('GENESIS_DEV_MODE') && $version =~ /development/) {
		debug("#Y{Version $version} of #C{$name} (development) being used - minimum of #W{$min} needed.");
		return;
	}

	my $v = $version;
	if ($regex) {
		$version =~ $regex; $v = $1;
		if ($v && $v =~ /^dev\b/) {
			# A build from source reports no ordinal, so there is nothing to
			# compare.  A caller that knows which release such a build must
			# postdate says so, and the comparison happens against that; the
			# rest keep the older reading, where the minimum is only a floor.
			unless ($opts->{dev_version}) {
				debug("#Y{Version $v} of #C{$name} (development) being used - minimum of #W{$min} needed.");
				return;
			}
			debug("#Y{Version $v} of #C{$name} (development) being read as #W{$opts->{dev_version}}.");
			$v = $opts->{dev_version};
		}
		return "Could not determine version of $name from `#M{$cmd}`: Got '#C{$version}'"
			unless $v && semver($v);
	}

	$path = humanize_path($path);
	return "$name v${v} is installed at $path, but Genesis requires #R{at least $min} -- please upgrade via #B{$url}"
		unless new_enough($v, $min);

	debug("#G{Version $v} of #C{$name} ($path) meets or exceeds minimum of #w{$min}");
	return; # no error
} # }}}

# safe drives either Vault or OpenBao, taking whichever it finds first on
# $PATH, so either satisfies Genesis.  OpenBao is only offered when safe is
# new enough to drive it: accepting it against an older safe would pass this
# check and fail later inside `safe local`, where the cause is far less
# obvious.
my $SAFE_OPENBAO_MIN = '1.20.0';

# A safe built from source reports `safe vdev/<branch>/<sha>`, which carries
# no ordinal: new_enough reads it as older than every release, and the
# OpenBao gate would deny the engine to exactly the people building safe to
# work on it.  Read such a build as the first release that could have
# produced it.  Mapped rather than waved through, so raising the minimum
# past this stops qualifying dev builds instead of silently passing them.
my $SAFE_DEV_VERSION = '1.20.1';
my @SECRETS_ENGINES = (
	# Name,  Version, Command,             Pattern                    Source
	["vault", "1.9.0", "vault -v 2>/dev/null", qr(.*vault v(\S+).*)i, "https://developer.hashicorp.com/vault/install"],
	["bao",   "2.6.0", "bao -v   2>/dev/null", qr(.*bao v?(\d\S*).*)i, "https://github.com/openbao/openbao/releases"],
);

sub check_secrets_engine { # {{{
	my @failures;
	for my $engine (@SECRETS_ENGINES) {
		my ($name) = @$engine;

		if ($name eq 'bao' && !_safe_drives_openbao()) {
			push @failures, sprintf(
				"#C{bao} is present, but driving OpenBao needs safe #R{at least %s}",
				$SAFE_OPENBAO_MIN
			) if which_binary('bao');
			next;
		}

		my $err = check_version(@$engine);
		return () unless $err;   # this engine satisfies the requirement
		debug $err;
		push @failures, $err;
	}

	return join(
		"\n         ",
		"#R{No usable secrets engine} -- Genesis needs one of:",
		@failures
	);
} # }}}

# Reported separately from check_version so a bao that is installed but
# undriveable says so, rather than being silently ignored.
sub which_binary { # {{{
	my ($name) = @_;
	my ($path) = run({stderr => undef}, 'type -p $1', $name);
	return $path && $path !~ /not found/ ? $path : undef;
} # }}}

sub _safe_drives_openbao { # {{{
	my ($out) = run({stderr => undef}, 'safe -v 2>&1');
	return 0 unless $out && $out =~ qr(safe v(\S+));
	my $v = $1;
	$v = $SAFE_DEV_VERSION if $v =~ /^dev\b/;
	return new_enough($v, $SAFE_OPENBAO_MIN) ? 1 : 0;
} # }}}

sub check_prereqs { # {{{
	CORE::state $prereqs_checked = 0; # static variables
	return 1 if envset("GENESIS_IS_HELPING_YOU") || $prereqs_checked;
	bug "check_prereqs called before command selected" unless current_command;

	my $bosh_min_version = "6.4.4";
	my $perl_version = join('.',map {$_+0}  ($] =~ m/(\d*)\.(\d{3})(\d{3})/));
	my $reqs = [
		# Name,     Version, Command,                                 Pattern                   Source
		["perl",   "5.20.0", "", $perl_version, $^X],
		["curl",   "7.30.0", "curl --version  2>/dev/null | head -n1",          qr(^curl\s+(\S+))],
		# 2.34.1 is what Ubuntu jammy ships, jammy being the lowest supported
		# image, and what the CI image carries.  Declared for every command
		# rather than for the ones that lean on it: two floors would be two
		# things to keep true, and a command that changed class would change
		# its requirement silently.  It is also what refuses a task image
		# whose git has regressed.
		["git",    "2.34.1", "git --version   2>/dev/null",                     qr(.*version\s+(\S+).*)],
		["jq",        "1.6", "jq --version    2>/dev/null",                     qr(^jq-([\.0-9]+)),       "https://stedolan.github.io/jq/download/"],
		["spruce", "1.28.0", "spruce -v       2>/dev/null",                     qr(.*version\s+(\S+).*)i, "https://github.com/geofffranks/spruce/releases"],
		[{dev_version => $SAFE_DEV_VERSION},
		 "safe",    "1.6.1", "safe -v         2>&1",                            qr(safe v(\S+)),          "https://github.com/starkandwayne/safe/releases"],
		# The secrets engine is checked separately: which ones are acceptable
		# depends on the version of safe that has to drive it.
		["openssl", "1.1.1", "openssl version 2>/dev/null",                     qr(OpenSSL ([\.0-9]+) .*),"https://www.openssl.org/source/"],
		["credhub", "2.7.0", "CREDHUB_SERVER='' credhub --version 2>/dev/null", qr(CLI Version: (\S+)),   "https://github.com/cloudfoundry-incubator/credhub-cli/releases"],
	];

	my @errors = grep {$_} map {
		my $err = check_version(@$_);
		debug $err if $err;
		$err
	} @$reqs;

	push @errors, grep {$_} check_secrets_engine();

	# Check that we have some required but not necessarily available Perl modules
	my $perl_modules = [
		["MIME::Base64", "3.14", "MIME::Base64"],
		["IO::Uncompress::Gunzip", "2.064", "IO::Uncompress::Gunzip"],
		["IO::Compress::Gzip", "2.064", "IO::Compress::Gzip"],
		["Archive::Tar", "1.96", "Archive::Tar"],
	];

	for my $mod (@$perl_modules) {
		my ($name, $min, $modname) = @$mod;
		eval "use $modname";
		if ($@) {
			push @errors, "Perl module $name is required but not installed";
		} elsif (new_enough $min, $modname->VERSION) {
			push @errors, sprintf(
				"Perl module $name is installed but version is too old (%s < %s)",
				$modname->VERSION, $min
			);
		} else {
			debug(
				"#G{Perl module %s/%s} is installed and meets version requirements",
				$name, $modname->VERSION
			)
		}
	}
	# check that we has a bosh (v2)
	require Service::BOSH;
	eval {$ENV{GENESIS_BOSH_COMMAND} = Service::BOSH->command($bosh_min_version)};
	if ($@) {
		push @errors, $@ =~ s/^\s*.*\[[^ ]*\][^ ]* //mr;
	}

	# Check Scope requirements
	if (has_scope(['repo','env'])) {
		push @errors, csprintf(
			"The '#B{%s %s}' command needs to be run from a Genesis deployment\n    ".
			"repo, or specify one using -C <dir> option",humanize_bin(), $COMMAND )
			unless in_repo_dir;
	} elsif (has_scope(['kit'])) {
		push @errors, csprintf(
			"The '#B{%s %s}' command needs to be run from a Genesis kit repo,\n    ".
			"or specify one using -C <dir> option",humanize_bin(), $COMMAND )
			unless in_kit_dir;
	} elsif (has_scope(['kit_or_dev'])) {
		push @errors, csprintf(
			"The '#B{%s %s}' command needs to be run from a Genesis kit repo or a\n    ".
			"deployment repo with a dev kit, or specify one using -C <dir> option",humanize_bin(), $COMMAND )
			unless in_kit_dir || (in_repo_dir && -d 'dev');
	} elsif (has_scope('empty')) {
		push @errors, csprintf(
			"The '#B{%s %s}' command cannot be run from a Genesis deployment\n    ".
			"or kit repo, or specify one using -C <dir> option",humanize_bin(), $COMMAND )
			if in_repo_dir || in_kit_dir;
	}
	# TODO: Validate pipeline scope (must at least be in a repo?)

	debug "Terminal encoding: '%s'", $ENV{LANG} || '<undefined>';

	# The prerequisites check keeps 86, which is the code the kit and
	# provider checks at Commands/Env.pm and Commands/Pipelines.pm already
	# exit with.  A missing or too-old tool is not a crash, and a caller
	# that reads 86 knows the environment is the thing to fix.
	bail(
		{exitcode => 86},
		"#R{GENESIS PRE-REQUISITES CHECKS FAILED!!}\n".
		"\n".
		"Encountered the following errors:\n".
		join("", map {"[[  - >>$_\n"} @errors)
	) if (@errors);
	$prereqs_checked=1;
} # }}}

sub at_exit { # {{{
	my ($fn) = @_;
	push @$END_HOOKS, $fn;
}

END {
	$_->($?) for @$END_HOOKS;
} # }}}

1;
# vim: fdm=marker:foldlevel=0:noet
