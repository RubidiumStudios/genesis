package Genesis::Commands::Bosh;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::Commands;
use Genesis::Top;
use Genesis::UI;
use JSON::PP;

# bosh - provide a wrapper around the bosh command {{{
sub bosh {
	append_options(redact => ! -t STDOUT);

	command_usage(1) unless @_;
	my $env = Genesis::Top->new('.')->load_env(shift(@_))->with_vault();

	my $bosh = $env->get_target_bosh(get_options());

	if (get_options->{connect}) {
		if (in_controlling_terminal) {
			my $call = $::CALL; # Silence single-use warning
			error(
				"This command is expected to be run in the following manner:\n".
				"  eval \"\$($::CALL)\"\n".
				"\n".
				"This will set the BOSH environment variables in the current shell"
			);
			exit 1;
		}
		my %bosh_envs = $bosh->environment_variables
			unless in_controlling_terminal;
		for (keys %bosh_envs) {
			(my $escaped_value = $bosh_envs{$_}||"") =~ s/"/"\\""/g;
			output 'export %s="%s"', $_, $escaped_value;
		}
		info "Exported environmental variables for BOSH director %s", $bosh->{alias};
		exit 0;
	} else {
		my ($out, $rc) = $bosh->execute({interactive => 1, dir => $ENV{GENESIS_ORIGINATING_DIR}}, @_);
		exit $rc;
	}
}

# }}}
# credhub - execute a credhub command for the target environment {{{
sub credhub {

	command_usage(1) unless @_;
	my $env = Genesis::Top->new('.')->load_env(shift(@_))->with_vault();

	# TODO: Support a --connect option similar to `bosh` command so that it
	#       will set the environment variables in the current shell.

	my ($cmd,@args) = @_;

	my ($bosh, $target) = $env->get_target_bosh(get_options());

	my $credhub = ($target eq 'self')
		? Service::Credhub->from_bosh($bosh)
		: $env->credhub;

	# Check for invalid commands in the context of Genesis-augmented CredHub
	# environments
	if ($cmd =~ m/^(l|login|a|api|o|logout)$/) {
		bail(
			"Command #C{genesis credhub %s} is not allowed in when Genesis is ".
			"managing authentication to CredHub",
			$cmd
		);
	}

	unless (get_options->{raw}) {

		# Find the name or path option, and make it magically work under the
		# environment's base path

		my $name_idx = index_of('-n', @args) // index_of('--name', @args);
		my $path_idx = index_of('-p', @args) // index_of('--path', @args) // index_of('--prefix', @args);

		# Commands that take a --name option only
		if ($cmd =~ m/^(g|get|s|set|n|generate|r|regenerate|d|delete)$/) {
			if (defined($name_idx)) {
				$args[$name_idx+1] = $credhub->base. $args[$name_idx+1]
					if ($args[$name_idx+1] !~ m/^\//);
			} else {
				# Can't generate a name if --name isn't present -- let credhub handle it
			}

		# Commands that take a --path or --prefix option (both use -p for short)
		} elsif ($cmd =~ m/^(e|export|interpolate|f|find)$/) {
			if (defined($path_idx)) {
				$args[$path_idx+1] = $credhub->base. $args[$path_idx+1]
					if ($args[$path_idx+1] !~ m/^\//);
			} else {
				unshift(@args, '-p', $credhub->base);
			}
		}
	}

	pushd($ENV{GENESIS_ORIGINATING_DIR});
	$env->notify(
		"Running #C{credhub %s} against CredHub server on #M{%s} (#C{%s}):\n",
		$cmd, $credhub->{name}, $credhub->{url}
	);
	my ($out, $rc) = $credhub->execute($cmd, @args);
	popd();
	if ($rc) {
		$env->notify(
			fatal => "command #C{credhub %s} failed with exit code #R{%d}\n",
			$cmd, $rc
		);
	} else {
		$env->notify(
			success => "command #C{credhub %s} succeeded!\n",
			$cmd
		);
	}
	exit $rc;
}


# }}}
sub logs {
	my %options = %{get_options()};
	my ($env_name, @extra_args) = @_;

	my $env = Genesis::Top->new('.')->load_env($env_name)->with_vault()->with_bosh();
	bail(
		"No bosh logs for environments deployed with #M{create-env}"
	) if $env->use_create_env;

	my @logs = $env->bosh_logs(@extra_args);
}

sub broadcast {
	my %options = %{get_options()};
	my ($env_name, @extra_args) = @_;

	my $targets = $options{on}; # default to all jobs

	my $env = Genesis::Top->new('.')->load_env($env_name)->with_vault()->with_bosh();
	my $bosh = $env->bosh;
	my ($out,$rc, $err) = read_json_from($bosh->execute({interactive => 0}, 'vms', '--json'));
	bail("Failed to fetch VM list: %s", $err) if $rc;
	my @vms = ();
	eval {
		@vms = @{$out->{Tables}[0]{Rows}};
	} or bail("Failed to parse VM list: %s", $@);

	my @errors = ();
	if ($targets) {
		my @instances = ();
		for my $target (@$targets) {
			my $search_target = $target;
			$search_target .= '/' unless $search_target =~ m{/};
			my @match = map {$_->{instance}} grep {$_->{instance} =~ m{^\Q$target\E}} @vms;
			if (@match) {
				push @instances, @match;
			} else {
				@errors = (@errors, ($target =~ m{/})
					? "No instances found matching specified instance ID #c{$target}"
					: "No instances found matching specified instance type #C{$target}");
			}
		}
		$targets = \@instances;
	} else {
		$targets = [map {$_->{instance}} @vms];
	}

	bail(
		"Errors were encountered while determining broadcast targets:\n%s",
		join("\n", map {"- $_"} @errors)
	) if @errors;

	for my $target ( uniq @$targets ) {
		info("\n" . ('=' x terminal_width()));
		info("#g{Broadcasting to }#C{%s}#g{...}", $target);
		info('-' x terminal_width());
		my ($out, $rc, $err) = $bosh->execute({interactive => 1}, 'ssh', $target, '--', @extra_args);
		error("Failed to broadcast to %s: %s", $target, $err) if $rc;
	}

	info("\n" . ('=' x terminal_width()));
	success("\nBroadcast complete!\n");
}

# bosh_configs - manage the bosh configs the environment synthesizes and the director holds {{{
my @BOSH_CONFIG_TYPES = qw(cloud runtime cpi);

sub bosh_configs {
	my %options = %{get_options()};
	my ($env_name, $action, @extra_args) = @_;

	command_usage(1, "Environment name is required") unless $env_name;

	$action //= 'upload';
	my @valid_actions = qw(upload list view compare delete summary);
	bail(
		"Invalid action: %s - expected one of: %s (leave blank for 'upload')",
		$action, sentence_join(@valid_actions)
	) unless grep {$_ eq $action} @valid_actions;

	bail("Too many arguments provided") if @extra_args > 0;

	bail(
		"Invalid config type: %s - expected one of: %s",
		$options{type}, sentence_join(@BOSH_CONFIG_TYPES)
	) if defined($options{type}) && !grep {$_ eq $options{type}} @BOSH_CONFIG_TYPES;

	my $env = Genesis::Top->new('.')->load_env($env_name)->with_vault();
	bail(
		"Environment #C{%s} is deployed with #M{create-env} and is not a BOSH ".
		"director, so there is no BOSH director to hold bosh configs for it.",
		$env->name
	) if $env->use_create_env && !$env->is_bosh_director;

	# The director that deploys this environment holds its cloud and cpi
	# configs.  A create-env director has no such director; its runtime
	# configs live on the director itself and are targeted per config.
	my $bosh = $env->use_create_env ? undef : $env->with_bosh->bosh;

	my $subcommand = "bosh_configs_$action";
	return (\&{$subcommand})->($env, $bosh, %options);
}

# }}}
# bosh_configs_summary - list each config the environment provides and whether the director holds an identical, different, or no copy {{{
sub bosh_configs_summary {
	my ($env, $bosh, %options) = @_;

	$env->notify("checking the bosh configs provided for #C{%s}...", $env->name);
	my ($configs, $notes) = _bosh_configs_provided($env, $bosh, %options);

	if (@$configs) {
		_bosh_configs_status($_) for @$configs;
		my $table = "| Type | Name | Director | Status |\n".
		            "|:-----|:-----|:---------|:-------|\n";
		$table .= sprintf(
			"| %s | %s | %s | %s |\n",
			$_->{type}, $_->{name}, $_->{bosh}->alias, _bosh_configs_status_label($_)
		) for @$configs;
		info("\n%s", build_markdown_table($table));
	} else {
		info(
			"\nNo bosh configs are provided for #C{%s}%s.",
			$env->name, _bosh_configs_filter_description(%options)
		);
	}
	_bosh_configs_notes($notes);
	return 1;
}

# }}}
# bosh_configs_upload - upload the synthesized configs to the director, after confirmation {{{
sub bosh_configs_upload {
	my ($env, $bosh, %options) = @_;
	my $yes = $options{yes} // 0;

	$env->notify("preparing the bosh configs for #C{%s}...", $env->name);

	# Cloud configs record network claims on the director, so their synthesis
	# and upload happen under the same network claims lock the deploy path
	# uses.  The lock is released on every exit path below.
	my $lock_held = 0;
	my $wants_cloud = (!$options{type} || $options{type} eq 'cloud')
		&& (!$options{name} || $options{name} eq $env->bosh_config_name)
		&& !$env->use_create_env
		&& $env->has_hook('cloud-config')
		&& $env->can_build_cloud_configs;

	# A signal while the lock is held has to unwind through the release below
	# instead of killing the process with the lock still on the director.
	local $SIG{INT}  = sub { die "Interrupted by user\n" };
	local $SIG{TERM} = sub { die "Terminated\n" };

	eval {
		if ($wants_cloud) {
			_bosh_configs_acquire_network_lock($env, $bosh, $yes);
			$lock_held = 1;
		}

		my ($configs, $notes) = _bosh_configs_provided($env, $bosh, %options);
		unless (@$configs) {
			info(
				"\nNo bosh configs are provided for #C{%s}%s, so there is nothing to upload.",
				$env->name, _bosh_configs_filter_description(%options)
			);
			_bosh_configs_notes($notes);
			return 1;
		}

		my @runtime_builds = ();
		my @runtime_skipped = ();
		my $failures = 0;
		for my $config (@$configs) {
			_bosh_configs_status($config);
			my $label = _bosh_configs_label($config);

			if ($config->{status} eq 'unsynthesized') {
				error("[[  - >>%s could not be synthesized; see the errors above.", $label);
				$failures++;
				next;
			}
			if ($config->{status} eq 'identical') {
				info("[[  - >>%s is #G{already up to date}.", $label);
				push @runtime_skipped, $config->{build} if $config->{type} eq 'runtime';
				next;
			}

			if ($config->{status} eq 'missing') {
				info(
					"[[  - >>%s is #R{missing} from the director; it would be created with:\n\n%s",
					$label, $config->{content}
				);
			} else {
				info(
					"[[  - >>%s is #Y{different} from the director's copy:\n\n%s\n",
					$label, $config->{diff}
				);
			}

			unless (_bosh_configs_confirm(sprintf(
				"Upload %s config #C{%s} to #M{%s} BOSH director? [y|n]",
				$config->{type}, $config->{name}, $config->{bosh}->alias
			), $yes, 1)) {
				info("[[  - >>#y{skipped} %s\n", $label);
				push @runtime_skipped, $config->{build} if $config->{type} eq 'runtime';
				next;
			}

			if ($config->{type} eq 'cloud') {
				_bosh_configs_upload_cloud($env, $config);
			} elsif ($config->{type} eq 'cpi') {
				_bosh_configs_upload_cpi($env, $config);
			} else {
				# Runtime configs are uploaded by the kit's runtime-config hook,
				# which also stores any secrets the build generated.
				push @runtime_builds, $config->{build};
			}
		}

		if (@runtime_builds) {
			my $requests = _bosh_configs_runtime_requests($env, $options{name});
			$env->run_hook(
				'runtime-config',
				args => {%$requests, map {($_ => JSON::PP::false)} @runtime_skipped},
				interactive => 0,
			);
		}

		_bosh_configs_notes($notes);
		bail(
			"%d bosh config%s could not be synthesized, so %s not uploaded.",
			$failures, $failures == 1 ? '' : 's', $failures == 1 ? 'it was' : 'they were'
		) if $failures;
		1;
	};
	my $err = $@;
	if ($lock_held && $bosh->network_locked_by_me) {
		info({pending => 1}, "[[  - >>releasing network claims lock on #M{%s} BOSH director...", $bosh->alias);
		$bosh->clear_network_lock();
		info "#G{done}";
	}
	die $err if $err;
	return 1;
}

# }}}
# bosh_configs_list - list the configs on the director that belong to this environment {{{
sub bosh_configs_list {
	my ($env, $bosh, %options) = @_;

	my @directors = _bosh_configs_directors($env, $bosh);
	$env->notify(
		"listing the bosh configs on %s that belong to #C{%s}...",
		join(' and ', map {"#M{".$_->alias."}"} @directors), $env->name
	);

	my @rows = _bosh_configs_uploaded($env, $bosh, %options);
	unless (@rows) {
		info(
			"\nNo bosh configs belonging to #C{%s}%s were found on %s.",
			$env->name, _bosh_configs_filter_description(%options),
			join(' or ', map {"#M{".$_->alias."}"} @directors)
		);
		return 1;
	}

	my $table = "| Type | Name | Director | ID | Uploaded | Versions |\n".
	            "|:-----|:-----|:---------|---:|:---------|---------:|\n";
	for my $row (@rows) {
		my $entry = $row->{entry};
		my $id = $entry->{current};
		$table .= sprintf(
			"| %s | %s | %s | %s | %s | %d |\n",
			$row->{type}, $row->{name}, $row->{bosh}->alias,
			$id // '-', ($id ? $entry->{entries}{$id}{date} : '-'),
			scalar(keys %{$entry->{entries}})
		);
	}
	info("\n%s", build_markdown_table($table));
	return 1;
}

# }}}
# bosh_configs_view - print the synthesized config, or the director's copy with --uploaded {{{
sub bosh_configs_view {
	my ($env, $bosh, %options) = @_;

	if ($options{uploaded}) {
		my @rows = _bosh_configs_uploaded($env, $bosh, %options);
		bail(
			"No bosh configs belonging to #C{%s}%s were found on %s.",
			$env->name, _bosh_configs_filter_description(%options),
			join(' or ', map {"#M{".$_->alias."}"} _bosh_configs_directors($env, $bosh))
		) unless @rows;
		for my $row (@rows) {
			my $content = $row->{bosh}->get_config($row->{type}, $row->{name});
			bail(
				"%s config #C{%s} on #M{%s} BOSH director has no current version to show.",
				$row->{type}, $row->{name}, $row->{bosh}->alias
			) unless defined $content;
			_bosh_configs_print($row, $content, sprintf("uploaded to %s", $row->{bosh}->alias));
		}
		return 1;
	}

	$env->notify("synthesizing the bosh configs for #C{%s}...", $env->name);
	my ($configs, $notes) = _bosh_configs_provided($env, $bosh, %options);
	_bosh_configs_notes($notes);
	bail(
		"No bosh configs are provided for #C{%s}%s.",
		$env->name, _bosh_configs_filter_description(%options)
	) unless @$configs;

	my $failures = 0;
	for my $config (@$configs) {
		unless (defined $config->{content}) {
			error("[[  - >>%s could not be synthesized; see the errors above.", _bosh_configs_label($config));
			$failures++;
			next;
		}
		_bosh_configs_print($config, $config->{content}, 'synthesized');
	}
	bail(
		"%d bosh config%s could not be synthesized.",
		$failures, $failures == 1 ? '' : 's'
	) if $failures;
	return 1;
}

# }}}
# bosh_configs_compare - diff each synthesized config against the director's copy {{{
sub bosh_configs_compare {
	my ($env, $bosh, %options) = @_;

	$env->notify(
		"comparing the bosh configs provided for #C{%s} with the director's copies...",
		$env->name
	);
	my ($configs, $notes) = _bosh_configs_provided($env, $bosh, %options);
	unless (@$configs) {
		info(
			"\nNo bosh configs are provided for #C{%s}%s, so there is nothing to compare.",
			$env->name, _bosh_configs_filter_description(%options)
		);
		_bosh_configs_notes($notes);
		return 1;
	}

	for my $config (@$configs) {
		_bosh_configs_status($config);
		my $label = _bosh_configs_label($config);
		if ($config->{status} eq 'unsynthesized') {
			error("[[  - >>%s could not be synthesized; see the errors above.", $label);
		} elsif ($config->{status} eq 'missing') {
			info(
				"[[  - >>%s is #R{missing} from the director; the synthesized config is:\n\n%s",
				$label, $config->{content}
			);
		} elsif ($config->{status} eq 'identical') {
			info("[[  - >>%s is #G{identical} to the director's copy.", $label);
		} else {
			info(
				"[[  - >>%s is #Y{different} from the director's copy:\n\n%s\n",
				$label, $config->{diff}
			);
		}
	}
	_bosh_configs_notes($notes);
	return 1;
}

# }}}
# bosh_configs_delete - remove the named config from the director, after confirmation {{{
sub bosh_configs_delete {
	my ($env, $bosh, %options) = @_;

	bail(
		"The delete action needs the name of the config to remove; give it with ".
		"#y{--name} (the #C{list} action shows the names the director holds)."
	) unless defined $options{name};

	my @rows = _bosh_configs_uploaded($env, $bosh, %options);
	bail(
		"No bosh config named #C{%s}%s belonging to #C{%s} was found on %s.  Only ".
		"configs named for this environment can be deleted here; use ".
		"#C{genesis %s bosh delete-config} for anything else.",
		$options{name}, ($options{type} ? " of type #C{$options{type}}" : ''),
		$env->name,
		join(' or ', map {"#M{".$_->alias."}"} _bosh_configs_directors($env, $bosh)),
		$env->name
	) unless @rows;
	bail(
		"Config name #C{%s} matches %d configs (%s); specify #y{--type} to pick one.",
		$options{name}, scalar(@rows),
		sentence_join(map {sprintf("%s on %s", $_->{type}, $_->{bosh}->alias)} @rows)
	) if @rows > 1;

	my ($row) = @rows;
	unless (_bosh_configs_confirm(sprintf(
		"Delete %s config #C{%s} from #M{%s} BOSH director? [y|n]",
		$row->{type}, $row->{name}, $row->{bosh}->alias
	), $options{yes}, 0)) {
		info("[[  - >>#y{skipped}\n");
		return 1;
	}

	info({pending => 1},
		"[[  - >>deleting %s config #C{%s} from #M{%s} BOSH director...",
		$row->{type}, $row->{name}, $row->{bosh}->alias
	);
	$row->{bosh}->delete_config($row->{type}, $row->{name});
	info "#G{done}";
	return 1;
}

# }}}

# Internal helpers for the bosh-configs actions {{{
# _bosh_configs_provided - synthesize the configs the environment provides, honoring --type and --name {{{
sub _bosh_configs_provided {
	my ($env, $bosh, %options) = @_;
	my @configs = ();
	my @notes = ();
	my %wanted = map {$_ => 1} ($options{type} ? ($options{type}) : @BOSH_CONFIG_TYPES);
	my $name = $options{name};

	if ($wanted{cloud}) {
		if ($env->use_create_env) {
			push @notes, "cloud configs do not apply to a create-env director.";
		} elsif (!$env->has_hook('cloud-config')) {
			push @notes, sprintf(
				"kit #C{%s} provides no cloud-config hook, so no cloud config is synthesized.",
				$env->kit->id
			);
		} elsif (!$env->can_build_cloud_configs) {
			push @notes, "cloud configs are not managed by genesis for this environment.";
		} elsif (!defined($name) || $name eq $env->bosh_config_name) {
			my ($content, $network_map) = $env->run_hook('cloud-config');
			push @configs, {
				type        => 'cloud',
				name        => $env->bosh_config_name,
				bosh        => $bosh,
				content     => $content,
				network_map => $network_map,
			};
		}
	}

	if ($wanted{cpi}) {
		if ($env->use_create_env) {
			push @notes, "cpi configs do not apply to a create-env director.";
		} elsif (!$env->has_hook('cpi-config')) {
			push @notes, sprintf(
				"kit #C{%s} provides no cpi-config hook, so no cpi config is synthesized.",
				$env->kit->id
			);
		} elsif (!$env->is_ocfp || !$env->cpi_enabled) {
			push @notes, "cpi configs are not managed by genesis for this environment.";
		} elsif (!defined($name) || $name eq ($env->cpi_name // '')) {
			my $results = scalar $env->run_hook(
				'cpi-config', credhub_prefix => $env->cpi_credhub_base
			);
			bail(
				"The cpi-config hook reported errors: %s", $results->{error}
			) if $results->{error};
			push @configs, {
				type       => 'cpi',
				name       => $env->cpi_name,
				bosh       => $bosh,
				content    => $results->{content},
				cpi_config => $results,
			};
		}
	}

	if ($wanted{runtime}) {
		if (!$env->has_hook('runtime-config')) {
			push @notes, sprintf(
				"kit #C{%s} provides no runtime-config hook, so no runtime configs are synthesized.",
				$env->kit->id
			);
		} elsif (my $requests = _bosh_configs_runtime_requests($env, $name)) {
			my $collected = eval {
				$env->run_hook('runtime-config', args => $requests, collect => 1);
			};
			if (my $err = $@) {
				chomp($err);
				push @notes, sprintf("runtime configs could not be synthesized: %s", $err);
			} else {
				my $target = $env->is_bosh_director
					? scalar($env->get_target_bosh(self => 1))
					: $bosh;
				for my $entry (@{$collected // []}) {
					next if defined($name) && $name ne $entry->{name};
					push @configs, {
						type        => 'runtime',
						name        => $entry->{name},
						bosh        => $target,
						content     => $entry->{content},
						build       => $entry->{build},
						description => $entry->{description},
					};
				}
			}
		} elsif (!defined($name)) {
			push @notes, sprintf(
				"kit #C{%s} provides a runtime-config hook, but the environment enables ".
				"no runtime configs under #C{bosh-configs.runtime}.",
				$env->kit->id
			);
		}
	}

	return (\@configs, \@notes);
}

# }}}
# _bosh_configs_runtime_requests - the runtime-config hook requests for the enabled builds, or for one named config {{{
sub _bosh_configs_runtime_requests {
	my ($env, $name) = @_;
	my $enabled = $env->lookup('bosh-configs.runtime', undef);
	$enabled = {} unless ref($enabled) eq 'HASH';

	if (defined $name) {
		my $prefix = $env->bosh_config_name.'.';
		return undef unless index($name, $prefix) == 0 && length($name) > length($prefix);
		my $build = substr($name, length($prefix));
		my $opts = ref($enabled->{$build}) eq 'HASH' ? $enabled->{$build} : {};
		return {$build => $opts};
	}
	return keys(%$enabled) ? $enabled : undef;
}

# }}}
# _bosh_configs_status - compare a synthesized config with the director's copy and record the outcome on it {{{
sub _bosh_configs_status {
	my ($config) = @_;
	my $bosh = $config->{bosh};

	unless (defined $config->{content}) {
		$config->{status} = 'unsynthesized';
		return $config->{status};
	}
	unless ($bosh->has_config($config->{type}, $config->{name})) {
		$config->{status} = 'missing';
		return $config->{status};
	}

	my $uploaded = $bosh->get_config($config->{type}, $config->{name});
	my ($diff, $is_diff) = spruce_diff(
		{content => $uploaded,          label => 'uploaded'},
		{content => $config->{content}, label => 'synthesized'}
	);
	$config->{uploaded} = $uploaded;
	$config->{diff}     = $diff;
	$config->{status}   = $is_diff ? 'different' : 'identical';
	return $config->{status};
}

# }}}
# _bosh_configs_status_label - colored status word for the summary table {{{
sub _bosh_configs_status_label {
	my ($config) = @_;
	my %labels = (
		identical     => '#G{identical}',
		different     => '#Y{different}',
		missing       => '#R{missing}',
		unsynthesized => '#R{not synthesized}',
	);
	return $labels{$config->{status} // ''} // '#R{unknown}';
}

# }}}
# _bosh_configs_label - describe a config for progress lines {{{
sub _bosh_configs_label {
	my ($config) = @_;
	return sprintf(
		"%s config #C{%s} on #M{%s}",
		$config->{type}, $config->{name}, $config->{bosh}->alias
	);
}

# }}}
# _bosh_configs_filter_description - describe the --type and --name filters in effect {{{
sub _bosh_configs_filter_description {
	my (%options) = @_;
	my @parts = ();
	push @parts, "of type #C{$options{type}}" if $options{type};
	push @parts, "named #C{$options{name}}" if defined $options{name};
	return @parts ? ' '.join(' and ', @parts) : '';
}

# }}}
# _bosh_configs_notes - print the reasons a config type was left out {{{
sub _bosh_configs_notes {
	my ($notes) = @_;
	info("\n#Yi{Note:} %s", $_) for @{$notes // []};
	return 1;
}

# }}}
# _bosh_configs_print - print a config's content on stdout under a heading {{{
sub _bosh_configs_print {
	my ($config, $content, $source) = @_;
	info("\n#Cu{%s config %s} #Ki{(%s)}", $config->{type}, $config->{name}, $source);
	output({raw => 1}, "%s", $content);
	return 1;
}

# }}}
# _bosh_configs_confirm - ask before changing the director, unless --yes was given {{{
sub _bosh_configs_confirm {
	my ($question, $yes, $default) = @_;
	return 1 if $yes;
	bail(
		"Not in a controlling terminal, so cannot prompt for confirmation.  Use ".
		"#y{--yes} to skip the confirmation prompt."
	) unless in_controlling_terminal;
	return prompt_for_boolean($question, $default) ? 1 : 0;
}

# }}}
# _bosh_configs_directors - the directors that may hold this environment's configs {{{
sub _bosh_configs_directors {
	my ($env, $bosh) = @_;
	my @directors = grep {defined} ($bosh);
	if ($env->is_bosh_director) {
		my $self_director = eval { scalar($env->get_target_bosh(self => 1)) };
		push @directors, $self_director
			if $self_director && !grep {$_->alias eq $self_director->alias} @directors;
	}
	return @directors;
}

# }}}
# _bosh_configs_belongs_to_env - whether a director config name is one this environment owns {{{
sub _bosh_configs_belongs_to_env {
	my ($env, $type, $name) = @_;
	my $base = $env->bosh_config_name;
	return 1 if $name eq $base;
	return 1 if index($name, "$base.") == 0;
	return 1 if $type eq 'cpi'
		&& $env->has_hook('cpi-config')
		&& $env->cpi_enabled
		&& ($env->cpi_name // '') eq $name;
	return 0;
}

# }}}
# _bosh_configs_uploaded - the environment's configs currently on the directors, honoring --type and --name {{{
sub _bosh_configs_uploaded {
	my ($env, $bosh, %options) = @_;
	my @rows = ();
	for my $director (_bosh_configs_directors($env, $bosh)) {
		my $configs = $director->configs;
		for my $type (sort keys %$configs) {
			next if $options{type} && $options{type} ne $type;
			for my $name (sort keys %{$configs->{$type}}) {
				next if defined($options{name}) && $options{name} ne $name;
				next unless _bosh_configs_belongs_to_env($env, $type, $name);
				push @rows, {
					type  => $type,
					name  => $name,
					bosh  => $director,
					entry => $configs->{$type}{$name},
				};
			}
		}
	}
	return @rows;
}

# }}}
# _bosh_configs_acquire_network_lock - take the network claims lock before synthesizing a cloud config {{{
sub _bosh_configs_acquire_network_lock {
	my ($env, $bosh, $yes) = @_;

	info({pending => 1},
		"[[  - >>checking for existing network claims lock on #M{%s} BOSH director...",
		$bosh->alias
	);
	my $current_lock = $bosh->check_network_lock;
	if ($current_lock->{status} eq 'unlocked') {
		info "#G{available}";
	} elsif ($current_lock->{status} eq 'locked') {
		info "#r{locked} %s", $current_lock->{description};
		bail(
			"Network claims are currently locked -- cannot upload a cloud config now!"
		);
	} elsif ($current_lock->{status} eq 'stale') {
		info "#y{locked (stale)} %s", $current_lock->{description};
		if ($yes) {
			# proceed
		} elsif (in_controlling_terminal) {
			prompt_for_boolean(
				"Clear the stale network claims lock and continue? [y|n]", 0
			) or bail "Aborted by user!";
		} else {
			bail(
				"Network claims are locked with a stale lock: %s\n\nRerun with #y{--yes} ".
				"to clear it.", $current_lock->{description}
			);
		}
		$bosh->clear_network_lock;
		info "[[  - >>stale network claims lock cleared.";
	}

	info({pending => 1},
		"[[  - >>acquiring network claims lock on #M{%s} BOSH director...", $bosh->alias
	);
	$bosh->acquire_network_lock();
	info "#G{done}";
	return 1;
}

# }}}
# _bosh_configs_upload_cloud - upload a cloud config and record its network claims, as the deploy path does {{{
sub _bosh_configs_upload_cloud {
	my ($env, $config) = @_;
	my $bosh = $config->{bosh};

	my $last_check = $bosh->check_network_lock;
	bail(
		"Network claims lock was lost since it was acquired (it may have become ".
		"stale and been removed) -- cannot upload the cloud config!"
	) if ($last_check->{status} eq 'unlocked');

	info({pending => 1},
		"[[  - >>uploading cloud config #C{%s} to #M{%s} BOSH director...",
		$config->{name}, $bosh->alias
	);
	my ($out, $rc, $err) = $bosh->upload_config($config->{content}, 'cloud', $config->{name});
	if ($rc) {
		info "#R{failed}";
		bail(
			"Failed to upload cloud config %s to BOSH director: %s\n\nContent:\n%s",
			$config->{name}, fix_wrap($err // $out // ''), $config->{content}
		);
	}
	info "#G{done}";

	if (ref($config->{network_map}) eq 'HASH') {
		info({pending => 1},
			"[[  - >>submitting network claims for #C{%s} to #M{%s} BOSH director...",
			$env->name, $bosh->alias
		);
		eval {
			$bosh->vault->set_path(
				$bosh->exodus_path.'/network', $config->{network_map}, flatten => 1, clear => 1
			);
			1;
		} or do {
			info "#R{failed}";
			bail(
				"Cloud config #C{%s} was uploaded, but the network map could not be ".
				"updated:\n\n%s", $config->{name}, $@
			);
		};
		info "#G{done}";
	}
	return 1;
}

# }}}
# _bosh_configs_upload_cpi - upload a cpi config and generate its CredHub secrets through the shared fixer {{{
sub _bosh_configs_upload_cpi {
	my ($env, $config) = @_;
	my $result = $env->_fix_cpi_config(
		($config->{status} eq 'missing' ? 'missing' : 'changed'),
		{
			cpi_config => $config->{cpi_config},
			name       => $config->{name},
			director   => $config->{bosh},
		},
		noprompt => 1,
	);
	bail(
		"Could not upload cpi config #C{%s}: %s", $config->{name}, $result->{msg}
	) unless ($result->{result} // '') eq 'ok';
	return 1;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
