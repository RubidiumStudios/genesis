package Genesis::CI::Compiler;
use strict;
use warnings;

use Genesis;
use Genesis::Exit qw/CONFIG/;
use Genesis::CI::Compiler::Parser;
use Genesis::CI::Compiler::Validator;
use Genesis::CI::Compiler::ScriptDiscovery;
use Genesis::CI::Compiler::ASTBuilder;
use Genesis::CI::Compiler::PipelineDescriptor;

# Register as the owner of the pipeline: section in .genesis/config.
# This runs at module load time so Top.pm's _validate_config() can
# delegate pipeline: section validation to us when we're loaded.
# The section is named pipeline while this namespace is not, because the
# compiler genuinely is CI and renaming it would be churn with nothing
# user-visible to show for it.
{
	require Genesis::Top;
	Genesis::Top->register_config_section('pipeline', __PACKAGE__);
}

### Constructor {{{

# new - create a new compiler instance {{{
sub new {
	my ($class, %opts) = @_;

	return bless({
		ci_dir  => $opts{ci_dir},
		file    => $opts{file},
		env_dir => $opts{env_dir},
		top     => $opts{top},
	}, $class);
}

# }}}
# }}}
### Public Methods {{{

# compile - run the full compilation pipeline {{{
sub compile {
	my ($self, %opts) = @_;

	my $provider_type = $opts{provider}
		or bail("Missing required 'provider' parameter for compile()");

	# Stage 1: Parse configuration
	info("Parsing pipeline configuration...");
	my $parser = Genesis::CI::Compiler::Parser->new(
		ci_dir => $self->{ci_dir},
		file   => $self->{file},
		top    => $self->{top},
	);
	my $parsed = $parser->parse();

	# Stage 2: Validate
	info("Validating configuration...");
	my $validator = Genesis::CI::Compiler::Validator->new(top => $self->{top});
	$validator->validate($parsed);

	if ($validator->has_warnings) {
		for my $warn (@{$validator->warnings}) {
			error("#Y{warning}: %s", $warn);
		}
	}

	if ($validator->has_errors) {
		error("#R{ERRORS encountered} in pipeline configuration:");
		error("  - #R{%s}", $_) for @{$validator->errors};
		bail("Pipeline configuration is invalid");
	}

	# Stage 3: Discover scripts
	info("Discovering scripts...");
	my $script_discovery = Genesis::CI::Compiler::ScriptDiscovery->new(
		repo_path => '.',
	);
	my $scripts = $script_discovery->discover($parsed);

	# Stage 4: Build AST (source representation)
	info("Building pipeline AST...");
	my $ast_builder = Genesis::CI::Compiler::ASTBuilder->new(
		top     => $self->{top},
		env_dir => $self->{env_dir},
	);
	my $ast = $ast_builder->build($parsed, $scripts);

	# Stage 5: Resolve generic pipeline from source representation
	info("Resolving pipeline...");
	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(
		ast => $ast,
		top => $self->{top},
	);
	$ast->set_pipeline($descriptor->describe());

	# Stage 6: Load and run provider
	# Stage 6 continued: generate platform-specific output
	info("Generating %s pipeline...", $provider_type);
	require Genesis::CI::ProviderRegistry;
	my $provider_class =
		Genesis::CI::ProviderRegistry->compiler_class($provider_type);

	# Extract provider options from parsed config (pipeline.provider: section)
	# and merge with any caller-supplied opts.  Normalize caller opts from their
	# CLI form (ci-* prefixed, hyphenated) to config/schema form (unprefixed, underscored)
	# so that provider_option() and provider_config() always see consistent keys.
	require Genesis::CI::ProviderCompiler;
	my $provider_opts = {
		%{ $parsed->{provider} || {} },
		%{ Genesis::CI::ProviderCompiler->normalize_provider_opts(
			$opts{provider_opts} || {}
		) },
	};

	my $provider = $provider_class->new(
		ast           => $ast,
		top           => $self->{top},
		provider_opts => $provider_opts,
	);
	my $raw_output = $provider->generate_from_ast($ast);

	# Wrap raw output into file map using provider's output_files manifest
	my $output;
	if (ref($raw_output) eq 'HASH') {
		$output = $raw_output;
	} else {
		my $files = $provider->output_files || {};
		my @filenames = keys %$files;
		my $filename = @filenames ? $filenames[0] : 'pipeline.yml';
		$output = { $filename => $raw_output };
	}

	# Stage 7: Apply provider-specific overrides (optional)
	$output = $self->_apply_provider_overrides($output, $provider_type);

	return {
		ast      => $ast,
		output   => $output,
		provider => $provider,
		parsed   => $parsed,
	};
}

# }}}
# }}}
### Class Methods {{{

# can_compile - detect if a named directory holds a pipeline.yml {{{
#
# D27 took the conventional directory away, so there is no name to fall
# back on and the caller says which directory it means.  A caller that
# names none is asking about nowhere, and the answer is no.
sub can_compile {
	my ($class, $ci_dir) = @_;
	return 0 unless $ci_dir;

	return (-d $ci_dir && -f "$ci_dir/pipeline.yml");
}

# }}}
# can_compile_from_env_files - detect a directory built for env-file topology {{{
#
# Returns true when the named directory is present and contains the
# required support files (targets.yml + integrations.yml), even if there is
# no pipeline.yml (topology coming from genesis.pipeline.* in env files).
# The directory is named by the caller for the same reason as above.
sub can_compile_from_env_files {
	my ($class, $ci_dir) = @_;
	return 0 unless $ci_dir;

	return (
		-d  $ci_dir &&
		-f  "$ci_dir/targets.yml" &&
		-f  "$ci_dir/integrations.yml" &&
		!-f "$ci_dir/pipeline.yml"
	);
}

# }}}
# can_compile_from_genesis_config - detect the pipeline section in .genesis/config {{{
#
# Returns true when $top has a Genesis::Config with a pipeline: key,
# meaning the pipeline configuration is embedded inline in .genesis/config
# rather than in separate files.  The section is named pipeline under D18,
# so the read is by that name and there is no alias for its old spelling.
sub can_compile_from_genesis_config {
	my ($class, $top) = @_;
	return 0 unless $top && $top->can('config');
	return 0 unless eval { $top->config->has('pipeline') };
	return 1;
}

# }}}
# validate_config_section - the pipeline section's owner check {{{
#
# Under D86 the declarative half runs in Top, which merges this provider's
# fragment into the schema before Genesis::Config::validate sees it, so
# there is no per-key loop here any more.  What is left is the shape check
# the schema cannot state, which the next task fills in.
sub validate_config_section {
	my ($class, $data, $top) = @_;

	return unless defined $data;
	bail("'pipeline' configuration in .genesis/config must be a hash")
		unless ref($data) eq 'HASH';

	return 1;
}

# }}}
# }}}
### Internal Methods {{{

# override_file_names - the override files this run may merge {{{
#
# D27 put the override beside .genesis/config and took the old CI
# subdirectory away, because a file whose name says what it is needs no
# subdirectory to say it again.  D67 generalised the name for a provider
# that emits more than one file: that provider takes one override per
# emitted file, named by the file's base name without its extension,
# because it would have nothing to merge a single override onto.  Under
# D101 the form follows the effective output_layout rather than the
# capability, so a multi-file provider set to single takes the single
# form.
#
# The whole output name goes into the override name, directory and all,
# with the separators flattened to dashes so the result is still one
# path segment.  Dropping the directory would let a provider that emits
# qa/deploy.yml and prod/deploy.yml merge both against the same override
# file, and nothing in the run would say so.
sub override_file_names {
	my ($class, $provider_type, $output_names, $layout) = @_;

	return (".genesis/pipeline-overrides-${provider_type}.yml")
		unless ($layout // 'single') eq 'multiple';

	return map {
		(my $base = $_) =~ s{\.[^./]+$}{};
		$base =~ s{^\./+}{};
		$base =~ s{/+}{-}g;
		".genesis/pipeline-overrides-${provider_type}-${base}.yml"
	} @$output_names;
}

# }}}
# _apply_provider_overrides - merge the override files over the output {{{
#
# The merge is unchanged: verbatim YAML merged over the generated output
# after compilation, with a non-YAML output passing through untouched.
# What changed is where the file is found and what it is called.
sub _apply_provider_overrides {
	my ($self, $output, $provider_type) = @_;

	my $top    = $self->{top} or bug("The compiler has no Genesis::Top");
	my $layout = $top->config->get('pipeline.provider.output_layout', 'single');
	my @files  = sort keys %$output;
	my @names  = $self->override_file_names($provider_type, \@files, $layout);

	# One override per emitted file under the multi-file form, and one
	# override for everything under the single form.
	my $single = (@names == 1);
	my %override_for;
	if ($single) {
		my $path = $top->path($names[0]);
		$override_for{$_} = $path for @files;
	} else {
		$override_for{$files[$_]} = $top->path($names[$_]) for 0..$#files;
	}

	$self->_report_unread_overrides($top, $provider_type, \@files, $layout,
		\%override_for);

	# Only YAML files are spruce-merged, and only where the override the
	# layout names is actually there, so the notice and the loop below
	# both read the same list.
	my @mergeable = grep {
		/\.ya?ml$/i && $override_for{$_} && -f $override_for{$_}
	} @files;
	return $output unless @mergeable;

	# Under the single form one override covers every emitted file, so the
	# notice belongs to the run rather than to each file in it, and
	# printing it inside the loop would read as several merges where there
	# was one.
	info("Applying %s...",
		humanize_path($override_for{$mergeable[0]}, base_dir => $top->path))
		if $single;

	my %wanted = map {$_ => 1} @mergeable;
	my $dir = workdir;
	my %merged;
	for my $filename (@files) {
		my $content  = $output->{$filename};
		my $override = $override_for{$filename};

		unless ($wanted{$filename}) {
			$merged{$filename} = $content;
			next;
		}

		info("Applying %s...", humanize_path($override, base_dir => $top->path))
			unless $single;

		my $base_path = "$dir/override-base-${filename}";
		open(my $fh, '>', $base_path)
			or bail("Cannot write temporary override base %s: %s", $base_path, $!);
		print $fh $content
			or bail("Cannot write to temporary override base %s: %s", $base_path, $!);
		close $fh
			or bail("Cannot flush temporary override base %s: %s", $base_path, $!);

		my ($merged_yaml, $rc) = run('spruce', 'merge', $base_path, $override);
		# A refusal a caller can act on: the override is the operator's
		# file, so a merge it cannot survive is a configuration problem
		# rather than the system one a bare 1 would report.
		bail({exitcode => CONFIG},
			"Failed to apply %s: spruce merge returned non-zero", $override)
			unless $rc == 0;

		$merged{$filename} = $merged_yaml;
	}

	return \%merged;
}

# }}}
# _report_unread_overrides - name the file the layout is passing over {{{
#
# The two naming forms are a layout apart, so an operator who writes one
# of them and then changes output_layout loses the merge with nothing
# said.  Wherever the name the layout reads is absent and the other
# form's file is on disk, say so, because a silent skip looks exactly
# like a merge that had nothing to add.
sub _report_unread_overrides {
	my ($self, $top, $provider_type, $files, $layout, $override_for) = @_;

	return unless grep {!-f $_} values %$override_for;

	my $other = ($layout // 'single') eq 'multiple' ? 'single' : 'multiple';
	my %read  = map {$_ => 1} values %$override_for;

	for my $name ($self->override_file_names($provider_type, $files, $other)) {
		my $path = $top->path($name);
		next if $read{$path} || !-f $path;
		warning(
			"Ignoring %s: the '%s' output layout reads %s instead.",
			humanize_path($path, base_dir => $top->path), $layout // 'single',
			join(', ', map {humanize_path($_, base_dir => $top->path)}
				sort keys %read)
		);
	}

	return;
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Compiler - CI pipeline compilation orchestrator

=head1 DESCRIPTION

Genesis::CI::Compiler orchestrates the full compilation pipeline:

  1. Parser    - Load configuration files (legacy or multi-file)
  2. Validator - Validate structure, cross-references, semantics
  3. ScriptDiscovery - Find and parse script metadata
  4. ASTBuilder - Construct platform-agnostic AST
  5. PipelineDescriptor - Resolve generic pipeline from source AST
  6. Provider  - Generate platform-specific output from AST
  7. Overrides - Deep-merge pipeline-overrides-<provider>.yml if present

=head1 SYNOPSIS

  # Compile from the pipeline: section of .genesis/config
  my $result = Genesis::CI::Compiler->new(
    top => $top_obj,
  )->compile(provider => 'concourse');

  # Compile from legacy ci.yml
  my $result = Genesis::CI::Compiler->new(
    file => 'ci.yml',
    top  => $top_obj,
  )->compile(provider => 'concourse');

  # Check whether a named directory holds a compilable pipeline
  if (Genesis::CI::Compiler->can_compile($some_dir)) {
    # Use compiler pipeline
  }

=head1 SEE ALSO

Genesis::CI, Genesis::CI::Compiler::Parser, Genesis::CI::Compiler::AST

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
