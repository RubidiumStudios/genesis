package Genesis::CI::ProviderCompiler::Concourse;
use v5.20;
use warnings;

# Genesis::CI was the second parent, and it is gone.  Its trait had had
# one implementer since March 2026 and no caller at all, so the compiler
# base is the only parent now.
use parent 'Genesis::CI::ProviderCompiler';

use Genesis;
use Genesis::Top;
use Genesis::Config;
use Genesis::CI::Legacy;
use Genesis::CI::Compiler::PipelineDescriptor;
use JSON::PP;

### Provider Constants {{{

# There is no DEFAULT_TEAM here.  It was written twice, here and in
# Genesis::CI::Provider::Concourse, where it is the default the provider
# fragment declares, and a comment above each asked a reader to keep the
# two in step.  The team is resolved through provider_option now, which
# reads the operator's block and falls back to that fragment's default,
# so this class neither holds the value nor knows what it is.
use constant {
	DEFAULT_PIPELINE_NAME   => undef,    # falls back to deployment_type from Top
	DEFAULT_EXPOSE          => 0,
	DEFAULT_PAUSE_AFTER_SET => 0,
	DEFAULT_INSECURE        => 0,
};

# }}}
### Class Methods {{{

# init - build a compiler from a configuration file rather than an AST {{{
#
# The factory that called this is gone and nothing in the tree calls it
# now.  It stands because parse reads the configuration this blesses, and
# parse is the only thing that sets the config key deploy insists on, so
# taking it away would take deploy's path with it.
sub init {
	my ($class, %opts) = @_;

	my $self = bless({
		file          => $opts{file},
		top           => $opts{top},
		layout        => $opts{layout},
		_platform     => $opts{platform} || '',
		provider_opts => $opts{provider_opts} || {},
		config        => undef,
		ast           => undef,
		errors        => [],
	}, $class);

	return $self;
}

# }}}
# }}}
### Provider Options System {{{
# Modelled after Genesis::Kit::Provider::Github, where each method mirrors its
# kit-provider counterpart so the patterns are interchangeable.

# provider_type - canonical type string {{{
sub provider_type { 'concourse' }

# }}}
# check_prereqs is gone from this class {{{
#
# A provider answers for its toolchain, and this class's copy asked only
# whether fly was on the path while the provider's asked for a version
# too.  The weaker one was the live one, because the command called it on
# whatever the compile handed back.
#
# }}}
# cli_opts - Getopt::Long specs for deploy-time command-line flags {{{
#
# All CI provider options are prefixed with 'ci-' to avoid clashing with
# top-level genesis option names.
sub cli_opts {
	qw/
		ci-target=s
		ci-team=s
		ci-pipeline-name=s
		ci-pause
		ci-expose
		ci-insecure
	/;
}

# }}}
# cli_opts_help - formatted help text for Concourse CLI flags {{{
sub cli_opts_help {
	my ($class, %config) = @_;
	return '' unless grep { $_ eq 'concourse' } @{$config{valid_types} || ['concourse']};
	return <<'EOF';
  CI Provider `concourse`:

    Deploys Genesis pipelines to a Concourse CI server using the fly CLI.
    Requires a configured fly target (see: fly login).

    --ci-target <name>  (required if not set in .genesis/config pipeline.provider.target)
        The fly target alias that identifies the Concourse server.
        Create a target with: fly login -t <name> -c <url>

    --ci-team <name>  (optional, default: "main")
        The Concourse team to use when setting the pipeline.
        Must match an existing team on the target Concourse server.

    --ci-pipeline-name <name>  (optional, default: pipeline.name, else deployment type)
        Override the pipeline name used in Concourse for this run alone.
        Falls back to pipeline.name in .genesis/config, and then to the
        repository's deployment_type (e.g., "cf", "bosh").

    --ci-pause  (optional, default: false)
        Leave the pipeline in a paused state after fly set-pipeline completes.
        By default the pipeline is unpaused immediately after being set.

    --ci-expose  (optional, default: false)
        Run fly expose-pipeline after setting, making the pipeline publicly
        viewable without authentication.  Useful for open-source pipelines.

    --ci-insecure  (optional, default: false)
        Skip TLS certificate verification when communicating with Concourse.
        Passes --skip-ssl-validation (-k) to all fly commands.  Use when the
        Concourse server uses a self-signed or otherwise untrusted certificate.

  Pipeline features are driven by configuration files, not CLI flags.
  The following sections are controlled in ci/configuration.yml (or the
  legacy ci.yml):

    Notification styles (integrations.slack.style):
        per-env,  pending-changes notify job gates each deployment (default)
        grouped,  notify jobs exist but do not block deployments
        minimal,  no notify jobs; Slack alerts on failure only
        none,     no Slack resource or notifications at all

    BOSH upgrade locks (genesis.pipeline.locks.bosh_upgrade):
        Automatically wired when a pipeline manages a BOSH director alongside
        child deployments.  Prevents a director upgrade from racing a child
        deploy.  Requires a locker integration.  Opt out per-env with:
            genesis:
              pipeline:
                locks:
                  bosh_upgrade: false

    Task library (configuration.task_library):
        Declares an external git repository of custom task files.  The repo
        is checked out as a Concourse git resource and made available as an
        input to every deploy task.  Configure uri, branch, path, and auth.

EOF
}

# }}}
# provider_options_defaults - default values for all Concourse options {{{
#
# Read off the fragment rather than listed again beside it, so the two
# cannot drift: a key whose default the fragment declares is a key whose
# default this answers with, and a nested block states its defaults where
# its own sub-keys are declared.
#
# The fragment comes from the provider this compiler holds, which is why
# this is an instance method: a class method has no provider to ask.
sub provider_options_defaults {
	my ($self) = @_;
	my $schema = $self->provider->provider_options_schema;
	return {
		map  {($_ => $schema->{$_}{default})}
		grep {exists $schema->{$_}{default}} keys %$schema
	};
}

# }}}
# normalize_provider_opts - remap ci-pause (CLI) to pause_after_set (schema key) {{{
sub normalize_provider_opts {
	my ($class, $opts) = @_;
	my $normalized = $class->SUPER::normalize_provider_opts($opts);
	if (exists $normalized->{pause} && !exists $normalized->{pause_after_set}) {
		$normalized->{pause_after_set} = delete $normalized->{pause};
	}
	return $normalized;
}

# }}}
# describe_provider - structured self-description for display {{{
#
# Mirrors Genesis::Kit::Provider::Github::status() and returns a hash with
# type, label, an ordered 'extras' list, and a per-key status structure.
# Also surfaces the active notification style and task library when an AST
# is already resolved (i.e., after parse() has been called).
sub describe_provider {
	my ($self) = @_;

	my $target    = $self->provider_option('target')        || '(not set)';
	my $team      = $self->provider_option('team');
	my $pipe_name = $self->provider_option('pipeline_name') || '(deployment type)';
	my $expose    = $self->provider_option('expose')    ? 'yes' : 'no';
	my $paused    = $self->provider_option('pause_after_set') ? 'yes' : 'no';
	my $insecure  = $self->provider_option('insecure')  ? 'yes' : 'no';

	my @extras = qw(Target Team Pipeline Expose PauseAfterSet Insecure);
	my %desc = (
		type          => 'concourse',
		label         => 'Concourse',
		Target        => $target,
		Team          => $team,
		Pipeline      => $pipe_name,
		Expose        => $expose,
		PauseAfterSet => $paused,
		Insecure      => $insecure,
		status        => 'ok',
	);

	# Augment with pipeline-level feature summary when AST is available
	if (my $ast = $self->{ast}) {
		my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);

		# Notification style
		my $notif_style = $descriptor->notification_style($ast);
		push @extras, 'NotifStyle';
		$desc{NotifStyle} = $notif_style;

		# Task library
		my $tl = ($ast->configuration || {})->{task_library};
		if ($tl && ref($tl) eq 'HASH' && $tl->{uri}) {
			push @extras, 'TaskLibrary';
			my $rn = $tl->{resource_name} || 'tasks';
			$desc{TaskLibrary} = "$rn ($tl->{uri})";
		}

		# BOSH upgrade lock summary
		my $has_locker = ($ast->integrations->{locker} || {})->{url} ? 'yes' : 'no';
		push @extras, 'BoshLocks';
		$desc{BoshLocks} = $has_locker;
	}

	$desc{extras} = \@extras;
	return %desc;
}

# }}}
# }}}
### Trait Interface Implementation {{{

# parse - parse and validate Concourse pipeline configuration {{{
sub parse {
	my ($self) = @_;

	my $platform = $self->{_platform} || '';

	# Legacy fallback: delegate to Legacy::parse when --platform legacy
	if ($platform eq 'legacy') {
		my ($pipeline, $layout) = Genesis::CI::Legacy::parse(
			$self->{file},
			$self->{top},
			$self->{layout}
		);
		$self->{config} = $pipeline;
		$self->{layout} = $layout;
		return $self;
	}

	# Native path: use the compiler pipeline
	require Genesis::CI::Compiler::Parser;
	require Genesis::CI::Compiler::Validator;
	require Genesis::CI::Compiler::ScriptDiscovery;
	require Genesis::CI::Compiler::ASTBuilder;

	my $parser = Genesis::CI::Compiler::Parser->new(
		file => $self->{file},
		top  => $self->{top},
	);
	my $parsed = $parser->parse();

	my $validator = Genesis::CI::Compiler::Validator->new(top => $self->{top});
	$validator->validate($parsed);

	if ($validator->has_errors) {
		bail("Pipeline configuration is invalid:\n  - %s",
			join("\n  - ", @{$validator->errors}));
	}

	my $script_discovery = Genesis::CI::Compiler::ScriptDiscovery->new(
		repo_path => '.',
	);
	my $scripts = $script_discovery->discover($parsed);

	my $ast_builder = Genesis::CI::Compiler::ASTBuilder->new(
		top => $self->{top},
	);
	my $ast = $ast_builder->build($parsed, $scripts);

	$self->{ast}    = $ast;
	$self->{config} = $parsed;

	return $self;
}

# }}}
# generate - generate Concourse pipeline YAML {{{
sub generate {
	my ($self) = @_;

	bail("Must call parse() before generate()") unless $self->{config};

	# Legacy fallback
	if ($self->{_platform} && $self->{_platform} eq 'legacy') {
		return Genesis::CI::Legacy::generate_pipeline_concourse_yaml(
			$self->{config},
			$self->{top}
		);
	}

	# Native generation from AST
	bail("No AST available; call parse() first") unless $self->{ast};
	return $self->generate_from_ast($self->{ast});
}

# }}}
# deploy - deploy pipeline to Concourse via fly CLI {{{
#
# Option resolution priority (highest to lowest):
#   1. Caller-supplied %opts (from command-line flags via parse_cli_opts)
#   2. provider_opts stored in $self (loaded from pipeline.provider: in .genesis/config)
#   3. Legacy $self->{layout} (backward compat)
#   4. Built-in defaults (team: main, etc.)
sub deploy {
	my ($self, %opts) = @_;

	bail("Must call parse() before deploy()") unless $self->{config};

	# All keys use config-file names (target, team, pipeline_name, pause_after_set, expose).
	# Callers are responsible for normalizing cli-prefixed keys before calling deploy().

	# --- Resolve options from three tiers ---

	# Target: call-site override > provider_opts > legacy layout
	my $target = $opts{target}
		// $self->provider_option('target')
		// $self->{layout};
	bail("No Concourse target specified.  Use --ci-target or set pipeline.provider.target in .genesis/config")
		unless $target;

	# Team: call-site override > the resolved option
	#
	# There is no third tier.  provider_option falls back to the defaults
	# the provider's own fragment declares, and team is one of them, so a
	# repository that names no team is already answered DEFAULT_TEAM by
	# the line above and an arm below it could never run.
	my $team = $opts{team}
		// $self->provider_option('team');

	# Pipeline name: call-site override > provider_opts > config name > deployment_type
	my $pipeline_name = $opts{pipeline_name}
		// $self->provider_option('pipeline_name')
		// $self->{config}{pipeline}{name}
		// ($self->{top} ? $self->{top}->type : undef);
	bail("Cannot determine pipeline name.  Set pipeline.name, or ensure ".
		"deployment_type is set")
		unless $pipeline_name;

	# Pause/expose/dry-run/insecure: call-site override > provider_opts > defaults
	my $dry_run  = $opts{'dry-run'};
	my $yes      = $opts{yes};
	my $pause    = $opts{pause_after_set}
		// $self->provider_option('pause_after_set')
		// DEFAULT_PAUSE_AFTER_SET;
	my $expose   = $opts{expose}
		// $self->provider_option('expose')
		// _yaml_bool(($self->{config}{pipeline} || {})->{public}, DEFAULT_EXPOSE);
	my $insecure = $opts{insecure}
		// $self->provider_option('insecure')
		// DEFAULT_INSECURE;

	my $yaml = $self->generate();

	if ($dry_run) {
		output({raw => 1}, $yaml);
		return;
	}

	my $k_flag = $insecure ? ' -k' : '';

	# Pause pipeline before updating (safe to do even when not found yet)
	my ($out, $rc) = run(
		"fly${k_flag} -t \$1 pause-pipeline -p \$2",
		$target, $pipeline_name
	);
	bail("Could not pause pipeline '%s': %s", $pipeline_name, $out)
		unless $rc == 0 || $out =~ /pipeline '.*' not found/;

	# Write pipeline to temp file
	my $dir = workdir;
	mkfile_or_fail("${dir}/pipeline.yml", $yaml);

	# Upload pipeline
	my $yes_flag  = $yes ? ' -n' : '';
	my $team_flag = " --team=$team";
	run({
		interactive => 1,
		onfailure => "Could not upload pipeline $pipeline_name",
	},
		"fly${k_flag} -t \$1 set-pipeline${yes_flag}${team_flag} -p \$2 -c \$3/pipeline.yml",
		$target, $pipeline_name, $dir
	);

	# Unpause pipeline (unless pipeline.provider.pause_after_set or --ci-pause)
	unless ($pause) {
		run({
			interactive => 1,
			onfailure => "Could not unpause pipeline $pipeline_name",
		},
			"fly${k_flag} -t \$1 unpause-pipeline -p \$2",
			$target, $pipeline_name
		);
	}

	# Set visibility (expose vs hide)
	my $action = $expose ? 'expose' : 'hide';
	run({
		interactive => 1,
		onfailure => "Could not $action pipeline $pipeline_name",
	},
		"fly${k_flag} -t \$1 ${action}-pipeline -p \$2",
		$target, $pipeline_name
	);

	return;
}

# }}}
# platform_name - return platform name {{{
sub platform_name {
	return "Concourse";
}

# }}}
# file_extension - return file extension {{{
sub file_extension {
	return ".yml";
}

# }}}
# }}}
### Compiler Pipeline Interface {{{

# generate_from_ast - generate Concourse pipeline from AST {{{
sub generate_from_ast {
	my ($self, $ast) = @_;

	my $source = $ast->metadata->{source} || '';

	# For legacy-sourced ASTs with raw pipeline data, bridge to Legacy
	if ($source eq 'legacy'
		&& $ast->provider_config->{concourse}
		&& $ast->provider_config->{concourse}{_legacy_pipeline_raw}
		&& $self->{top}) {
		return $self->_generate_from_legacy_ast($ast);
	}

	# For all other ASTs, generate natively
	return $self->_generate_native($ast);
}

# }}}
# output_files - describe generated files {{{
sub output_files {
	return { 'pipeline.yml' => 'Concourse pipeline definition' };
}

# }}}
# }}}
### Legacy AST Bridge {{{

# _generate_from_legacy_ast - bridge AST back to Legacy generator {{{
sub _generate_from_legacy_ast {
	my ($self, $ast) = @_;

	my $raw_p = $ast->provider_config->{concourse}{_legacy_pipeline_raw};

	# Get the first (typically only) workflow's legacy data
	my @wf_names = $ast->workflow_names;
	my $wf = $ast->workflows->{$wf_names[0]};
	my $leg = $wf->{_legacy} || {};

	# Reconstruct the fully-parsed $P hashref that Legacy expects
	my $P = {
		pipeline => { %$raw_p },
		file     => $ast->metadata->{source_file} || 'ci.yml',
		envs     => $leg->{environments} || [],
		auto     => $leg->{auto_envs}    || [],
		aliases      => { %{$leg->{aliases}      || {}} },
		genesis_envs => { %{$leg->{genesis_envs} || {}} },
		will_trigger => { %{$leg->{will_trigger} || {}} },
		triggers     => ref($leg->{triggers}) eq 'HASH'
			? { %{$leg->{triggers}} } : {},
	};

	# Apply defaults (same as Legacy::parse)
	$P->{pipeline}{tagged}     = _yaml_bool($P->{pipeline}{tagged}, 0);
	$P->{pipeline}{public}     = _yaml_bool($P->{pipeline}{public}, 0);
	$P->{pipeline}{unredacted} = _yaml_bool($P->{pipeline}{unredacted}, 0);
	$P->{pipeline}{ocfp}       = _yaml_bool($P->{pipeline}{ocfp}, 0);
	if ($P->{pipeline}{vault}) {
		$P->{pipeline}{vault}{verify} = _yaml_bool($P->{pipeline}{vault}{verify}, 1);
	}
	$P->{pipeline}{task}{image}      ||= 'genesiscommunity/concourse';
	$P->{pipeline}{task}{version}    ||= 'latest';
	$P->{pipeline}{task}{privileged} ||= [];

	return Genesis::CI::Legacy::generate_pipeline_concourse_yaml($P, $self->{top});
}

# }}}
# }}}
### Native Concourse Generator {{{

# _generate_native - serialize the generic pipeline from AST to Concourse YAML {{{
sub _generate_native {
	my ($self, $ast) = @_;

	$self->_ensure_pipeline_resolved();

	# Serialize the generic pipeline to Concourse YAML
	my $pipeline = {
		groups         => $ast->groups,
		resources      => $ast->pipeline_resources,
		resource_types => $ast->resource_types,
		jobs           => $ast->jobs,
	};

	return "---\n" . $self->dump_yaml($pipeline) . "\n";
}

# }}}
# }}}
### Additional Concourse-Specific Methods {{{

# graph_md - generate pipeline.md with Mermaid flowchart {{{
sub graph_md {
	my ($self) = @_;

	bail("Must call parse() before graph_md()") unless $self->{config};

	# Legacy fallback: no Mermaid support; return minimal document
	if ($self->{_platform} && $self->{_platform} eq 'legacy') {
		my $name = ($self->{config}{pipeline} || {})->{name} || 'pipeline';
		return "# Pipeline: $name\n\n*(Legacy provider, graph not available)*\n";
	}

	# Native Mermaid from AST
	bail("No AST available; call parse() first") unless $self->{ast};
	$self->_ensure_pipeline_resolved();
	return $self->{ast}->pipeline_md();
}

# }}}
# generate_description - alias for describe(); called by Genesis::Commands::Pipelines {{{
sub generate_description { $_[0]->describe() }

# }}}
# describe - generate human-readable description {{{
sub describe {
	my ($self) = @_;

	bail("Must call parse() before describe()") unless $self->{config};

	# Legacy fallback
	if ($self->{_platform} && $self->{_platform} eq 'legacy') {
		Genesis::CI::Legacy::generate_pipeline_human_description(
			$self->{config}
		);
		return;
	}

	# Native description from AST
	bail("No AST available; call parse() first") unless $self->{ast};
	$self->_ensure_pipeline_resolved();
	output({raw => 1}, $self->{ast}->description());
	return;
}

# }}}
# }}}
### Accessors {{{

# config - get parsed configuration {{{
sub config {
	return $_[0]->{config};
}

# }}}
# top - get Genesis::Top object {{{
sub top {
	return $_[0]->{top};
}

# }}}
# layout - get layout name {{{
sub layout {
	return $_[0]->{layout};
}

# }}}
# }}}
### Internal Helpers {{{

# _ensure_pipeline_resolved - resolve pipeline via PipelineDescriptor if needed {{{
sub _ensure_pipeline_resolved {
	my ($self) = @_;
	my $ast = $self->{ast} or return;
	unless ($ast->pipeline && %{$ast->pipeline}) {
		my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(
			ast => $ast,
			top => $self->{top},
		);
		$ast->set_pipeline($descriptor->describe());
	}
}

# }}}
# _yaml_bool - handle yaml boolean values with defaults {{{
sub _yaml_bool {
	my ($bool, $default) = @_;
	return ($default || 0) unless defined $bool;
	return $bool ? 1 : 0;
}

# }}}
# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
