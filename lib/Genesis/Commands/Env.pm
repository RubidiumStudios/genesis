package Genesis::Commands::Env;

use strict;
use warnings;
use utf8;

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::Commands;
use Genesis::Top;
use Genesis::UI;
use Genesis::CI::Marker;
use Genesis::CI::Preflight;
use Genesis::Exit qw/ABORTED DATAERR/;
use Encode qw(decode_utf8);

sub create {

	# WARNING: Do not default create-env option to 0, because its absence is used
	# to determine whether the user has explicitly specified it or not, so
	# appropriate warnings can be issued, or actions taken.
	command_usage(1) if @_ != 1;
	warning(
		"The --no-secrets flag is deprecated, and no longer honored."
	) if has_option("secrets", 0);

	my $name = $_[0];
	bail(
		"No environment name specified!"
	) unless $name;
	$name =~ s/\.yml$//;

	my $top = Genesis::Top->new('.');
	my $vault_desc = get_options->{vault} || $top->get_ancestral_vault($name) || '';
	if ($vault_desc) {
		if ( $vault_desc eq "?") {
			$top->set_vault(interactive => 1);
		} else {
			my $vault = Service::Vault->get_vault_from_descriptor($vault_desc, get_options->{vault} ? '--vault option' : '');
			$top->set_vault(vault => $vault);
		}
		$vault_desc = $top->vault->build_descriptor()
	}

	# determine the kit to use (dev or compiled)
	my $kit_id=delete(get_options->{kit}) || '';
	my $kit = $top->local_kit_version($kit_id);
	if (!$kit) {
		bail(
			"Unable to determine the correct version of the Genesis Kit to use.  ".
			"Perhaps you should specify it with the `--kit` flag."
		) if (!$kit_id);

		bail(
			"No dev/ kit found in current working directory.  ".
			"Did you forget to `genesis decompile-kit` first?"
		) if ($kit_id eq 'dev');

		bail(
			"Kit '$kit_id' not found in compiled kit cache.  ".
			"Do you need to `genesis fetch-kit $kit_id`?"
		);
	}

	# Check if root ca path exists if specified
	if (get_options->{'root-ca-path'}) {
		bail(
			"No CA certificate found in vault under '#C{%s}'",
			get_options->{'root-ca-path'}
		) unless $top->vault->query('x509', 'validate', '-A', get_options->{'root-ca-path'});
	}

	# check version prereqs
	$kit->check_prereqs() or exit 86;

	# Under a pipeline the branch class gate has already refreshed control
	# into T and refused a derived branch, so create has nothing left to
	# check about the branch it stands on (D40, D41, D81).
	my $pipeline_enabled = $top->pipeline_enabled;
	my $git;
	if ($pipeline_enabled) {
		require Service::Git;
		$git = Service::Git->new('.');

		# D80: genesis new opens no session, because it writes on the branch
		# the operator chose and there is nothing to leave.  What it does
		# share with begin is the pre-flight, so H20 closes for it too.
		$git->preflight;

		# The command commits the environment file, and a commit takes
		# everything the index already holds, so an operator with staged
		# work of their own would otherwise find it swept into the
		# environment's own commit and have to undo a commit to get it
		# back.  Under --no-commit there is no commit for anything to be
		# swept into, so the check is skipped (D80).
		_assert_clean_index($git) unless get_options->{'no-commit'};
	}

	# create the environment
	info("\nSetting up new environment #C{$name} based on kit %s ...", $kit->id);
	my $env = $top->create_env($name, $kit, %{get_options()});
	bail "Failed to create environment $name" unless $env;

	# Phase C: write pipeline metadata when the repository declares a pipeline.
	# Runs interactively when in a controlling terminal; honours --prior-env,
	# --require-pr, and --manual flags for non-interactive (scripted) use.
	if ($pipeline_enabled) {
		my $provider = $top->pipeline_provider_type // 'unknown';
		info(
			"\n#G{Pipeline configuration} (pipeline provider: #C{%s})\n",
			$provider
		);

		my %cli_opts = %{get_options()};
		my $interactive = in_controlling_terminal;

		my $prior_env;
		if (exists $cli_opts{'prior-env'}) {
			$prior_env = $cli_opts{'prior-env'} // '';
			if (length($prior_env)) {
				my %known = map { $_->name => 1 } $top->envs();
				bail(
					"--prior-env '%s' does not match any environment in this repository.",
					$prior_env
				) unless $known{$prior_env};
			}
		} elsif ($interactive) {
			my @existing = grep { $_->name ne $name } $top->envs();
			if (@existing) {
				my @env_names = map { $_->name } @existing;
				my @choices = map {{ value => $_, label => $_ }} @env_names;
				push @choices, { separator => 1 };
				push @choices, {
					value => '',
					label => '#Yi{(none — pipeline entrypoint)}',
					summary => '(entrypoint)',
				};
				$prior_env = new_prompt_for_choice(
					header      => "Select prior environment (must succeed before this one):",
					choices     => \@choices,
					description => "environment",
				);
			} else {
				$prior_env = '';
				info("No other environments found — #C{%s} will be the pipeline entrypoint.", $name);
			}
		}

		# --- require_pr / manual ---
		my $require_pr;
		if (exists $cli_opts{'require-pr'}) {
			$require_pr = $cli_opts{'require-pr'} ? 1 : 0;
		} elsif ($interactive) {
			$require_pr = prompt_for_boolean(
				"Require a PR gate before this environment deploys? [y|n]",
				"n",
			);
		}

		my $manual;
		if (exists $cli_opts{manual}) {
			$manual = $cli_opts{manual} ? 1 : 0;
		} elsif ($interactive) {
			$manual = prompt_for_boolean(
				"Require a manual CI trigger before this environment deploys? [y|n]",
				"n",
			);
		}

		# Write pipeline: section when there is something to record.
		# Entrypoints (no prior_env) can still carry manual: true.
		if (length($prior_env // '') || $require_pr || $manual) {
			my $pipeline_yaml = "  pipeline:\n";
			$pipeline_yaml .= "    prior_env:    $prior_env\n" if length($prior_env // '');
			$pipeline_yaml .= "    require_pr:   true\n"       if $require_pr;
			$pipeline_yaml .= "    manual:       true\n"       if $manual;

			my $file     = $env->path($env->file);
			my $contents = slurp($file);

			if ($contents =~ /^\s+pipeline:/m) {
				info(
					"#Y{Note}: pipeline section already present in #C{%s}, skipping injection.",
					$env->file
				);
			} else {
				my $injected = ($contents =~ s/^((\s+)env:\s+\S[^\n]*\n)/$1$pipeline_yaml/m);
				if ($injected) {
					mkfile_or_fail($file, $contents);
					info("#G{Pipeline metadata written to} #C{%s}", $env->file);
				} else {
					warning(
						"Could not inject pipeline metadata into #C{%s}: ".
						"'env:' key not found at expected indentation. ".
						"Add the pipeline section manually:\n%s",
						$env->file, $pipeline_yaml
					);
				}
			}
		} else {
			info(
				"#C{%s} is a pipeline entrypoint with no gate flags — no pipeline section written.",
				$name
			);
		}
	}

	# Stage the environment file when the repository declares a pipeline,
	# and commit it too unless --no-commit is set.
	my %cli_opts_git = %{get_options()};
	if ($pipeline_enabled) {
		my $env_file = $env->file;
		$git->add($git->prefixed($env_file));

		if ($cli_opts_git{'no-commit'}) {
			info "Skipping commit (#C{--no-commit} set); #C{%s} remains staged.", $env_file;
		} else {
			my $message = $cli_opts_git{reason}
				|| "Add environment $name";
			$git->commit($message);

			my $sha = $git->sha('HEAD', short => 1);
			info "#G{Committed} #C{%s} -- %s", $sha // '<unknown>', $message;

			# Branch creation belongs to genesis pipeline-apply and to
			# nothing else, so this command writes the environment file on
			# the branch the operator is standing on and touches no
			# deployment branch.  The environment reaches its branch when a
			# propagate run delivers this commit onto it, and the shape of
			# the pipeline that carries it is the apply's to write (D43).
			info(
				"#C{%s} reaches its deployment branch when the next ".
				"#C{genesis propagate} run delivers this commit.  The branch ".
				"itself is created by #C{genesis pipeline-apply}.",
				$name
			);
		}
	}

	# Generate secrets.  Non-fatal — the env file, pipeline metadata, and
	# git branch are already in place; secrets can be retried later with
	# `genesis add-secrets` or will be generated at deploy time.
	# quiet_if_empty: this runs immediately after create_env, so the
	# source vault is expected to be empty for a brand-new env.
	my $secrets_ok = eval {
		$env->add_secrets(verbose => 1, import => 1, quiet_if_empty => 1)
	};
	if (!$secrets_ok) {
		my $err = $@ || '';
		$err =~ s/\s+$//;
		warning(
			"Secret generation incomplete for #C{%s}.%s\n".
			"Run #C{genesis add-secrets '%s'} to retry, or secrets will be\n".
			"generated at deploy time.",
			$name,
			$err ? "\n$err" : '',
			$name
		);
	}

	# let the user know
	if ($pipeline_enabled && !$cli_opts_git{'no-commit'}) {
		info(
			"\nNew environment #C{%s} provisioned!\n\n".
			"To deploy, switch to the environment branch and run:\n\n".
			"  #C{git checkout '%s'}\n".
			"  #C{genesis deploy '%s'}\n",
			$env->{name}, $name, $env->{name}
		);
	} else {
		info(
			"\nNew environment #C{%s} provisioned!\n\n".
			"To deploy, run this:\n\n".
			"  #C{genesis deploy '%s'}\n",
			$env->{name}, $env->{name}
		);
	}
}

# _assert_clean_index - refuse a commit that would sweep in staged work {{{
#
# D80: a session asserts a clean tree and a clean index, because its abort
# has to discard only what it wrote.  This command discards nothing, and its
# one real risk is a commit that carries somebody else's staged change, so
# the check is on the index alone.  An unstaged edit is left where it is,
# because it never enters the commit and refusing it would protect nothing
# (I3).
sub _assert_clean_index {
	my ($git) = @_;

	my $status = $git->status;
	my @staged = sort grep {
		# The index column is the first character of the two.  A space
		# means the change is unstaged, and a question mark means the path
		# is untracked.
		substr($status->{$_} // '', 0, 1) !~ /[ ?]/
	} keys %$status;
	return 1 unless @staged;

	bail(
		{exitcode => DATAERR},
		"There are staged changes in this repository, and this command ".
		"makes a commit, so they would be swept into it:\n\n%s\n".
		"Commit them, unstage them with #C{git reset}, or run with ".
		"#C{--no-commit} to stage the environment file and stop there.\n",
		join('', map {"    $_\n"} @staged)
	);
}

# }}}
sub edit {
	option_defaults(
		editor => $ENV{EDITOR} || 'vim',
	);
	my ($name) = @_;
	my $top = Genesis::Top->new('.', no_vault => 1);
	# Can't use load_env because it validates, and we don't care about that here
	my $env = Genesis::Env->new(name => $name, top => $top);

	my $kit_name = $env->params->{kit}{name};
	my $kit_version = $env->params->{kit}{version};
	my $min_genesis_version = $env->params->{genesis}{min_version};
	if (get_options->{kit}) {
		($kit_name,$kit_version) = (get_options->{kit}) =~ m/^([^\/]*)(?:\/(.*))?$/;
	}

	$env->notify("Editing environment file #C{%s}", Cwd::abs_path($env->file) =~ s/^\Q$ENV{HOME}\E/~/r);
	my $kit_id = $kit_name eq 'dev' ? 'dev' : "$kit_name/$kit_version";
	info "[[  - >>based on kit #C{%s}", $kit_id;

	my $editor = get_options->{editor};
	my @cmd = split(/\s+/, $editor);
	$editor = $cmd[0];
	info "[[  - >>using editor #C{%s}%s", $editor, @cmd > 1 ? ", with option(s): ".join(', ', map {"#Y{'$_'}"} @cmd[1..$#cmd]) : '';

	my @warnings = ();
	my $manual_path = '';
	my $use_manual = defined(get_options->{manual}) ? (get_options->{manual} ? 1 : 0) : undef;
	my $prompt_for_kit = 0;

		# Validate Genesis version requirements
	my $version_check = $env->validate_genesis_version_requirements();
	push @warnings, @{$version_check->{warnings}} if @{$version_check->{warnings}};
	push @warnings, @{$version_check->{errors}} if @{$version_check->{errors}};

	bail(
		"Cannot specify #Y{--manual} unless the editor is vi-based (vi,vim,mvim,".
		"nvim,gvim), vscode (code) or emacs: ".
		"Pull request are welcome for other editors."
	) if $use_manual && $editor !~ m/^([gmn]?vim|vi|emacs|code)$/;
	if ($use_manual//1 && $editor =~ m/^([gmn]?vim|vi|emacs|code)$/) {
		if ($kit_name eq 'dev') {
			if (-d $top->path('dev')) {
				$manual_path = $top->path('dev/MANUAL.md');
				if (! -f $manual_path) {
					push @warnings, "Dev kit for environment #C{$name} has no MANUAL.md";
				}
			} else {
				push @warnings, "Dev kit for environment #C{$name} not found - no MANUAL.md available";
			}
		} else {
			my $kit = $top->local_kit_version($kit_name, $kit_version);
			if ($kit) {
				$manual_path = $kit->path('MANUAL.md');
				if (! -f $manual_path) {
					push @warnings, "Kit #C{$kit_name/$kit_version} has no MANUAL.md";
				}
			} else {
				push @warnings, "Kit #C{$kit_name/$kit_version} not found - no MANUAL.md available";
				$prompt_for_kit = 1;
			}
		}
	} else {
		if ($kit_name eq 'dev') {
			push @warnings, "Dev kit for environment #C{$name} not found!"
				unless (-d $top->path('dev'));
		} else {
			my $kit = $top->local_kit_version($kit_name, $kit_version);
			unless ($kit) {
				push @warnings, "Specified kit #C{$kit_name/$kit_version} not found!";
				$prompt_for_kit = 1;
			}
		}
	}
	info "[[  - >>showing kit manual" if $manual_path;

	my @files = ();
	my $show_ancestors = defined(get_options->{ancestors}) ? (get_options->{ancestors} ? 1 : 0) : undef;
	bail(
		"Cannot specify #Y{--include-all-ancestors} unless the editor is vi-based ".
		"(vi,vim,mvim,nvim,gvim) or vscode (code): Pull request are welcome for other editors."
	) if $show_ancestors && $editor !~ m/^([gmn]?vim|vi|code)$/;

	if ($show_ancestors//1 && $editor =~ m/^([gmn]?vim|vi|code)$/) {
		my @ancestors = reverse $env->potential_environment_files;
		shift @ancestors; # remove the current environment file
		@ancestors = grep {-f $_} @ancestors unless $show_ancestors;
		push @files, map {Cwd::abs_path($_)} @ancestors;
		info(
			"[[  - >>including %s hierarchial ancestor files",
			$show_ancestors ? "all" : 'existing'
		) if @ancestors;
	}

	my $replace_kit = undef;
	if (@warnings) {
		warning(
			"\nThe following issues were found with the environment:%s",
			join("", map {"\n[[- >>$_"} @warnings)
		);
		if ($prompt_for_kit && $editor =~ m/^([gmn]?vim|vi)$/) {
			my $local_kits = $top->local_kits;
			my @kit_names = keys %$local_kits;
			my @kit_labels = ();
			my @kits = ();
			for my $kit (@kit_names) {
				my @versions = keys %{$local_kits->{$kit}};
				if (@versions) {
					push @kit_labels, csprintf("---#C{%s-genesis-kit:}---", $kit);
					for my $version (reverse sort by_semver @versions) {
						push @kits, [$kit, $version];
						push @kit_labels, [csprintf("#%s{%s}", ($version =~ /[\.-]rc[\.-]?(\d+)$/) ? 'Y' : 'G',$version), "$kit/$version"];
					}
				}
			}
			my $selection = prompt_for_choice(
				"Would you like to select a local kit and continue?",
				[@kits, 'download','current', 'abort'],
				$kits[0],
				[@kit_labels, '---', csprintf('#g{Download} #C{%s/%s}',$kit_name, $kit_version), csprintf('#y{Keep as-is}'), csprintf('#r{Quit}')]
			) or bail("Aborted by user");

			if ($selection eq 'download') {
				my $kitsig = "$kit_name/$kit_version";
				$env->notify(
					"Attempting to retrieve Genesis kit #M{$kit_name (v$kit_version)}..."
				);
				my ($name,$version,$target) = $top->download_kit($kitsig)
					or bail "Failed to download Genesis Kit #C{$kitsig}";

				$env->notify(
					"Downloaded version #C{$version} of the #C{$name} kit\n",
				);
				$selection = [$name, $version];
				$replace_kit = 0;
			}

			bail("Aborted by user") if $selection eq 'abort';
			if ($selection ne 'current') {
				$replace_kit //= 1;
				($kit_name, $kit_version) = @$selection;
				$manual_path = $top->local_kit_version($kit_name, $kit_version)->path('MANUAL.md');
				$manual_path = '' unless -f $manual_path;
			}
		} else {
			prompt_for_boolean(
				"Continue? [y|n]",
				1
			) or bail("Aborted by user");
		}
	}

	@files = ($top->path($env->file), $manual_path, @files);

	if ($editor =~ m/vim?$/) {
		push @cmd, '-c';
		my $build_opts = 'edit '.shift(@files);
		if ($replace_kit) {
			$build_opts .= ' | %s/\(kit:\(\n  .*$\)*\n  name:\s*\).*/\1'.$kit_name.'/';
			$build_opts .= ' | %s/\(kit:\(\n  .*$\)*\n  version\s*\).*/\1'.$kit_version.'/';
		}
		if (my $manual = shift(@files)) {
			$build_opts .= ' | vsplit '. $manual;
			$build_opts .= ' | wincmd w';
		}
		$build_opts .= ' | split '. $_ for (@files);
		$build_opts .= ' | '.scalar(@files).' wincmd k' if (@files);

		push @cmd, $build_opts;
	} elsif ($editor eq 'code') {
		info(
			"\n[[#Y{Note:} >>VSCode opens files in separate tabs -- drag and drop ".
			"them to split the view if desired."
		) if grep {$_} @files > 1;
		push @cmd, '--wait', '--add','.', grep {$_} @files;
	} elsif ($editor eq 'emacs') {
		push @cmd, '-nw', shift(@files);
		push @cmd, '-f', 'split-window-horizontally', shift(@files), '-f', 'other-window'
			if @files;
	} else {
		push @cmd, shift(@files);
	}

	my ($out, $rc, $err) = run(
		{interactive => 1},
		@cmd
	);

	if ($rc) {
		bail(
			"Failed to edit environment %s",
			$name,
		);
	}
	$env->notify(success => "Environment $name edit completed.\n");
}

sub check {
	command_usage(1) if @_ != 1;

	option_defaults(
		manifest => 1,
	);
	my $env = Genesis::Top->new('.')->load_env($_[0]);
	$env->with_vault() if get_options->{secrets} || get_options->{manifest};

	if (has_option('no-config',1)) {
		$ENV{GENESIS_CONFIG_NO_CHECK}=1;
		bail(
			"Cannot specify --no-config without also specifying --no-manifest"
		) if get_options->{manifest};
	} else {
		my @hooks = qw/check/;
		push(@hooks, 'manifest', 'blueprint') if has_option('manifest',1);
		$env->download_required_configs(@hooks);
	}

	get_options->{$_} //= 0 for qw/secrets stemcells cpis/;

	my $ok = $env->check(
		(map {("check_$_" => has_option($_,1))} qw/manifest secrets stemcells cpis/)
	);
	if ($ok) {
		info "\n[#M{%s}] #G{All Checks Succeeded}", $env->name;
		exit 0;
	} else {
		bail "\n[#M{%s}] #R{PREFLIGHT FAILED}", $env->name;
	}
}

sub list_secrets {
	command_usage(1) if @_ < 1;
	my ($name, @filters) = @_;
	my $env = Genesis::Top
		->new(".")
		->load_env($name)
		->with_vault();

	# TODO: Should we support the missing|invalid|problematic|unused options here?
	my %options = %{get_options()};
	my $plan = $env->secrets_plan(no_validation=>1)->filter(@filters)->autoload;

	my $results = [];
	for my $secret ($plan->secrets) {
		my $path = $options{relative} ? $secret->path :$secret->full_path;
		if ($options{json}) {
			my $json = undef;
			if ($options{verbose}) {
				$json = {
					path => $path,
					type => $secret->type,
					description => scalar($secret->describe),
					source => $secret->source,
				};
				$json->{value} = $secret->value if $options{verbose} > 1;
				$json->{feature} = $secret->feature if $secret->from_kit;
				$json->{var_name} = $secret->var_name if $secret->from_manifest;
			} else {
				$json = $path;
			}
			push @$results, $json;
		} else {
			my $value = $path;
			if ($options{verbose}) {
				$value .= " #C{(".$secret->describe.")}";
				my $source = $secret->source;
				my $descriminator = $source eq 'kit' ? 'feature' : 'var_name';
				my $desc = $secret->$descriminator;
				$value .= " from #m{$source} (#Mi{$descriminator: $desc})";
			}
			push @$results, csprintf($value);
		}
	}
	if ($options{json}) {
		info '';
		my %json_key_order = (
			path => 1,
			type => 2,
			description => 2,
			source => 3,
			feature => 4,
			var_name => 5,
		);

		require "JSON/PP.pm";
		print(
			JSON::PP->new->pretty
			->sort_by(sub {
				my ($a, $b) = ($JSON::PP::a, $JSON::PP::b);
				return ($json_key_order{$a}//999) <=> ($json_key_order{$b}//999) || $a cmp $b;
			})
			->encode($results)
		);
	} else {
		info "\nSecrets in #C{$name}:\n";
		output(join("\n", @$results));
	}

	$env->notify(success => "found ".scalar($plan->secrets)." secrets.\n");

}
sub check_secrets {
	command_usage(1) if @_ < 1;
	my ($name,@paths) = @_;

	my $level = delete(get_options->{exists});
	my ($action_desc, $validation_level) = $level
		? (checked => 0)
		: (validated => 1);

	my $env = Genesis::Top
		->new(".")
		->load_env($name)
		->with_vault();

	my ($results, $msg) = $env->check_secrets(
		paths=>\@paths,
		%{get_options()}
		, validate => $validation_level
	);

	if ($results->{empty}) {
		if ($msg) {
			$env->notify($msg."\n")
		} else {
			$env->notify(success => "doesn't have any secrets to be $action_desc.\n");
		}
	}

	if ($results->{error}) {
		$env->notify(fatal => "- invalid secrets detected.\n");
		exit 1
	}
	if ($results->{missing}) {
		$env->notify(fatal => "- missing secrets detected.\n");
		exit 1
	}
	if ($results->{warn}) {
		$env->notify(warning => "- all secrets valid, but warnings were encountered.\n");
		exit 0;
	}
	$env->notify(success => "$action_desc secrets successfully!\n");
	exit 0
}

sub add_secrets {
	command_usage(1) if @_ < 1;
	my ($name,@paths) = @_;
	my $env = Genesis::Top
		->new(".")
		->load_env($name)
		->with_vault();

	my ($results) = $env->add_secrets(paths=>\@paths,%{get_options()});
	if ($results->{error}) {
		$env->notify(fatal => "- errors encountered while adding secrets");
		exit 1
	}
	my $msg;
	my @warnings = ();
	push(@warnings, 'warnings were encountered') if $results->{warn};
	push(@warnings, 'not all secrets could be imported from CredHub, so were generated instead')
		if $results->{generated};

	if ($results->{ok} || $results->{generated}) {
		$msg = "- all ".($results->{skipped} ? 'missing ':'')."secrets were added";
	} elsif ($results->{imported}) {
		$msg = "- all ".($results->{skipped} ? 'missing ':'')."secrets were imported";
	} elsif ($results->{skipped}) {
		$env->notify(success => "- all secrets already present, nothing to do!\n");
		exit 0;
	} else {
		$env->notify(warning => "- no secrets were added.\n");
		exit 0;
	}

	if (@warnings) {
		$env->notify(warning => "$msg, but ".sentence_join(@warnings)."\n");
	} else {
		$env->notify(success => "$msg successfully!\n");
	}
	exit 0;
}

sub rotate_secrets {
	command_usage(1) if @_ < 1;
	my ($name, @paths) = @_;
	bail(
		"--force option no longer valid. See `genesis rotate-secrets -h` for more details"
	) if get_options->{force};

	get_options->{invalid} = 2 if delete(get_options->{problematic});
	my $env = Genesis::Top
		->new(".")
		->load_env($name)
		->with_vault();

	my ($results, $msg) = $env->rotate_secrets(paths => \@paths,%{get_options()});

	bail($msg||"User aborted secrets rotation") if $results->{abort};

	if ($results->{empty}) {
		$env->notify($msg);
		exit 0
	}
	if ($results->{error}) {
		$env->notify(fatal => "- errors encountered while rotating secrets");
		exit 1;
	}
	my @warnings = ();
	push(@warnings, 'some rotations were skipped') if $results->{skipped};
	push(@warnings, 'warnings were encountered') if $results->{warn};
	if ($results->{skipped} && !$results->{ok} && !$results->{warn}) {
		$env->notify(warning => "no secrets were rotated!\n");
	} elsif (@warnings) {
		$env->notify(warning => "$msg, but ".sentence_join(@warnings)."\n");
	} else {
		my $selective = @paths ? 'specified' : 'all';
		$env->notify(success => "$selective $msg successfully!\n");
	}
	exit 0;
}

sub remove_secrets {
	command_usage(1, 'Missing environment name or file') if @_ < 1;
	my %options = %{get_options()};
	$options{invalid} //= 0;
	my ($name, @paths) = @_;
	if ( $options{all}) {
		bail(
			"Cannot specify secret paths when using the --all option."
		) if @paths;
		bail(
			"Cannot use --invalid, --problematic, --interactive or --unused at the same time as the --all option."
		) if $options{problematic} || $options{invalid} || $options{interactive} || $options{unused};
	}
	if ($options{unused}) {
		bail(
			"Cannot specify secret paths or filters when using the --unused option."
		) if @paths;
		bail(
			"Cannot use --invalid or --problematic at the same time as the --unused option."
		) if $options{problematic} || $options{invalid};
	}

	$options{invalid} = 2 if delete($options{problematic});
	$options{invalid} = 3 if delete($options{unused});
	my $env = Genesis::Top
		->new(".")
		->load_env($name)
		->with_vault();

	my ($results, $msg) = $env->remove_secrets(paths => \@paths,%options);
	if ($results->{abort}) {
		if ($options{invalid} == 3 || $options{interactive}) { # -- unused or interactive can be partially aborted
			bail($msg||"User aborted secrets removal") unless $results->{ok} || $results->{warn} || $results->{error} || $results->{missing};
		} else {
			bail($msg||"User aborted secrets removal");
		}
	}

	if ($results->{empty} && keys %$results == 1) {
		$env->notify($msg||"No secrets were found to remove");
		exit 0
	}
	if ($results->{error}) {
		$env->notify(fatal => "- errors encountered while removing secrets");
		exit 1;
	}

	my @warnings = ();
	$msg ||= "unused secrets removed" if $options{invalid} == 3;
	push(@warnings, 'some removals were skipped') if $results->{skipped};
	push(@warnings, 'warnings were encountered') if $results->{warn};
	if ($results->{missing} && !$results->{skipped} && !$results->{ok} && !$results->{warn}) {
		$env->notify(success => "no secrets to remove.\n");
	} elsif (($results->{skipped} || $results->{missing}) && !$results->{ok} && !$results->{warn}) {
		$env->notify(warning => "no secrets were removed!\n");
	} elsif (@warnings) {
		$env->notify(warning => "$msg, but ".sentence_join(@warnings)."\n");
	} else {
		my $selective = @paths ? 'specified' : 'all';
		$env->notify(success => "$selective $msg successfully!\n");
	}
	exit 0;
}

sub manifest {
	command_usage(1) if @_ != 1;

	my ($type,$subset) = @{get_options()}{qw(type subset)};

	my $env = Genesis::Top
		->new('.')
		->load_env($_[0])
		->with_vault();

	my %valid_types = $env->manifest_provider->known_types;
	my %valid_subsets = $env->manifest_provider->known_subsets;
	if (get_options->{list}) {
		# Calculate max width for consistent alignment
		my $max_len = ((sort {$b <=> $a} map {length($_ =~ s/_/-/gr)} (keys %valid_types, keys %valid_subsets))[0] || 0) + 2;

		# Format types with descriptions
		my @type_lines = map {
			my $name = $_ =~ s/_/-/gr . ':';
			sprintf("[[  #c{%-*s}>>%s", $max_len, $name, $valid_types{$_})
		} sort keys %valid_types;

		# Format subsets with descriptions
		my @subset_lines = map {
			my $name = $_ =~ s/_/-/gr . ':';
			sprintf("[[  #c{%-*s}>>%s", $max_len, $name, $valid_subsets{$_})
		} sort keys %valid_subsets;

		output(
			"Valid manifest types (defaults to default deployment manifest):\n".
			join("\n", @type_lines).
			"\n\n".
			"Valid subsets (defaults to full contents):\n".
			join("\n", @subset_lines)
		);
		return 1;
	}

	bail(
		"Unknown manifest type %s - use --list option to show valid types",
		$type
	) if ($type && ! in_array($type =~ s/-/_/gr, keys %valid_types));

	bail(
		"Unknown manifest subset %s - use --list option to show valid subsets",
		$subset
	) if ($subset && ! in_array($subset =~ s/-/_/gr, keys %valid_subsets));

	if ($env->use_create_env && scalar(@{$env->configs})) {
		warning(
			"\nThe provided configs will be ignored, as create-env environments do ".
			"not use them:\n[[- >>".join(
				"\n[[- >>", map {"#C{$_}"} (@{$env->configs})
			)
		);
	}

	$type //= 'deployment';
	$type =~ s/-/_/g if $type;
	$subset =~ s/-/_/g if $subset;

	bail(
		"Manifest type %s is not supported by this environment",
		$type
	) unless $env->manifest_provider->can($type);

	my $manifest = $env
		->download_required_configs('blueprint', 'manifest')
		->manifest_provider->$type(notify=>1,subset=>$subset);
	my $content = slurp($manifest->file) =~ s/\s*\z//msr;
	print STDERR "\n";
	output {raw => 1}, $content;
}

# _derive_deploy_reason - build a default --reason from the pipeline commit range {{{
#
# Reads the last successful deployment's `git.commit` from exodus and
# compares it to the env branch HEAD.  If equal, this is a redeploy —
# returns a "Redeploy of <sha>" stub.  If different, walks commits in
# the `$last_deployed..$branch_head` range on the env branch and
# delegates to _format_pipeline_reason to produce the audit string.
#
# Returns undef if vault is unreachable (caller falls back to the
# operator-provided or default reason).
sub _derive_deploy_reason {
	my ($env, $git) = @_;

	my $env_v = eval { $env->with_vault };
	return undef unless $env_v;

	my $dep = eval { $env_v->deployments->latest_successful };
	my $last_deployed = $dep ? ($dep->lookup('git.commit') || '') : '';

	my $branch_head = $git->sha($env->name);
	return undef unless $branch_head;

	if ($last_deployed && $last_deployed eq $branch_head) {
		return sprintf("Redeploy of %s", $git->sha($branch_head, short => 1));
	}

	my $range = $last_deployed ? "$last_deployed..$branch_head" : $branch_head;

	# Scope the history to commits that actually touched files this env
	# depends on.  Without this filter, multi-deploy repos (e.g. bosh and
	# vault sharing one env branch) would surface propagation markers
	# from sibling deployments whose subjects are irrelevant to the deploy
	# being reasoned about.
	my @dep_files = $env->propagation_files;
	my @lines = $git->log_subjects(
		$range,
		limit => 50,
		paths => \@dep_files,
	);

	return _format_pipeline_reason(
		\@lines,
		sub { $git->sha($_[0], short => 1) },
		sub {
			my ($subject) = $git->log_subjects($_[0], limit => 1, format => '%s');
			$subject //= '';
			$subject =~ s/\s+$//;
			return $subject;
		},
	);
}

# }}}
# _format_pipeline_reason - pure formatter for the derived deploy reason {{{
#
# Inputs:
#   \@log_lines   — output of `git log --format='%H %s'` for the range
#   $short_sha    — callback: sha => abbreviated-sha (kept for API
#                   compatibility; may be unused)
#   $subject_of   — callback: sha => commit subject line
#
# Reads the propagation marker off each env-branch log line through the one
# reader, flips the control commits it finds into oldest-first order, and
# produces a reason string made up of their subjects (SHAs are omitted
# because exodus already records `git.control_commit`).  For a single
# commit the subject is returned verbatim; for multiple commits a
# bulleted list is produced.  Returns undef if no markers are found.
#
# The lines arrive in git's `%H %s` shape, so the subject begins after the
# commit's own sha.  The reader is anchored to the start of a line, which is
# what keeps a sha named in passing from matching, so the leading field has
# to come off before the marker is at the start of anything.
#
# The line is read as it arrived first and with that field removed second,
# because a caller that hands over the subject alone would otherwise go
# silent: the strip would take the marker's own first word and leave a line
# that reads as carrying nothing.  Both reads are anchored, so the second one
# adds no way for a sha named in passing to match.
sub _format_pipeline_reason {
	my ($log_lines, $short_sha, $subject_of) = @_;
	require Genesis::CI::Marker;

	my @controls;
	for my $line (@{$log_lines || []}) {
		(my $subject = $line) =~ s/\A\S+[ \t]+//;
		my $control = Genesis::CI::Marker::in_text($line)
		           // Genesis::CI::Marker::in_text($subject);
		next unless defined $control;
		push @controls, $control;
	}
	return undef unless @controls;

	@controls = reverse @controls;  # log is newest-first; reason reads oldest-first

	my @subjects = map { $subject_of->($_) } @controls;

	return $subjects[0] if @subjects == 1;

	return join("\n",
		sprintf("%d commits:", scalar @subjects),
		map { "  - $_" } @subjects,
	);
}

# }}}
# _deploy_branch_action - classify <env>/<type> and act by the class table {{{
#
# The one ref move D35's span allows is the fast-forward of a behind branch,
# which moves L toward T and neither creates nor discards a commit (D5).  An
# ahead or diverged branch is refused, because the marker-only reset and the
# hand-commit refusal are the propagate run's and a deploy never discards a
# commit.  A branch R lacks, or one sharing no ancestor with R's, is refused
# under D48, because it has no legitimate origin and a deploy from it would
# certify a commit that is not on R.  A branch with nothing delivered to it is
# D56's, awaiting pipeline-apply and the propagation that fills what the apply
# cut.  Genesis deletes nothing on any of them.
sub _deploy_branch_action {
	my ($top, $env_name, $git) = @_;

	my $branch = $top->branch_for($env_name);
	my $remote = $git->default_remote // 'origin';
	my $d      = $git->resolve_branch($branch, remote => $remote);

	# resolve_branch answers undef when neither ref exists, which is the one
	# case that has no state, so it is read before anything reads a state.
	bail({exitcode => DATAERR},
		"Refusing to deploy.  The environment #C{%s} has no branch on ".
		"#C{%s} or locally, so it is awaiting #C{pipeline-apply}.  A deploy ".
		"certifies the commit of the branch it stands on, and with no branch ".
		"it would deploy from control, certifying a commit no propagation ".
		"routed there.  Run #C{genesis pipeline-apply} to create the branch, ".
		"then #C{genesis propagate}.  Nothing was deployed.",
		$env_name, $remote
	) unless defined $d;

	if ($d->{state} eq 'no-remote') {
		bail({exitcode => DATAERR},
			"Refusing to deploy.  The local branch #C{%s} has no counterpart on ".
			"#C{%s}.  A deployment branch is derived from control and never ".
			"originates locally, so this branch is a legacy checkout or was ".
			"created by hand.  Genesis deletes nothing.  Inspect the branch for ".
			"anything that should live on control and move it there through a ".
			"commit or a pull request, then delete the branch with #C{git branch ".
			"-D %s}, then run #C{genesis pipeline-apply} if the environment ".
			"#C{%s} is meant to exist.  Nothing was deployed.",
			$branch, $remote, $branch, $env_name
		);
	}

	# The three states that would deploy, and the one ref move among them.
	# What the branch carries is not asked here: the pre-flight asks it after
	# this move has been made, because a branch behind a delivery carries the
	# init commit until the fast-forward lands and the answer before it would
	# be an answer about the wrong commit.
	#
	# no-local sits with the other two for the reason the propagate run's own
	# initial state gives: the refresh two steps above materialises the local
	# ref from the tracking ref, so nothing reaches here in that state, and
	# the gate's switch would have created the ref in any case.
	if ($d->{state} eq 'in-sync' || $d->{state} eq 'behind'
			|| $d->{state} eq 'no-local') {
		return {action => 'fast-forward', divergence => $d}
			if $d->{state} eq 'behind';
		return {action => 'proceed', divergence => $d};
	}

	# resolve_branch has no unrelated state: a branch sharing no ancestor
	# with the remote's counts two ways and reads as diverged.  The ancestry
	# question is asked separately, through the one test the propagate run's
	# initial state uses, so the two commands mean the same thing by it.  It
	# is asked here rather than above, because both refs have to exist for
	# git to answer it and only these two states promise that.
	if (!Genesis::CI::Preflight::_shares_history($git, $branch, $remote)) {
		bail({exitcode => DATAERR},
			"Refusing to deploy.  The local branch #C{%s} shares no ancestor ".
			"with #C{%s/%s}, which #C{pipeline-apply} created.  The marker-only ".
			"reset never applies across unrelated histories, whatever the local ".
			"commits carry, and Genesis deletes nothing.  Inspect the local ".
			"branch for anything that should live on control and move it there ".
			"through a commit or a pull request, then delete the local branch ".
			"with #C{git branch -D %s}, then run #C{genesis propagate} again.  ".
			"Nothing was deployed.",
			$branch, $remote, $branch, $branch
		);
	}

	# Two states share this refusal and they read differently, so the verb
	# comes off the state rather than the state's own name being read as one.
	# Both counts carry their noun, because a number with no noun beside it
	# is a number an operator has to guess the unit of.
	bail({exitcode => DATAERR},
		"Refusing to deploy.  The branch #C{%s} %s.  A deploy never discards ".
		"a commit, so run #C{genesis propagate}, which resets a marker-only ".
		"commit and refuses a hand commit by name.  Nothing was deployed.",
		$branch,
		$d->{state} eq 'diverged'
			? sprintf("has diverged from #C{%s/%s}, standing %s ahead of it ".
			          "and %s behind", $remote, $branch,
			          count_nouns($d->{ahead}, 'commit'),
			          count_nouns($d->{behind}, 'commit'))
			: sprintf("is ahead of #C{%s/%s} by %s", $remote, $branch,
			          count_nouns($d->{ahead}, 'commit'))
	);
}

# }}}
# _deploy_preflight - the deploy's pre-flight, in order {{{
#
# The order is the design's, and it is one sub because the order is what the
# rows assert.  Every gate runs before every warning, so an operator sees a
# refusal before a warning about a deploy that will not happen, and the
# divergence refusal of the branch classification prints where the prior-env
# refusal would otherwise also apply.
#
# The handle comes from Service::Git->new('.'), which memoises one handle per
# repository root, so this is the same handle the branch-class gate used and
# not a second one.  The session is the gate's, read through
# Genesis::Commands::branch_session, and it is undef where the gate switched
# nothing (D80).
sub _deploy_preflight {
	# The options come down whole rather than by the keys read here, because
	# the steps that follow this one ask about --yes for the prompt they put
	# beside their warnings, and a sub whose caller has to know which keys it
	# reads is a sub whose caller goes stale.
	my ($top, $env_name, $options) = @_;

	require Service::Git;
	my $git = Service::Git->new('.');

	# An operator may name the environment by a path or by its file, and the
	# gate takes the same two things off the same argument before it derives
	# the branch.  Two derivations of one name are two chances to disagree,
	# so this one is written to match the gate's and the branch is derived
	# once, here, for everything below.
	(my $name = $env_name) =~ s{^.*/}{};
	$name =~ s/\.ya?ml$//;
	my $branch = $top->branch_for($name);

	# Which commit this run is about, resolved once for the two steps that
	# ask.  D87 has --redeploy select the commit the last successful
	# deployment recorded, and the gate has already stood the working tree on
	# it, detached, inside the session.  Step 5 asks whether this deploy is
	# reading the branch at all, and the notice in step 8 tells the operator
	# which of the two commits the run is about.
	#
	# The resolver reads one record and answers the same value it answered
	# the gate, so asking it again here costs one vault read and cannot
	# disagree with the commit the tree is standing on.  It is asked in
	# scalar context, because the record path beside it is the gate's to
	# name in its own refusal and nothing here has a use for it.
	my $target = Genesis::Commands::deployed_target($name, $top);

	# 1.  The one refresh, control included, which M7 already freed of
	# --no-fetch on this command under D40.  The deploy's own reads are
	# worthless against a stale tracking ref.
	my $refreshed = $top->fetch_pipeline_envs($git,
		command => "$env_name deploy",
		action  => 'deploy',
		outcome => 'Nothing was deployed.');

	# 2.  The deploy asks the same first question the run asks, and refuses
	# on the one answer that leaves it nothing to read.  It reports every
	# other state rather than refusing on it, because a deploy resolves
	# nothing about control.
	my $control_state = Genesis::CI::Preflight::require_control($top, $git,
		refreshed     => $refreshed,
		action        => 'deploy',
		outcome       => 'Nothing was deployed.',
		on_divergence => 'report');
	info("  #Gi{%s}", $_) for @{$control_state->{events}};

	# 3.  The session the gate opened asserts the tree clean in begin, and
	# for a deploy that switches that is the whole of the check.  Three arms
	# of the gate open no session at all, though, and two of them have
	# nothing to do with cleanliness: an environment with no deployment
	# branch, and a branch pipeline-apply cut that carries no repository.  A
	# deploy from a dirty tree there deploys uncommitted content and records
	# a commit that does not hold it, which is the audit trail describing
	# something other than what shipped, so D84's precondition is asserted
	# here for those two.  It is asserted before the classification refuses
	# either of them, because a dirty tree is the operator's to settle
	# whatever the branch turns out to be.
	#
	# The third arm is exempt on purpose.  A command already standing on the
	# branch it would switch to is leaving nothing behind, and D80 lets an
	# operator deploy an edit in place, which is how a change is tested
	# before it is committed.  That is the same branch the retired switch
	# asked about, and it is asked the same way.
	my $session = Genesis::Commands::branch_session();
	if (!$session && ($git->current_branch // '') ne $branch) {
		unless ($git->is_clean) {
			# The list comes from the session's own reader, so an operator
			# refused here and an operator refused by the session are shown
			# one list rather than two that have to be kept in step by hand.
			# The module is required here because the arm with no deployment
			# branch returns before the gate has loaded it.
			require Service::Git::Session;
			my $modified = Service::Git::Session::modified_paths_of($git);
			bail(
				"Working tree has uncommitted changes.  Commit or stash them\n".
				"before deploying:\n%s",
				join("", map {"  - $_\n"} @$modified)
			);
		}
	}

	# 4.  What the branch is, and the one move its class allows.  The pull is
	# made where the deploy stands, which the gate has stood on the branch,
	# and it is the fast-forward D5 named as its precedent rather than the
	# unconditional pull the deploy used to make of every branch alike.
	my $on_branch = ($git->current_branch // '') eq $branch;
	my $action    = _deploy_branch_action($top, $name, $git);
	if ($action->{action} eq 'fast-forward' && $on_branch) {
		# The remote is named the way the classification named it, so the
		# move is made against the ref the class was read from.
		my $remote = $git->default_remote // 'origin';
		info "Fast-forwarding #C{%s} to #C{%s/%s}...", $branch, $remote, $branch;
		$git->pull_ff_only($branch, $remote);
	}

	# 5.  What the branch carries, asked after the move, because a branch
	# behind a delivery holds the commit before it until the fast-forward
	# lands and the answer taken first would be an answer about the wrong
	# commit.
	#
	# Standing on the branch is asked as well, and the two are one question
	# rather than two.  The pull above merges into the branch the working tree
	# holds, so it is made only where the deploy stands on the branch, and a
	# deploy that is not standing there is one the branch-class gate declined
	# to switch: the root it read is control's, whatever the branch carries
	# now, so the commit it would record is not the commit it would deploy.
	#
	# A run that resolved a target is the exception, and it is an exception
	# to the premise rather than to the rule.  Such a run is standing on the
	# branch's own history, at the commit it was told to deploy, because the
	# gate checked that commit out detached inside the session, so the root
	# it read is the branch's and the commit it records is the commit it
	# deploys.  What it is not standing on is the branch name, and asking for
	# the name alone would refuse every redeploy as a branch carrying no
	# repository.
	unless (($on_branch || defined($target))
			&& Genesis::Commands::branch_carries_repository($top, $git, $branch)) {
		my $remote = $git->default_remote // 'origin';

		# Two states reach here and they need different remedies.  A branch
		# behind its counterpart has a delivery waiting on the remote that
		# this clone has not pulled, and telling such an operator to propagate
		# sends them to a command that cannot help them: nothing is due, and
		# the deploy would refuse the same way on the next run.  The gate
		# cannot pull it for them, because every other command in the class
		# reads and a read moves no ref.
		bail({exitcode => DATAERR},
			"Refusing to deploy.  The branch #C{%s} carries no repository as ".
			"this clone holds it, and it stands %s behind #C{%s/%s}, so a ".
			"delivery has been made and this clone has not pulled it.  Nothing ".
			"was switched onto, because there is no deployment root on the ".
			"branch to read, and a deploy from here would read control and ".
			"record the branch.  Bring the branch up to its counterpart with ".
			"#C{git fetch %s %s:%s}, then deploy again.  Nothing was deployed.",
			$branch, count_nouns($action->{divergence}{behind}, 'commit'),
			$remote, $branch, $remote, $branch, $branch
		) if $action->{divergence}{state} eq 'behind';

		bail({exitcode => DATAERR},
			"Refusing to deploy.  The branch #C{%s} carries no repository, so ".
			"nothing has been delivered to the environment #C{%s} that a deploy ".
			"could read.  A deploy certifies the commit of the branch it stands ".
			"on, and from a branch carrying only what #C{pipeline-apply} cut it ".
			"would deploy from control, certifying a commit no propagation routed ".
			"there.  The branch is #C{genesis pipeline-apply}'s to create and ".
			"#C{genesis propagate}'s to fill, so run #C{genesis propagate} to ".
			"deliver control to it.  Nothing was deployed.",
			$branch, $name
		);
	}

	# 6.  D79: every genesis.pipeline.* key the pre-flight reads comes from
	# the merged environment hierarchy and never from the leaf file alone, so
	# a predecessor named on a site file is seen by the check that refuses on
	# it.  bare runs the name and file-existence checks and nothing else, so
	# lookup resolves through the hierarchy with no kit loaded and nothing
	# connected, and the read is made here rather than after the environment
	# is loaded, where a repository the deploy cannot reach a director for
	# would answer with the director's complaint instead of this refusal.
	#
	# The record is read once and handed to the check.  Two readers want it,
	# the check for the fact that the predecessor deployed at all and the
	# due computation for the commit it certified, and one read serves both
	# (FWT-1141).
	my $bare         = Genesis::Env->bare($name, $top);
	my $prior        = $bare->lookup('genesis.pipeline.prior_env', '');
	my $prior_record = _prior_env_record($bare, $prior);
	_assert_prior_env_deployed($bare, $prior, $prior_record) if $prior;

	# 7.  D73.  The deploy's words for a gate the propagate run also meets,
	# and the typed acknowledgement is what makes the operator read what they
	# are doing.  -y means stop asking questions and must never mean accept
	# an unlocked deploy, so nothing here reads it.
	#
	# It sits after the predecessor's record and before the warnings, which
	# makes it the last refusal we raise on our own judgment rather than the
	# first.  Every refusal above it is one no acknowledgement can settle: an
	# operator who types the phrase past a branch that carries no repository
	# still has nothing to deploy.  This gate is the one question --force is
	# an answer to, so it is asked once everything that is not negotiable has
	# passed, and what follows it is a warning rather than a refusal of ours.
	# The operator can still stop the deploy below, by declining the prompt
	# beside the due-commits warning, which exits ABORTED.
	Genesis::CI::Preflight::assert_provider_gate($top, $options,
		owns        => 'deploys of this environment',
		outcome     => 'Nothing was deployed.',
		acknowledge => 'I accept the risk');

	# 8.  What this run is about, said before anything is said about the
	# branch, because every warning below it describes the tip and an
	# operator has to know first that the tip is not what is being deployed.
	# D87 has --redeploy select the deployed commit, and an operator standing
	# on a branch whose tip holds something else needs to be told which of
	# the two this run is about before it starts.  A run that resolved no
	# target is deploying the tip, as every deploy did before the flag
	# existed, and says nothing here.
	if (defined $target) {
		info(
			"\nRedeploying #C{%s} at its deployed commit #C{%s}, which is what ".
			"it is running, rather than the tip of #C{%s}.",
			$name, $target, $branch
		);
	}

	# 9.  The warnings, in the order the design fixes, and this is the first
	# of them.  It runs ahead of the due-commits warning below because what
	# is stale decides which environments and which branches that warning is
	# talking about: an operator told that commits are due to a branch wants
	# to know first that the pipeline watching it no longer matches control.
	#
	# It is asked in void context because nothing below reads the count.  The
	# sub answers one anyway, for the propagate pre-flight and
	# pipeline-status, which ask the same query, and its POD says so.
	_warn_stale_pipeline($top, $git);

	# 10.  What control carries that has not reached this branch, and the one
	# prompt --yes answers.  The deploy computes none of it: the walk is the
	# propagate run's own computation, run read-only and narrowed to this
	# environment through the option it already has, so the two commands
	# cannot disagree about what is due.  The deploy calls no read-only sub
	# of its own here, because a second such sub would be a second thing to
	# keep in step with the first.
	#
	# It prints after the staleness warning, because what is stale decides
	# which branches the due set is talking about.
	#
	# The branch record is composed here rather than taken from
	# Genesis::CI::Preflight::initial_state, which resets and fast-forwards
	# the branches it classifies and so is no read for a deploy to make.  The
	# walk reads the ref off this record and nothing else off it, so the one
	# field it reads is the one field given, and the classification four
	# steps above is where the branch was already resolved.
	require Genesis::CI::Walk;
	my $walk = Genesis::CI::Walk::plan($top,
		git      => $git,
		scope    => [$name],
		branches => {$name => {branch => $branch}},
	);
	# The walk was asked about one environment, so it answers about one, and
	# a list with nothing in it is the walk disagreeing with its own scope.
	# The read below would hand undef on and every warning would then read as
	# nothing due, which is the one wrong answer this step can give.
	my ($due_record) = @{$walk->{environments} || []};
	bug("The walk answered no environment for #C{%s}.", $name)
		unless $due_record;

	my $due = _warn_commits_due($bare, $due_record);

	# 11.  The last of the warnings, and the only one about the branch itself
	# rather than about what has not reached it.  It runs after the other two
	# because a branch that has drifted is a smaller thing to know than a
	# pipeline that no longer matches control, and it runs before the prompt
	# below because that prompt is the last place a deploy can be stopped and
	# an operator answering it should have heard everything the pre-flight
	# had to say (D33).
	#
	# It is the one read of the pre-flight made through a loaded environment
	# rather than through the bare one above.  The propagation set is built
	# from the kit as much as from the environment file, since the kit source
	# is a kind of the set and the blueprint names the fragments the merge
	# consumes, and a bare environment has no kit to ask.  The load reads the
	# kit off the branch and connects to nothing, and the deploy loads the
	# same environment a step later, so a repository whose kit cannot be
	# loaded fails here rather than there and says the same thing either way.
	#
	# That second load is the same work done twice, and the cost is named
	# rather than hidden, because load_env memoises nothing and the deploy
	# proper pays for a full merge of the environment hierarchy and a full
	# kit resolution again a step below.  Carrying the loaded environment out in
	# the answer would spare it, and the keys of that answer are fixed, so
	# sparing it belongs to whichever step may widen them.
	my $drifted = _warn_drifted($top->load_env($name), $git);

	# The one prompt --yes answers, asked once every warning has printed.
	_confirm_commits_due($name, $due, $options);

	return {
		git     => $git,
		branch  => $branch,
		session => $session,
		action  => $action,
		bare    => $bare,
		prior   => $prior_record,
		due     => $due,
		drifted => $drifted,
	};
}

# }}}
sub deploy {
	option_defaults(
		redact   => ! -t STDOUT,
		reactions => 1,
	);
	command_usage(1) if @_ < 1 || @_ > 2;
	my ($env_name, $reason) = @_;

	my %options = %{get_options()};
	my @invalid_create_env_opts = grep {$options{$_}} (qw/fix fix-stemcells/);

	# The pre-flight reads run on the environment's own branch, because the
	# cloud-config download, the manifest viability check, the secret checks,
	# and the stemcell checks all read the files that branch carries.  The
	# switch belongs to the branch class (D81, D80) rather than to the
	# command, so by the time this runs the gate has already opened the
	# session, asserted a clean tree and index as is_clean means it, taken
	# the switch lock, and stood the working tree on <env>/<type>.
	#
	# Top is therefore the one built on that branch and is never rebuilt
	# from '.' partway through.  A root rebuilt after a checkout is a root
	# built out of whatever the checkout left behind, which is how a deploy
	# the checkout had moved out from under came to report a repository that
	# is not there rather than the problem in front of it (H10).
	my $top = Genesis::Top->new('.');

	# D64.  A pipeline the configuration has disowned is one that is still
	# live, still watching its branches, and still deploying, and the
	# propagate run has always refused it.  A deploy is about to read what
	# is already there rather than write to it, and an operator mid-teardown
	# has a reason to be here, so it warns and carries on; inside the
	# pipeline's own job it refuses, because nobody there reads a warning.
	#
	# It sits ahead of the block below rather than inside it, because the
	# state it answers for is a repository whose pipeline.enabled reads
	# false.  Every pipeline read below is guarded on that key being true,
	# so a check made there could never see the one state it exists to see.
	#
	# The record it answers is not bound here.  It is read again beside the
	# provider type, in the pre-flight that owns the order, and a lexical
	# nothing reads is a lexical a reader has to go looking for.
	Genesis::CI::Preflight::assert_not_disowned($top,
		command => "$env_name deploy",
		outcome => 'Nothing was deployed.',
		in_job  => 'A job never deploys what its own configuration disowns.',
		locally => 'warn');

	# Everything a pipeline deploy asks before it deploys, in the one place
	# that owns the order.  What it settled is held here rather than unpacked,
	# because the session in it is what the post-deploy commit is made inside
	# and the steps after this one read what the classification decided.
	my $preflight;
	my $pipeline_git;
	my $pipeline_branch;
	if ($top->pipeline_enabled) {
		$preflight = _deploy_preflight($top, $env_name, \%options);
		($pipeline_git, $pipeline_branch) = @{$preflight}{qw/git branch/};
	}

	$options{'disable-reactions'} = ! delete($options{reactions});
	my $env = $top->load_env($env_name)->with_vault()->with_bosh();

	# Everything a pipeline deploy asks, it asks in the pre-flight above.
	# The last check to leave here was the warning about deploying by hand
	# what a pipeline manages, which spoke only where a predecessor was
	# named, said nothing about the locks it was warning of, and put its
	# question behind --yes.  The provider gate replaces it under D73: it
	# refuses rather than warns, it asks for an acknowledgement --yes cannot
	# answer, and it is asked before the environment is loaded rather than
	# after.
	#
	# --pull is gone with --no-fetch (D40).  It was a second source of truth
	# beside the refresh: the operator chose whether the branch was brought
	# up to date, and a deploy that skipped the pull read a branch nobody had
	# moved.  The refresh above is now the one way the branch gets current,
	# and M8 retires the two private subs this block was the last caller of.

	my $deployment_files = $env->deployment_cache_path_lookup('existing');
	if (scalar(keys %$deployment_files)) {
		# TODO: Support the --resume option here, to resume a previous deployment.
		#       This will have to use a step file that indicates the last step
		#       that was completed, and then resume from there, if possible.
		if ($options{clear}) {
			$env->deployment_cache_clear;
		} else {
			my $cache_dir = $env->deployment_cache_dir;
			my $file_list = join("\n", map {
				sprintf("[[  - >>%s", basename($_))
			} sort values %$deployment_files);
			warning(
				"\nThere are cached deployment files in #C{%s} from the previous failed or interrupted deployment:\n%s%s",
				$cache_dir, $file_list,
				$deployment_files->{state}
					? "\n\n[[#Yr{IMPORTANT:} >>The cached files contain a state file, which ".
					"may contain values necessary to run this deployment successfully.  ".
					"Please copy it to a safe location, then use the --STATE-FILE-PATH ".
					"option to use that file instead of a potentially outdated one from ".
					"a previously successful deployment instead of clearing and ".
					"continuing with this deployment."
					: ""
			);
			if (!$options{yes} && in_controlling_terminal()) {
				# Ask the user if they want to clear the cache directory
				prompt_for_boolean(
					"Do you want to clear the cache directory and start a new deployment? [y|n]",
					0
				) || bail("Aborted by user");

				$env->notify("Clearing deployment cache files...");
				$env->deployment_cache_clear;
			} else {
				bail(
					"\nCowardly refusing to clear deployment cache files in #C{%s} ".
					"without user confirmation.\n\n".
					"Use the #Y{--clear} option to clear them, or run the command ".
					"without the #Y{--yes} option in an interactive terminal to be ".
					"prompted.",
					$cache_dir
				);
			}
		}
	}

	# Derive a default reason from the pipeline commit range when the
	# env is on a pipeline branch and no --reason was supplied.
	if (!defined($reason) && $pipeline_git && $pipeline_branch) {
		if (my $derived = _derive_deploy_reason($env, $pipeline_git)) {
			$reason = $derived;
			$env->notify("derived deploy reason from pipeline history:\n%s", $reason);
		}
	}

	# Check if the user is compelled to provide a reason for the deployment
	if (my $min_size = $env->deployment_change_reason_required_size_policy) {
		# TODO: Maybe prompt for a reason if it wasn't provided
		bail(
			"Cannot deploy environment #C{%s} without a reason (minimum length is %d characters).\n".
			"Please provide a reason after any options on the command line",
			$env->name, $min_size
		) unless length($reason//'') >= $min_size;
	}
	$reason //= 'unknown'; # if not provided or required, use 'unknown' as the reason

	if (scalar(grep {$_} ($options{fix}, $options{recreate}, $options{'dry-run'})) > 1) {
		command_usage(1,"Can only specify one of --dry-run, --fix or --recreate");
	}
	my $noprompt = $options{yes} // 0;
	$ENV{BOSH_NON_INTERACTIVE} = 'true' if $noprompt;
	my $dryrun = $options{'dry-run'} // 0;

	bail(
		"The following options cannot be specified for #M{create-env}: %s",
		join(", ", @invalid_create_env_opts)
	) if $env->use_create_env && @invalid_create_env_opts;

	if (delete $options{'fix-checks'}) {
		$options{'fix-stemcells'} = 1 unless $env->use_create_env;
		$options{'fix-secrets'} = 1;
	}

	info "\nPreparing to deploy #C{%s}:\n  - based on kit #c{%s}\n  - using Genesis #c{%s}%s",
		$env->name, $env->kit->id, $Genesis::VERSION,
		_format_deploy_feature_opt_in($env);
	if ($pipeline_branch) {
		info "  - from branch #c{%s}", $pipeline_branch;
	}
	if ($env->use_create_env) {
		info "  - as a #M{create-env} deployment.";
	} else {
		info "  - to '#M{%s}' BOSH director at #c{%s}.", $env->bosh->{alias}, $env->bosh->{url};
	}
	# Specify the environment iaas and scale
	my $scale = $env->scale;
	if ($scale) {
		info("  - to a #Y{%s}-scale #G{%s} IaaS target", $scale, $env->iaas);
	} else {
		info("  - targeting #G{%s} IaaS", $env->iaas);
	}
	info "";

	# Check if the kit supports the environment's IaaS
	if (my $supported_iaas = $env->kit->metadata('supports')) {
		bail(
			"Genesis kit #C{%s} does not support the IaaS type #C{%s} - ".
			"you will need to use a different kit/version.",
			$env->kit->id, $env->iaas
		) unless in_array($env->iaas, @$supported_iaas);
	}

	my ($cloud_config, $network_map, $cpi_config, $credhub_secrets, $cpi_err) = ();
	my $ok = 1;
	if (! $env->use_create_env) {
		# TODO: refactor to clean this up a bit

		# CPI config management is an OCFP concern.  Non-OCFP envs have
		# CPI config managed externally (typically via the director's
		# cloud-config), so skip the check/fix and the default-CPI notify.
		if ($env->is_ocfp) {
			if ($env->cpi_enabled) {
				if ($env->has_hook('cpi-config')) {
					$env->notify("checking CPI config for #C{%s} deployment...", $env->name); #FIXME: move this into the _check_cpi_config method
					my $check_result = $env->_check_cpi_config();

					bail(
						"Cannot provide the required CPI config: %s",
						$check_result->{msg}
					) if $check_result->{fatal}; # Should we just set a flag instead, and skip to next check?

					if ($check_result->{state} ne 'ok') {
						if ($dryrun) {
							dryrun(
								"CPI config check failed: %s\n\nThis would be fixed if not in dry-run mode.",
								$check_result->{msg}
							);
						} else {
							# Just going to force the fix for now
							my $fix_result = $env->_fix_cpi_config(
								$check_result->{state},
								$check_result->{fix_data},
								noprompt => 1,
							);
							bail(
								"Could not update required CPI config: %s",
								$fix_result->{msg}
							) unless $fix_result->{result} eq 'ok';
						}
					}
				}
			} else {
				# Use the cpi config provided by the director (via exodus data)
				$env->notify(
					"Using %s CPI config from #M{%s} BOSH director...",
					scalar $env->director_exodus_lookup('default_cpi_config','default'),
					$env->bosh->{alias}
				);
			}
		}

		if ($env->can_build_cloud_configs) {
			# Refactor this to use _check_cloud_config and _fix_cloud_config like the cpi stuff above
			if ($env->has_hook('cloud-config')) {
				$env->notify("checking cloud configs for #C{%s} deployment...", $env->name);

				# The cloud config synthesis reads the network claims on the
				# director and a real deploy rewrites them, so the deploy holds
				# the network claims lock from here until the claims are
				# submitted.  A dry run only reads, so it takes no lock.
				my $lock_held = _deploy_network_claims_lock(
					$env, dryrun => $dryrun, yes => $options{yes}
				);

				# While the lock is held, a signal has to unwind through the
				# release below instead of killing the process with the lock
				# still recorded on the director.  HUP is in the list because
				# these deploys are run over ssh from a bastion, and a dropped
				# session hangs up every process in it -- which is how a lock
				# outlives the process that took it.
				local $SIG{INT}  = $lock_held ? sub { die "Interrupted by user\n" } : $SIG{INT};
				local $SIG{TERM} = $lock_held ? sub { die "Terminated\n" }         : $SIG{TERM};
				local $SIG{HUP}  = $lock_held ? sub { die "Hung up\n" }            : $SIG{HUP};
				local $SIG{QUIT} = $lock_held ? sub { die "Quit\n" }               : $SIG{QUIT};

				eval {
					($cloud_config, $network_map) = $env->run_hook('cloud-config');

					# TODO: Support multiple cloud configs
					my $cloud_config_name = $env->name.'.'.$env->type;
					my $cloud_config_dir = $env->workpath('cloud-configs');
					my $diff_dir = $env->workpath('cloud-config-diffs');
					my $new_path = "$cloud_config_dir/${cloud_config_name}.yml";
					my $new_path_diff = "$diff_dir/${cloud_config_name}.yml";
					info "[[  - >>cloud config synthesized.";

					# Wrap this in an eval block to ensure the lock is cleared on error
					mkdir($cloud_config_dir) unless -d $cloud_config_dir;
					mkdir($diff_dir) unless -d $diff_dir;
					mkfile_or_fail($new_path, 0644, $cloud_config);
					my ($out, $rc, $err) = run( 'spruce merge --skip-eval $1 > $2',$new_path,$new_path_diff);
					bail "Error generating cloud config for diff: %s", $err//$out if $rc;
					info "[[  - >>checking for existing cloud config on #M{%s} BOSH director...", $env->bosh->{alias};
					if ($env->bosh->has_config('cloud',$cloud_config_name)) {
						my $old_path = "$cloud_config_dir/current-${cloud_config_name}.yml";
						info "[[  - >>comparing generated cloud config with existing cloud config...";
						$env->bosh->download_configs($old_path,'cloud',$cloud_config_name);
						my ($out, $rc, $err) = run(
							fake_tty("$cloud_config_dir/spruce-out.txt",'spruce','diff',$old_path, $new_path_diff)
						);
						bail "Error comparing cloud configs: %s", $err if $rc;

						$out = decode_utf8($out) =~ s/\A\s*(.*?)\s*\z/$1/mrs;
						if ($out) {
							$out =~ s/\(root level\)/<root>/m;
							info "[[  - >>#yui{found the following differences:}\n\n%s", $out;
							if ($dryrun) {
								_deploy_dryrun_cloud_config_warning($env, $cloud_config_name, 'outdated');
								dryrun(
									"Cloud config check failed: %s\n\nThis would be fixed if not in dry-run mode.",
									$out
								);
							} else {
								_deploy_confirm(
									"Upload the new cloud config to the BOSH director ('no' will cancel deploy)? [y|n]",
									yes => $options{yes}, default => 1
								) or bail "Aborted by user!";
								my $last_check = $env->bosh->check_network_lock;
								bail(
									"Network claims lock was lost since last checked (may have become stale and removed) -- cannot proceed with deployment!"
								) if ($last_check->{status} eq 'unlocked');
								info(
									"Uploading new cloud config to #M{%s} BOSH director...",
									$env->bosh->{alias}
								);
								eval {
									# Upload the new cloud config
									$env->bosh->upload_config_from_file($new_path,'cloud',$cloud_config_name);
								} or bail(
									"Failed to upload cloud config %s to BOSH director: %s\n\nContent:\n%s",
									$cloud_config_name,
									fix_wrap($@),
									slurp($new_path)
								);
								info "[[  - >>cloud config for #C{%s} deployment has been updated.\n", $env->name;
							}
						} else {
							info "[[  - >>no changes required in cloud config; proceeding with deploy.\n";
						}
					} elsif ($dryrun) {
						_deploy_dryrun_cloud_config_warning($env, $cloud_config_name, 'missing');
						dryrun(
							"Cloud config #C{%s} missing.  This would be created and uploaded if not in dry-run mode.  Content:\n\n%s",
							$cloud_config_name, slurp($new_path_diff)
						);
					} else {
						info(
							"[[  - >>uploading new cloud config to #M{%s} BOSH director...",
							$env->bosh->{alias}
						);
						eval {
							$env->bosh->upload_config_from_file($new_path,'cloud',$cloud_config_name);
						} or bail(
							"Failed to upload cloud config %s to BOSH director: %s\n\nContent:\n%s",
							$cloud_config_name,
							fix_wrap($@),
							slurp($new_path)
						);
						info "[[  - >>cloud config for #C{%s} deployment has been created.\n", $env->name;
					}

					if (ref($network_map) eq 'HASH') {
						if ($dryrun) {
							dryrun(
								"Network map would be updated on the BOSH director if not in dry-run mode."
							);
						} else {
							# Update the network map on the director's exodus network data
							$env->notify(
								"submitting network claims for this deployment to #M{%s} BOSH director...",
								$env->bosh->{alias}
							);
							eval {$env->bosh->vault->set_path(
								$env->bosh->exodus_path.'/network', $network_map, flatten => 1, clear => 1
							);};
							if ($@) {
								info("  - #R{failed to update network map}\n");
								bail("\nCannot continue without a valid network map:\n\n%s", $@);
							}
							$env->bosh->clear_network_lock();
							info("  - #G{network map successfully updated }#Gi{(lock removed)}\n");
						}
					}
				}; # end eval

				# Release the lock on every exit path.  A successful deploy already
				# released it when the network claims were submitted.
				my $err = $@;
				_deploy_release_network_claims_lock($env) if $lock_held;
				die $err if $err;
			} else {
				warning(
					"Kit #C{%s} does not provide a cloud-config hook, so cloud configs ".
					"will not be generated.  Ensure that the BOSH director has the ".
					"necessary cloud config in place.",
					$env->kit->id,
				);
			}
		} elsif ($env->is_ocfp) {
			# OCFP env opted out via genesis.manage-cloud-configs: false.
			# For non-OCFP envs the cloud-config is always externally
			# managed, so skip the warning entirely — it's not actionable.
			warning(
				"Cloud Configs will not be generated for this deployment.  ".
				"Ensure that the BOSH director has the necessary cloud config in place."
			);
		}
		my @hooks = qw(blueprint manifest deploy);
		push @hooks, grep {$env->kit->has_hook($_)} qw(check pre-deploy post-deploy);
		$env->download_required_configs(@hooks);
	} # end if ! $env->use_create_env

	# Check environment for viability
	$env->{notify_prefix_overrides}{'determining manifest fragments for merging...'} = sprintf(
		"[[  - >>checking manifest components...\n[[  - >>",
	);
	my $env_check = $env->_check_environment_viability();
	bail("%s", $env_check->{msg}) if $env_check->{fatal};
	$ok = 0 unless $env_check->{state} eq 'ok';
	my $kit_files = $env_check->{kit_files};

	# Check or fix secrets for required items
	my $fix_secrets = delete($options{'fix-secrets'}) || $Genesis::RC->get('fix_on_deploy') ne 'never';
	if ($fix_secrets && !$dryrun) {
		my $secret_fixes = $env->_fix_secrets(noprompt => $noprompt);
		bail(
			"Failed to fix secrets: %s",
			$secret_fixes->{msg}
		) if $secret_fixes->{fatal};
		$env->notify("%s", $secret_fixes->{msg});
		$ok = 0 unless $secret_fixes->{result} =~ /^(ok|warning)$/;

	} else {
		my $secrets_check = $env->_check_secrets();
		my $msg_type = $secrets_check->{state};
		$msg_type = '%s' if $msg_type eq 'ok';

		$env->notify($msg_type => $secrets_check->{msg});
		if ($secrets_check->{state} !~ /^(ok|warning)$/) {
			dryrun(
				"Secrets would be automatically fixed if not in dry-run mode."
			) if $fix_secrets;
			$ok = 0;
		}
	}

	# Checking yaml files - more of a visual dump than a validation
	if (envset("GENESIS_CHECK_YAML_ON_DEPLOY")) {
		if (my @missing = $env->missing_required_configs('blueprint')) {
			$env->notify("#Y{Required BOSH configs not provided - can't list manifest YAML files: %s}", join(', ', @missing));
		} else {
			$env->notify("inspecting YAML files used to build manifest...");
			my @yaml_files = $env->format_yaml_files('include-kit' => 1, padding => '  ', kit_files => $kit_files);
			info join("\n",@yaml_files)."\n";
		}
	}

	# Check manifest validation
	if ($ok) {
		if (my @missing = $env->missing_required_configs('manifest')) {
			$env->notify("#Y{Required BOSH configs not provided - can't check manifest viability: %s}", join(', ', @missing));
		} else {
			$env->notify("running manifest viability checks...");
			$env->manifest_provider->unredacted->validate or $ok = 0;
		}
	}

	# Check for release overrides
	my $release_check = $env->_check_release_overrides();
	my $confirm = $noprompt ? 'never' : $Genesis::RC->get(
		'confirm_release_overrides' => $env->top->config->{'confirm_release_overrides'} // 'outdated'
	);
	if ($release_check->{state} ne 'ok' && !$dryrun) {
		if ($confirm eq 'always' || ($confirm eq 'outdated' && $release_check->{state} eq 'outdated')) {
			bail(
				"Cannot prompt user for confirmation of release version overrides - ".
				"not in a controlling terminal.  Please specify #Y{-y|--yes} to bypass this prompt."
			) unless in_controlling_terminal;

			$ok = 0 unless prompt_for_boolean(
				"Release version overrides detected.  Proceed with release version overrides? [y|n]",
				1
			);
		}
	}

	# Check for and potentially fix stemcell availability
	# FIXME: This won't be accurate if there is a missing CPI config for this env
	if (!$env->use_create_env) {
		my $stemcell_check_result = $env->_check_stemcells();
		if ($stemcell_check_result->{state} ne 'ok') {
			if ($options{'fix-stemcells'}) {
				if ($dryrun) {
					dryrun(
						"\nStemcell check failed: %s\n\nThis would be fixed if not in dry-run mode.",
						$stemcell_check_result->{msg}
					);
				} else {
					my $stemcell_fix = $env->_fix_stemcells(
						$stemcell_check_result->{fix_data},
						noprompt => $noprompt,
					);
					bail(
						"Failed to fix stemcells: %s",
						$stemcell_fix->{msg}
					) if $stemcell_fix->{fatal};
					$env->notify("%s", $stemcell_fix->{msg}); # Check if this makes sense or is reduntant
				}
			} else {
				$env->_advise_stemcell_updates(
					$stemcell_check_result->{fix_data},
				);
				bail(
					"Stemcell check failed: %s",
					$stemcell_check_result->{msg}
				);
			}
		}
	}

	bail(
		"Preflight checks failed; deployment operation halted."
	) unless $ok;

	# The session goes to _post_deploy, which finishes it when the tree is
	# clean and aborts naming the files when it is not.  Nothing else on this
	# path finishes it, so no early return in this sub can skip the
	# assertion, and the gate's own finish, which runs straight after this
	# function returns, then finds a session that is already closed and does
	# nothing to it.  One path inside _post_deploy does leave ahead of the
	# assertion, which is the dry run's exit before any deployment has been
	# made, and that exit never comes back here, so the gate's finish never
	# runs and the session is left open.  What closes it there is the
	# session's own last-resort net, which aborts rather than finishes, and
	# the net prints its notice to stderr because the status the dry run
	# left behind is zero.
	$ok = $env->deploy(%options, network_map => $network_map, reason => $reason,
		session => $preflight && $preflight->{session});

	if ($ok) {
		success "#M{%s}/#c{%s} deployed successfully.\n", $env->name, $env->type;
		# The status is handed back rather than exited with, because the
		# deploy declares DEPLOYED_STATE and the gate holds a branch session
		# open around this call.  An exit here would leave that session for
		# the last-resort net to find, and the operator would be told about
		# a session they never asked for under the deployment they did.
		return 0;
	} else {
		bail "[#M{%s}] #R{Deployment Failed}", $env->name;
	}
}

# _prior_env_record - the one read of the predecessor's exodus record {{{
#
# Two readers want this record, the prior-env check for the fact that the
# predecessor deployed at all and the due computation for the commit it
# certified, so the design gives both one read (FWT-1141).  A post-failed
# result counts, because the BOSH deploy itself succeeded and the environment
# is running.
#
# The read is of the deployment audits under the predecessor's own exodus
# base, keyed on the compact timestamp, which is the set every reader of a
# certified commit goes through.  The flat record beside them holds the same
# facts under different names and is the staleness comparison's half.
#
# The read is wrapped in an eval, so a predecessor whose history cannot be
# read at all is answered the same way as one that never deployed, and the
# check that reads this answer is where that refusal is worded.
sub _prior_env_record {
	my ($env, $prior_name) = @_;
	return undef unless $prior_name;

	# exodus_mount already ends with '/', so the path is composed directly.
	my $path = $env->exodus_mount.$prior_name.'/'.$env->type.'/deployments';
	my $deploys = eval { $env->vault->get_path($path) };
	return undef unless $deploys && ref($deploys) eq 'HASH';

	# Newest first, the entry names being the compact timestamps the deploy
	# writes, so the record answered is the predecessor's latest deployment
	# that reached the director rather than whichever one a hash happened to
	# hand back first.
	#
	# Each entry is read through the same constructor
	# Genesis::Env::DeploymentManager::_all reads them through, with
	# from_storage, because a record may predate the current schema by years
	# and the two readers must not disagree about what it says.  A record
	# read raw here and normalised there is a predecessor that has deployed
	# by one reader's reckoning and never deployed by the other's.  The
	# environment handed to the constructor is the deploying one rather than
	# the predecessor, which the constructor only stores; the predecessor is
	# not loaded as an environment at all, because D79 forbids that read.
	require Genesis::Env::Deployment;
	for my $at (sort {$b cmp $a} keys %$deploys) {
		my $entry = $deploys->{$at};
		next unless ref($entry) eq 'HASH';
		my $record = Genesis::Env::Deployment->new(
			{from_storage => 1}, $env, timestamp => $at, %$entry
		);
		# succeeded is true of success and of post-failed, which are the two
		# results that mean the BOSH deploy reached the director.
		next unless $record->succeeded;
		return {
			at     => $record->timestamp,
			result => $record->result,
			git    => $record->lookup('git') || {},
		};
	}
	return undef;
}

# }}}
# _assert_prior_env_deployed - the predecessor must have deployed at all {{{
#
# A hard invariant with no --yes override.  It judges the record
# _prior_env_record already read rather than reading again, and it asks only
# whether the predecessor has ever deployed; which commit it certified is the
# due computation's question, and a predecessor that never certified one holds
# everything below it under D43 rather than failing this check.
sub _assert_prior_env_deployed {
	my ($env, $prior_name, $record) = @_;
	return 1 if $record;

	bail({exitcode => DATAERR},
		"Cannot deploy #C{%s}: its pipeline predecessor #C{%s} has never been ".
		"successfully deployed.\n\nDeploy #C{%s} first, then retry.  Nothing ".
		"was deployed.",
		$env->name, $prior_name, $prior_name
	);
}

# }}}
# _warn_stale_pipeline - the first of the pre-flight's warnings, under D43 {{{
#
# The deploy computes no diff of its own.  pipeline_staleness is the one
# staleness query (D103), and it reads three things: the commit the applied
# record names, a git path diff from that commit to control over each
# environment's own defining paths, and each environment's compiled
# dependency set against the set its last deployment recorded reading, which
# is D77's fact standing where the compile had only a prediction.  The
# propagate pre-flight and pipeline-status ask the same sub the same
# question, and it takes the git handle because a path diff is a git
# question.
#
# What comes back is one entry per changed environment, naming the
# environment and the reason it changed, and the warning prints the reason
# the query gave rather than deciding one of its own.  A repository with no
# pipeline, and one the apply has never run against, both answer nothing, so
# no guard is needed here for either.
sub _warn_stale_pipeline {
	my ($top, $git) = @_;

	my $changed = $top->pipeline_staleness($git);
	return 0 unless $changed && @$changed;

	warning(
		"\nThe pipeline is stale.  Control has changed the shape of %s since ".
		"#C{genesis pipeline-apply} last applied it:\n%s\n\nRun #C{genesis ".
		"pipeline-apply} to bring the pipeline back into step with control.",
		count_nouns(scalar(@$changed), 'environment'),
		join("\n",
			map {sprintf("  - #C{%s}: %s", $_->{env}, $_->{reason})} @$changed)
	);

	return scalar(@$changed);
}

# }}}
# _warn_commits_due - the second of the pre-flight's warnings, under D35 {{{
#
# The due set is the walk's own computation, run read-only for one
# environment, so the deploy and the propagate run read the same durable
# state and cannot disagree about what is due.  A predecessor that has never
# certified a commit holds everything below it (D43), so the set is empty and
# we name the ancestor that holds it rather than report that we cannot tell.
# There is one remedy, and it is genesis propagate (D37).
#
# The holding ancestor is named off the hold's own reason, where the walk put
# it, rather than off any read of our own, for the reason the stale warning
# prints the staleness query's reason: two readers deciding one fact is how
# the two come to disagree about it.
sub _warn_commits_due {
	my ($env, $record) = @_;

	# A walk that failed for this environment empties its pending list, so a
	# reader that went straight to that list would print the silence of a
	# branch with nothing due over a question nobody answered.  We say which
	# it was, and we warn nothing else, the rest of the record being whatever
	# the failure left behind.
	if (my $error = $record->{error}) {
		warning(
			"\nCould not tell what is due to #C{%s}: %s\n\nThe pre-flight goes ".
			"on from here, and the deploy proper will meet the same fault if ".
			"that is what it was.  Run #C{genesis propagate} once the reason ".
			"above is settled.",
			$env->name, $error
		);
		return [];
	}

	my @due = @{$record->{pending} || []};

	# The uncertified ancestor of D43, which holds everything below it.  It is
	# read with the pending list rather than ahead of it, because the sentence
	# below says that nothing is due and only an empty list makes that true.
	# Nothing routed can stand beside such a hold today, hold_for returning on
	# the uncertified ancestor at lib/Genesis/CI/Walk.pm:459 before it reads
	# any file, but a hold order that changed would otherwise turn the
	# sentence into a claim that suppressed the list underneath it.
	my ($uncertified) = grep {
		($_->{reason} // '') eq 'ancestor-uncertified'
	} @{$record->{held} || []};
	if ($uncertified && !@due) {
		warning(
			"\nNothing is due to #C{%s}.  Its ancestor #C{%s} has certified no ".
			"control commit, so it holds everything below it until it deploys.",
			$env->name, $uncertified->{ancestor}
		);
		return [];
	}

	return [] unless @due;

	# The proposed record is read here rather than above, because an
	# environment with nothing due has nothing a pull request could be
	# proposing and a read made there would be a vault call every deploy
	# paid for and no deploy used.
	my $proposed = $env->proposed_record;
	warning(
		"\n%s due to #C{%s} and not yet on #C{%s}:\n%s\n%s\nRun #C{genesis ".
		"propagate} to deliver %s.",
		count_nouns(scalar(@due), 'commit'), $env->name, $env->deployment_slug,
		join("\n", map {
			sprintf("  - control\@%s  %s",
				substr($_->{control_commit}, 0, 8), $_->{subject})
		} @due),
		$proposed ? sprintf("\nPR #%s proposes control\@%s, not yet merged.\n",
			$proposed->{number}, substr($proposed->{control_commit}, 0, 8)) : '',
		scalar(@due) == 1 ? 'it' : 'them'
	);
	return \@due;
}

# }}}
# _confirm_commits_due - the one prompt -y answers on this path {{{
#
# Outside a controlling terminal we warn and proceed, because a deploy must
# not stop to ask where nobody can answer, which is the opposite of the
# provider gate's rule for the opposite reason: the gate refuses where it
# cannot ask, and this one carries on.  A deploy past a due commit is a thing
# an operator may legitimately want, and a deploy past an unlocked pipeline
# is not.
#
# It is its own sub so that the terminal half can be driven directly, no
# spawned command having a terminal to answer from.
sub _confirm_commits_due {
	my ($env_name, $due, $options) = @_;

	return 1 unless $due && @$due;
	return 1 if $options->{yes};
	return 1 unless in_controlling_terminal();

	return 1 if prompt_for_boolean("Deploy #C{$env_name} anyway? [y|n]", 0);
	bail({exitcode => ABORTED}, "Aborted.  Nothing was deployed.");
}

# }}}
# _warn_drifted - the third of the pre-flight's warnings, under D33 {{{
#
# The branch should be a verified mirror of the control commit its newest
# marker names, over the propagation set and nothing else.  Where it is not,
# somebody pushed a hand commit, which is the emergency hatch: legal,
# temporary by construction, and never silent.  We name the files and deploy,
# because refusing would leave the operator with nothing to do in the case
# the hatch exists for, and the record tells the two commits apart afterwards
# (D87).
#
# A branch carrying no marker anywhere has been delivered nothing, and there
# is no snapshot to compare it against, so this says nothing rather than
# reading the whole branch as drift.
#
# The environment is the loaded one rather than the pre-flight's bare one,
# because the set is built from the kit as well as from the environment file
# and a bare environment has none to ask.
#
# propagation_files answers a list, so it goes straight into diff_files's
# pathspecs and no reference reaches git.
sub _warn_drifted {
	my ($env, $git) = @_;

	my $branch    = $env->deployment_slug;
	my $certified = Genesis::CI::Marker::newest($git, $branch) or return [];
	my $diff  = $git->diff_files($branch, $certified, $env->propagation_files);
	my @files = sort(@{$diff->{changed}}, @{$diff->{deleted}});
	return [] unless @files;

	warning(
		"\nThe branch #C{%s} differs from the snapshot of control\@%s that its ".
		"newest marker names, in %s:\n%s\n\nDeploying it anyway, and the ".
		"deployment record will name the branch commit as deployed and ".
		"control\@%s as certified.",
		$branch, substr($certified, 0, 8), count_nouns(scalar(@files), 'file'),
		join("\n", map {"  - $_"} @files), substr($certified, 0, 8)
	);
	return \@files;
}

# }}}
# The two subs that resolved a source commit and copied the predecessor's
# state onto the branch are gone.  D35 withdraws the step outright rather
# than renaming it, so what the predecessor certified reaches this branch
# through the propagate run, in control order, under D34.
sub terminate {
	my ($env, $reason, @extras) = @_;
	command_usage(1) if @extras || !defined($env);

	my %options = %{get_options()};
	$env = Genesis::Top->new('.')->load_env($env)->with_vault()->with_bosh()
		unless $env->isa('Genesis::Env');

	# Check if the user is compelled to provide a reason for the deployment
	if (my $min_size = $env->deployment_change_reason_required_size_policy) {
		# TODO: Maybe prompt for reason if not provided?
		bail(
			"Cannot terminate environment #C{%s} without a reason (minimum length is %d characters).\n".
			"Please provide a reason after any options on the command line",
			$env->name, $min_size
		) unless length($reason//'') >= $min_size;
	}

	my $flags = join(" ", map {
		if ($_ =~ m/(resources|secrets|user-secrets|credhub|networking)/) {
			$options{$_} ? "--$_" : "--no-$_";
		} else {
			"--$_";
		}
	} (sort keys %options));

	my %clean_up = ();
	my $default_cleanup = delete($options{'no-cleanup'}) ? 0 : 1;
	for my $opt (qw/resources secrets user-secrets credhub networking/) {
		$clean_up{$opt =~ s/-/_/gr} = exists($options{$opt})
			? (delete($options{$opt}) ? 1 : 0)
			: $default_cleanup;
	}

	my $noprompt = delete($options{'yes'})//0;
	my $dry_run = delete($options{'dry-run'})//0;
	my $force = delete($options{'force'})//0;

	bug(
		"Undefined options passed in from the Genesis command handler: %s",
		join(", ", sort keys %options)
	) if keys %options;

	my $action_desc = $dry_run ? 'would' : 'will';
	my $msg = (
		"This $action_desc #R{terminate} this deployment:\n".
		"[[  - >>#R{all its VMs and persistent disks} $action_desc be #R{destroyed}."
	).(
		$clean_up{secrets}
		? "\n[[  - >>#R{this environment's generated secrets} $action_desc be #R{removed}".
			($default_cleanup ? " (use --no-secrets to keep)." : ".")
		: "\n[[  - >>#G{this environment's generated secrets} $action_desc be left in place".
			($default_cleanup ? "." : " (use --secrets to remove).")
	).(
		$clean_up{user_secrets}
		? "\n[[  - >>#R{this environment's user-provided secrets} $action_desc be #R{removed}".
			($default_cleanup ? " (use --no-user-secrets to keep)." : ".")
		: "\n[[  - >>#G{this environment's user-provided secrets} $action_desc be left in place".
			($default_cleanup ? "." : " (use --user-secrets to remove).")
	);
	$msg .= (
		(
			$clean_up{credhub}
			? "\n[[  - >>#R{this environment's credhub secrets} $action_desc be #R{removed}".
				($default_cleanup ? " (use --no-credhub to keep)." : ".")
			: "\n[[  - >>#G{this environment's credhub secrets} $action_desc be left in place".
				($default_cleanup ? "." : " (use --credhub to remove).")
		).(
			$clean_up{resources}
			? "\n[[  - >>#R{all unused resources} $action_desc be #R{removed} from its BOSH director".
				($default_cleanup ? " (use --no-resources to keep)." : ".")
			: "\n[[  - >>#G{all unused resources} $action_desc be left in place on its BOSH director".
				($default_cleanup ? "." : " (use --resources to remove).")
		).(
			$clean_up{networking}
			? "\n[[  - >>#R{all claimed networks} $action_desc be #R{removed} from its BOSH director".
				($default_cleanup ? " (use --no-networking to keep)." : ".")
			: "\n[[  - >>#G{all claimed networks} $action_desc be left in place on its BOSH director".
				($default_cleanup ? "." : " (use --networking to remove).")
		).(
		"\n[[  - >>#R{all associated BOSH configs on its BOSH director} $action_desc be #R{removed}."
		)
	) unless $env->use_create_env;
	$env->notify($msg);

	if (!$dry_run && !$noprompt) {
		notice(
		"\nYou can run this command with the #Y{--dry-run} option to see exactly what ".
		"would be removed without actually terminating the deployment or removing ".
		"any asscoiated items."
		);
		warning "\nThis action is #R{irreversible} and #R{cannot be undone}!";
		my $msg = sprintf(
			"Are you sure you want to terminate #M{%s}/#c{%s} deployment? [y|n]",
			$env->name, $env->type
		);
		prompt_for_boolean($msg, 0) or bail "Aborted by user!";
	}

	my $ok = $env->terminate(
		dryrun    => $dry_run,
		noprompt  => $noprompt,
		force     => $force,
		reason    => $reason,
		flags     => $flags,
		%clean_up
	);
	if ($dry_run) {
		notice(
			"\n#M{%s}/#c{%s} termination dry-run completed %s.\n",
			$env->name, $env->type,
			$ok ? "#g{successfully}" : "with #r{errors}"
		);
		exit($ok ? 0 : 1);
	}
	if ($ok) {
		success "\n#M{%s}/#c{%s} terminated successfully.\n", $env->name, $env->type;
		exit 0;
	} else {
		bail "\n#M{%s}/#c{%s} #R{termination failed!}", $env->name, $env->type;
	}
}

sub addon {
	command_usage(1) if @_ < 1;

	my ($name, $script, @args) = @_;
	$script = 'help' if !$script || $script eq '--help' || $script eq '-h';
	my $env = Genesis::Top->new('.')->load_env($name)->with_vault();

	$env->kit->check_prereqs($env)
		or bail "Cannot use the kit specified by %s.\n", $env->name;

	$env->has_hook('addon', script => $script)
		or bail "#R{Kit %s does not provide an addon hook!}", $env->kit->id;

	$env->download_required_configs('addon', "addon-$script");

	info(
		"Running #G{%s} addon for #C{%s} #M{%s} deployment",
		$script, $env->name, $env->type
	) unless $script eq 'help';

	$env->run_hook('addon', script => $script, args => \@args)
		or exit 1;
}

sub env_shell {
	append_options(redact => ! -t STDOUT);
	command_usage(1) if @_ != 1;
	my $env = Genesis::Top->new('.')->load_env($_[0])->with_vault();
	$env->with_bosh() unless get_options->{'no-bosh'};
	$env->shell(%{get_options()});
}

# _format_deploy_feature_opt_in - returns the " (feature opt-in: ...)" tail
# for the deploy header, or '' when the env has no effective floor.
sub _format_deploy_feature_opt_in {
	my ($env) = @_;
	my $fc = $env->effective_minimum_version;
	return '' if !$fc || $fc eq '0.0.0';
	return sprintf(
		" (feature opt-in: #c{v%s} from #c{%s})",
		$fc, $env->effective_minimum_version_source
	);
}

# _deploy_dryrun_cloud_config_warning - say that a dry run validates against the director's copy of the cloud config {{{
sub _deploy_dryrun_cloud_config_warning {
	my ($env, $cloud_config_name, $state) = @_;

	if ($state eq 'outdated') {
		warning(
			"A dry-run never uploads cloud configs, so the #M{%s} BOSH ".
			"director will validate the manifest against its current copy ".
			"of cloud config #C{%s} rather than the updated one shown above.  ".
			"Errors from bosh about networks, vm types, disk types, vm ".
			"extensions, or availability zones that only the updated cloud ".
			"config defines are expected here and do not indicate a manifest ".
			"problem.  Deploy without #y{--dry-run} to upload the updated cloud ".
			"config before the manifest is validated.",
			$env->bosh->{alias}, $cloud_config_name
		);
	} elsif ($state eq 'missing') {
		warning(
			"A dry-run never uploads cloud configs, and the #M{%s} BOSH director ".
			"does not hold a cloud config named #C{%s}.  When bosh validates the ".
			"manifest it will only see the cloud configs already on the director, ".
			"so errors about unknown networks, vm types, disk types, vm extensions, ".
			"or availability zones are expected here and do not indicate a manifest ".
			"problem.  Deploy without #y{--dry-run} to create and upload the cloud ".
			"config before the manifest is validated.",
			$env->bosh->{alias}, $cloud_config_name
		);
	} else {
		bug("Unknown cloud config state '%s' for a dry-run warning", $state);
	}
	return 1;
}

# }}}
# _deploy_network_claims_lock - check the network claims lock on the director and take it for a real deploy {{{
sub _deploy_network_claims_lock {
	my ($env, %opts) = @_;
	my $bosh = $env->bosh;

	info({pending => 1},
		"[[  - >>checking for existing network claims lock on #M{%s} BOSH director...",
		$bosh->alias
	);
	my $current_lock = $bosh->check_network_lock;
	if ($current_lock->{status} eq 'unlocked') {
		info "#G{available}";
	} elsif ($current_lock->{status} eq 'locked') {
		info "#r{locked} %s", $current_lock->{description};
		if ($opts{dryrun}) {
			warning(
				"Another deploy holds the network claims lock: %s\n\nA dry run only ".
				"reads the network claims, so it carries on, but the deploy that holds ".
				"the lock can change those claims while this dry run is reading them.  ".
				"Any addresses this dry run reports may therefore differ from the ones ".
				"a real deploy would claim once the lock is free.",
				$current_lock->{description}
			);
		} else {
			bail(
				"Network claims are currently locked -- cannot proceed with deployment!"
			);
		}
	} elsif ($current_lock->{status} eq 'stale') {
		info "#y{locked (stale)} %s", $current_lock->{description};
		if ($opts{dryrun}) {
			dryrun(
				"Network claims are locked with a stale lock: %s\n\nThis would be ".
				"cleared if not in dry-run mode.", $current_lock->{description}
			);
		} elsif ($opts{yes}) {
			# --yes clears the stale lock without asking.
		} elsif (in_controlling_terminal) {
			prompt_for_boolean(
				"Clear the stale network claims lock and continue with deployment? [y|n]",
				0
			) or bail "Aborted by user!";
		} else {
			bail(
				"Network claims are locked with a stale lock: %s\n\nRerun with ".
				"#y{--yes} to clear it, or run this command in a terminal to be ".
				"asked.", $current_lock->{description}
			);
		}
		unless ($opts{dryrun}) {
			$bosh->clear_network_lock;
			$env->notify("checking cloud configs for #C{%s} deployment (continued)...", $env->name);
			info "[[  - >>stale network claims lock cleared.";
		}
	}

	if ($opts{dryrun}) {
		info "[[  - >>a dry run reads the network claims without taking the lock.";
		return 0;
	}

	info({pending => 1},
		"[[  - >>acquiring network claims lock on #M{%s} BOSH director...", $bosh->alias
	);
	$bosh->acquire_network_lock();
	info "#G{done}";
	return 1;
}

# }}}
# _deploy_confirm - answer a yes/no question for the deploy: --yes says yes, a terminal asks, a pipe stops {{{
sub _deploy_confirm {
	my ($question, %opts) = @_;
	return 1 if $opts{yes};
	return prompt_for_boolean($question, $opts{default} // 1) ? 1 : 0
		if in_controlling_terminal;
	bail(
		"Cannot ask \"%s\" without a controlling terminal.\n\nRerun with #y{--yes} ".
		"to answer yes, or run this command in a terminal to be asked.",
		$question =~ s/\s*\[y\|n\]\s*$//r
	);
}

# }}}
# _deploy_release_network_claims_lock - release the network claims lock if this process still holds it {{{
sub _deploy_release_network_claims_lock {
	my ($env) = @_;
	my $bosh = $env->bosh;
	return 0 unless $bosh->network_locked_by_me;

	$env->notify("cleaning up...");
	info({pending => 1},
		"[[  - >>releasing network claims lock on #M{%s} BOSH director...", $bosh->alias
	);
	$bosh->clear_network_lock();
	info "#G{done}";
	return 1;
}

# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
