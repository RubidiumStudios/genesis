package Genesis::CI::ProviderCompiler::Concourse;
use v5.20;
use warnings;

# Genesis::CI was the second parent, and it is gone.  Its trait had had
# one implementer since March 2026 and no caller at all, so the compiler
# base is the only parent now.
use parent 'Genesis::CI::ProviderCompiler';

use Genesis;
use Genesis::Exit ();
use Genesis::Term qw/in_controlling_terminal/;
use Genesis::UI qw/prompt_for_boolean/;
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
	DEFAULT_INSECURE        => 0,
	STATE_AFTER_APPLY_KEY   => 'pipeline.provider.pipeline_state_after_apply',
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
# describe_provider - structured self-description for display {{{
# Shaped as Genesis::Kit::Provider::Github::status() is.
sub describe_provider {
	my ($self) = @_;

	# Reported, never refused: a describe says what is missing (D86).
	my $found     = $self->provider->target_found;
	my $target    = defined $found->{target}
		? "$found->{target} ($found->{how})"
		: '(none): ' . (split /\n/, $found->{refusal} // '')[0];
	my $team      = $self->provider_option('team') // $self->provider->team;
	my $pipe_name = $self->provider_option('pipeline_name') || '(deployment type)';
	my $expose    = $self->provider_option('expose')    ? 'yes' : 'no';
	my $state     = $self->provider_option('pipeline_state_after_apply');
	my $insecure  = $self->provider_option('insecure')  ? 'yes' : 'no';

	my @extras = qw(Target Team Pipeline Expose StateAfterApply Insecure);
	my %desc = (
		type            => 'concourse',
		label           => 'Concourse',
		Target          => $target,
		Team            => $team,
		Pipeline        => $pipe_name,
		Expose          => $expose,
		StateAfterApply => $state,
		Insecure        => $insecure,
		status          => 'ok',
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
sub deploy {
	my ($self, %opts) = @_;
	my $config = $self->{config} || {}; # set only on the parse() path

	# All keys use config-file names (target, team, pipeline_name, expose), but
	# pipeline_state, which is the run's own answer to pipeline_state_after_apply.
	# Callers are responsible for normalizing cli-prefixed keys before calling deploy().

	# --- Resolve options from three tiers ---

	# A target only where the caller names one; the provider's fly finds it otherwise (D86).
	my $target = $opts{target};

	# The provider answers its default where the configuration names none.
	my $team = $opts{team}
		// $self->provider_option('team')
		// $self->provider->team;

	# Pipeline name: call-site override > provider_opts > config name > deployment_type
	my $pipeline_name = $opts{pipeline_name}
		// $self->provider_option('pipeline_name')
		// ($config->{pipeline} || {})->{name}
		// ($self->{top} ? $self->{top}->type : undef);
	bail("Cannot determine pipeline name.  Set pipeline.name, or ensure ".
		"deployment_type is set")
		unless $pipeline_name;

	# Expose/dry-run/insecure: call-site override > provider_opts > defaults
	my $dry_run  = $opts{'dry-run'};
	my $yes      = $opts{yes};

	# The pause state to end in: this run's flag, else the key (D184).
	my $state = $opts{pipeline_state}
		// $self->provider_option('pipeline_state_after_apply');
	my $state_why = defined $opts{pipeline_state} ? "--$state" : STATE_AFTER_APPLY_KEY;

	my $expose   = $opts{expose}
		// $self->provider_option('expose')
		// _yaml_bool(($config->{pipeline} || {})->{public}, DEFAULT_EXPOSE);
	my $insecure = $opts{insecure}
		// $self->provider_option('insecure')
		// DEFAULT_INSECURE;

	# The compiled pipeline the apply hands over, or the parse() path's own.
	my $yaml = $opts{yaml} // $self->generate();

	if ($dry_run) {
		output({raw => 1}, $yaml);
		return;
	}

	# Every fly below is the provider's, which names the binary and the target.
	my $provider = $self->provider;
	my %at       = ((defined $target ? (target => $target) : ()), insecure => $insecure);

	# Write pipeline to temp file
	my $dir = workdir;
	mkfile_or_fail("${dir}/pipeline.yml", $yaml);

	# The apply asks its own question before the pipeline is touched, because
	# fly answers a declined confirmation with exit 0 and its prompt writes to
	# the terminal, so its answer cannot be read back (T440).  Concourse is
	# asked whether it would take the pipeline, then what setting it would
	# change.
	my ($valid, $vrc) = $provider->fly({%at}, 'validate-pipeline', '-c', "$dir/pipeline.yml");
	bail({exitcode => Genesis::Exit::CONFIG},
		"The compiled pipeline is not one Concourse would accept:\n\n%s",
		$valid // 'fly gave no reason') if $vrc;

	my ($dry, $drc) = $provider->fly({%at}, 'set-pipeline', '--team', $team,
		'-p', $pipeline_name, '-c', "$dir/pipeline.yml", '--dry-run');
	my $asked = !($drc && ($dry // '') =~ /unknown flag/);
	bail("Could not compare pipeline %s through fly: %s", $pipeline_name,
		$dry // 'no reason given') if $asked && $drc;

	# Read ahead of the pause below, which would otherwise be all there is to find.
	my %pause = (state => $state, why => $state_why);
	$pause{found} = $self->_found_pause_state(\%at, $pipeline_name, $team)
		if $state eq 'unchanged';

	if ($asked) {
		if (($dry // '') =~ /no changes to apply/) {
			info("  #Ki{already set} #C{%s}: it matches what this run compiled",
				$pipeline_name);
			$self->_settle_pause_state(\%at, $pipeline_name, %pause, set => 0);
			return;
		}
		(my $shown = $dry // '') =~ s/\n*\S*pipeline name:.*\z//s;
		info({raw => 1}, "%s\n", $shown);

		unless ($yes) {
			bail({exitcode => Genesis::Exit::ABORTED},
				"Nothing was set: there is no terminal to confirm the change to ".
				"#C{%s} at.  Review it above, then run with #C{-y} to set it.",
				$pipeline_name) unless in_controlling_terminal();
			bail({exitcode => Genesis::Exit::ABORTED},
				"Nothing was set: the change to #C{%s} was declined.", $pipeline_name)
				unless prompt_for_boolean("Set pipeline $pipeline_name? [y|n]", 0);
		}
	}

	# Pause pipeline before updating (safe to do even when not found yet)
	my ($out, $rc) = $provider->fly({%at}, 'pause-pipeline', '-p', $pipeline_name);
	bail("Could not pause pipeline '%s': %s", $pipeline_name, $out)
		unless $rc == 0 || $out =~ /pipeline '.*' not found/;

	# Upload pipeline: confirmed above, so fly asks nothing; a fly with no
	# --dry-run still asks itself, as before.
	$provider->fly({%at, interactive => 1,
		onfailure => "Could not upload pipeline $pipeline_name"},
		'set-pipeline', (($yes || $asked) ? ('-n') : ()), '--team', $team,
		'-p', $pipeline_name, '-c', "$dir/pipeline.yml");

	$self->_settle_pause_state(\%at, $pipeline_name, %pause, set => 1);

	# Set visibility (expose vs hide)
	my $action = $expose ? 'expose' : 'hide';
	$provider->fly({%at, interactive => 1,
		onfailure => "Could not $action pipeline $pipeline_name"},
		"$action-pipeline", '-p', $pipeline_name);

	return;
}

# }}}
# _found_pause_state - paused, unpaused or new, as Concourse holds the pipeline {{{
sub _found_pause_state {
	my ($self, $at, $name, $team) = @_;

	# Apart from stdout, where a fly out of step with its Concourse warns.
	my ($out, $rc, $err) = $self->provider->fly({%$at, stderr => 0}, 'pipelines', '--json');
	my $list = $rc ? undef : eval {JSON::PP->new->decode($out // '')};
	bail(
		"Could not read whether pipeline #C{%s} is paused, which leaving it ".
		"as it was found needs: %s\n\nNothing was paused or set.  Run with ".
		"#C{--paused} or #C{--unpaused} to say which state to leave it in, ".
		"which needs no reading.",
		$name, $rc ? ($err || $out || 'fly gave no reason')
		           : '`fly pipelines --json` did not answer with a list'
	) unless ref($list) eq 'ARRAY';

	my ($held) = grep {
		ref($_) eq 'HASH'
			&& ($_->{name} // '') eq $name
			&& (!defined $_->{team_name} || $_->{team_name} eq $team)
			&& !$_->{instance_vars}
	} @$list;
	return 'new' unless $held;
	return $held->{paused} ? 'paused' : 'unpaused';
}

# }}}
# _settle_pause_state - leave the pipeline in the state asked for, and say which {{{
sub _settle_pause_state {
	my ($self, $at, $name, %is) = @_;
	my ($state, $found) = @is{qw/state found/};

	my $end = $state ne 'unchanged' ? $state
	        : $found eq 'new'       ? 'paused'
	        :                         $found;

	# A run that set the pipeline paused it first; one that did not left it as found.
	my $act = $is{set} ? $end eq 'unpaused' : $state ne 'unchanged';
	if ($act) {
		my $verb = $end eq 'paused' ? 'pause' : 'unpause';
		$self->provider->fly({%$at, interactive => 1,
			onfailure => "Could not $verb pipeline $name"},
			"$verb-pipeline", '-p', $name);
	}

	my $because =
		  $state ne 'unchanged' ? "as #C{$is{why}} asks"
		: $found eq 'new'       ? "a new pipeline, which Concourse creates paused; ".
		                          "#C{--unpaused} starts it, as #C{genesis pipeline-resume} does"
		: $end eq 'paused'      ? "as it was found; #C{--unpaused} starts it"
		:                         "as it was found";
	$because .= sprintf(" (#C{%s: unchanged})", STATE_AFTER_APPLY_KEY)
		if $state eq 'unchanged';
	info("  #Ki{%s} #C{%s}: %s", $end, $name, $because);
	return $end;
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
