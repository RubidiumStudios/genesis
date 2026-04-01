package Genesis::Commands::Pipeline;
use strict;
use warnings;

use Genesis;
use Genesis::Commands;
use Genesis::Top;
use Genesis::CI::Compiler;
use JSON::PP;
use File::Basename qw/dirname/;

### Public Command Functions {{{

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
	my $result = _compile($top, $platform, $opts);

	_dump_debug_artifacts($opts->{'debug-dir'}, $result, $platform)
		if $opts->{'debug-dir'};

	my $ast    = $result->{ast};
	my $output = $result->{output};

	my $name = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");

	# --output-dir: write artifacts to directory and exit
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
		my $yaml = $output->{'pipeline.yml'}
			or bail("Concourse provider did not produce pipeline.yml");

		if ($opts->{'dry-run'}) {
			output({raw => 1}, $yaml);
			exit 0;
		}

		my $target = $opts->{target} || $layout || $name;

		my ($out, $rc) = run('fly -t $1 pause-pipeline -p $2', $target, $name);
		bail("Could not pause #c{%s} pipeline: %s", $name, $out)
			unless $rc == 0 || $out =~ /pipeline '.*' not found/;

		my $yes = $opts->{yes} ? ' -n ' : '';
		my $dir = workdir;
		mkfile_or_fail("$dir/pipeline.yml", $yaml);
		run({ interactive => 1, onfailure => "Could not upload pipeline $name" },
			'fly -t $1 set-pipeline '.$yes.' -p $2 -c $3/pipeline.yml',
			$target, $name, $dir);

		unless ($opts->{paused}) {
			run({ interactive => 1, onfailure => "Could not unpause pipeline $name" },
				'fly -t $1 unpause-pipeline -p $2',
				$target, $name);
		}

		my $public = $ast->configuration->{public} || 0;
		my $action = $public ? 'expose' : 'hide';
		run({ interactive => 1, onfailure => "Could not $action pipeline $name" },
			'fly -t $1 '.$action.'-pipeline -p $2',
			$target, $name);

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
# graph - write pipeline.md with Mermaid flowchart (replaces genesis graph) {{{
sub graph {
	my ($layout) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';
	my $top      = Genesis::Top->new('.');

	my $result   = _compile($top, $platform, $opts);
	my $ast      = $result->{ast};
	my $provider = $result->{provider};

	my $md;
	if ($provider->can('graph_md')) {
		$md = $provider->graph_md();
	} else {
		$md = _mermaid_md($ast);
	}

	mkfile_or_fail('pipeline.md', $md);
	info("Wrote #C{pipeline.md}");
	exit 0;
}

# }}}
# describe - human-readable pipeline progression (replaces genesis describe) {{{
sub describe {
	my ($layout) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';
	my $top      = Genesis::Top->new('.');

	my $result   = _compile($top, $platform, $opts);
	my $ast      = $result->{ast};
	my $provider = $result->{provider};

	if ($provider->can('generate_description')) {
		$provider->generate_description($ast);
	} else {
		_print_description($ast, $platform);
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
	my $result = _compile($top, $platform, $opts);
	my $ast    = $result->{ast};
	my $output = $result->{output};

	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my $target = $opts->{target} || $name;

	my $compiled = $output->{'pipeline.yml'}
		or bail("Concourse provider did not produce pipeline.yml");

	my $dir = workdir;
	mkfile_or_fail("$dir/compiled.yml", $compiled);

	my ($live, $rc) = run('fly -t $1 get-pipeline -p $2', $target, $name);
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
	my $result = _compile($top, $platform, $opts);
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my $target = $opts->{target} || $name;

	my ($json_out, $rc) = run('fly -t $1 jobs -p $2 --json', $target, $name);
	bail("Could not get jobs for pipeline '%s' on target '%s': %s", $name, $target, $json_out)
		unless $rc == 0;

	my $jobs;
	eval { $jobs = JSON::PP->new->decode($json_out) };
	bail("Failed to parse fly jobs output: %s", $@) if $@;

	output "#G{Pipeline}: #C{%s}  (#Yi{target}: %s)", $name, $target;
	output "";

	my $col_w = 40;
	output "  %-${col_w}s  %-10s  %s", "Environment", "Status", "Notes";
	output "  %s  %s  %s", '-' x $col_w, '-' x 10, '-' x 20;

	for my $job (sort { $a->{name} cmp $b->{name} } @$jobs) {
		next if $filter_env && $job->{name} ne $filter_env;

		my $status = _job_status_label($job);
		my @notes;
		push @notes, 'paused'  if $job->{paused};
		push @notes, 'errored' if ($job->{finished_build} || {})->{status} eq 'errored';

		output "  %-${col_w}s  %-10s  %s",
			$job->{name},
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
	my $result = _compile($top, $platform, $opts);
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my $target = $opts->{target} || $name;

	if ($env) {
		run({ interactive => 1,
		      onfailure => "Could not pause job '$env' in pipeline '$name'" },
			'fly -t $1 pause-job -p $2 -j $3',
			$target, $name, $env);
		info("Paused job #C{%s} in pipeline #C{%s}", $env, $name);
	} else {
		run({ interactive => 1,
		      onfailure => "Could not pause pipeline '$name'" },
			'fly -t $1 pause-pipeline -p $2',
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
	my $result = _compile($top, $platform, $opts);
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my $target = $opts->{target} || $name;

	if ($env) {
		run({ interactive => 1,
		      onfailure => "Could not resume job '$env' in pipeline '$name'" },
			'fly -t $1 unpause-job -p $2 -j $3',
			$target, $name, $env);
		info("Resumed job #C{%s} in pipeline #C{%s}", $env, $name);
	} else {
		run({ interactive => 1,
		      onfailure => "Could not resume pipeline '$name'" },
			'fly -t $1 unpause-pipeline -p $2',
			$target, $name);
		info("Resumed pipeline #C{%s}", $name);
	}
	exit 0;
}

# }}}
# }}}
### Internal Helpers {{{

# _compile - detect config source and run the compiler {{{
sub _compile {
	my ($top, $platform, $opts) = @_;

	my %compiler_opts = (top => $top);

	my $ci_dir = '.genesis/ci';
	if (-d $ci_dir && -f "$ci_dir/pipeline.yml") {
		$compiler_opts{ci_dir} = $ci_dir;
		info("Using multi-file configuration from #C{%s/}", $ci_dir);
	} elsif (Genesis::CI::Compiler->can_compile_from_env_files($ci_dir)) {
		$compiler_opts{ci_dir}  = $ci_dir;
		$compiler_opts{env_dir} = '.';
		info("Using env-file topology with config from #C{%s/}", $ci_dir);
	} else {
		$compiler_opts{file} = $opts->{config} || 'ci.yml';
		info("Using legacy configuration from #C{%s}", $compiler_opts{file});
	}

	my $compiler = Genesis::CI::Compiler->new(%compiler_opts);
	return $compiler->compile(provider => $platform);
}

# }}}
# _get_top - create a Genesis::Top object, with or without vault {{{
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
# _mermaid_md - generate Mermaid pipeline.md from a bare AST {{{
sub _mermaid_md {
	my ($ast) = @_;

	my $name  = $ast->metadata->{name} || 'genesis-pipeline';
	my @lines = ('flowchart LR');

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
			$alias =~ s/[^a-zA-Z0-9_]/_/g;
			push @lines, "  $alias";
		}
	}

	my $mermaid = join("\n", @lines) . "\n";
	return "# Pipeline: $name\n\n\`\`\`mermaid\n${mermaid}\`\`\`\n";
}

# }}}
# _print_description - human-readable AST description {{{
sub _print_description {
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
				my @order = eval { $ast->workflow_stage_order($wf_name) };
				my @stages = @order
					? map { $nodes->{$_}{alias} || $_ } @order
					: sort keys %$nodes;
				output "    Progression: %s", join(' -> ', @stages);
			}
		}
	}

	output "";
}

# }}}
# _dump_debug_artifacts - write compiler intermediates to a directory {{{
sub _dump_debug_artifacts {
	my ($debug_dir, $result, $platform) = @_;

	mkdir_or_fail($debug_dir);

	my $json = JSON::PP->new->pretty->canonical;

	if ($result->{parsed}) {
		mkfile_or_fail("$debug_dir/01-parsed.json", $json->encode($result->{parsed}));
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

		mkfile_or_fail("$debug_dir/02-ast-source.json", $json->encode(\%source));
		info("Debug: wrote #C{%s/02-ast-source.json}", $debug_dir);

		if ($ast->pipeline && %{$ast->pipeline}) {
			my %pipeline    = %{$ast->pipeline};
			my $pipeline_md = delete $pipeline{pipeline_md};
			my $description = delete $pipeline{description};
			delete $pipeline{mermaid};

			mkfile_or_fail("$debug_dir/03-pipeline.json", $json->encode(\%pipeline));
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
				mkfile_or_fail("$debug_dir/06-output-$file", $result->{output}{$file});
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

Genesis::Commands::Pipeline - Pipeline management command suite

=head1 DESCRIPTION

Implements the C<genesis pipeline-*> command family, replacing the legacy
C<repipe>, C<graph>, and C<describe> commands with a unified interface.

Commands are registered in C<bin/genesis> as flat names for 3.0.x
compatibility (C<genesis pipeline-apply>, C<genesis pipeline-graph>, etc.)
and the legacy C<repipe>/C<graph>/C<describe> remain as aliases.

=head1 COMMANDS

=over 4

=item B<pipeline-apply> [--platform PROVIDER] [--dry-run] [--paused]

Compile and deploy the pipeline. Replaces C<genesis repipe>.
Defaults to Concourse. Supports C<--dry-run> (print YAML only) and
C<--output-dir> (write artifacts to a directory).

=item B<pipeline-graph> [--platform PROVIDER]

Compile pipeline and write C<pipeline.md> containing a Mermaid flowchart.
Replaces C<genesis graph>.

=item B<pipeline-describe> [--platform PROVIDER]

Compile pipeline and print a human-readable ordered progression.
Replaces C<genesis describe>.

=item B<pipeline-diff> [--target TARGET]

Compare compiled pipeline YAML against the live pipeline via
C<fly get-pipeline>. Shows unified diff or reports no differences.

=item B<pipeline-status> [<env>] [--target TARGET]

Query C<fly jobs> for per-environment job status. Optionally filter to a
single environment.

=item B<pipeline-pause> [<env>] [--target TARGET]

Pause a specific environment's job, or the entire pipeline if no env given.

=item B<pipeline-resume> [<env>] [--target TARGET]

Resume a specific environment's job, or the entire pipeline if no env given.

=back

=head1 SEE ALSO

Genesis::Commands::Pipelines (legacy), Genesis::CI::Compiler

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
