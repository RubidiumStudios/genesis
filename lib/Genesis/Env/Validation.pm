package Genesis::Env::Validation;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::State;
use Genesis::Commands;
use Genesis::Term;
use Genesis::UI;

### Instance Methods {{{

# _check_environment_viability - check that the environment is viable for deployment {{{
sub _check_environment_viability {
	my ($self) = @_;

	my $checks = "environmental parameters";
	$checks = "BOSH configs and $checks" if scalar($self->configs);
	my $ok = 1;

	if ($self->has_hook('check')) {
		$self->notify("running %s checks...", $checks);
		$self->run_hook('check') or $ok = 0;
	} else {
		$self->notify("#Y{%s does not define a 'check' hook; $checks checks will be skipped.}", $self->kit->id);
	}

	my $kit_files = eval {
		$self->manifest_provider->kit_files(); # pre-warm the cache
	};
	if ($@) {
		info("[[  - >>manifest blueprint #R{failed}");
		return {
			state => 'error',
			fatal => 1,
			msg   => "Kit files could not be generated -- cannot continue with further checks."
		};
	}
	info("[[  - >>manifest blueprint #G{passed}");
	return {
		state     => $ok ? 'ok' : 'error',
		msg       => $ok ? "environmental is viable" : "environmental is not viable",
		kit_files => $kit_files,
	}
}

# }}}
# _check_secrets - check the secrets {{{
sub _check_secrets {
	my ($self) = @_;

	my %check_opts=(indent => '  ', validate => ! envset("GENESIS_TESTING_CHECK_SECRETS_PRESENCE_ONLY"));

	# FIXME: Revisit the _check_secrets(this ui wrapper) vs check_secrets (thing that
	# actually does the work) - this is a bit confusing and thus error-prone.
	my ($secrets_results, $secrets_msg) = $self->check_secrets(%check_opts);
	if ($secrets_results) {
		return {
			state => 'error',
			msg   => '#R{invalid secrets detected}',
		}	if ($secrets_results->{error});

		if ($secrets_results->{missing}) {
			my $msg = "#{missing secrets detected}";
			if ($self->is_vaultified && grep {$_->{source} eq 'manifest'} ($self->secrets_plan->secrets)) {
				$msg .= csprintf(
					" (you may need to run '#g{%s add-secrets} #Y{--import}' to import them from credhub)",
					$self->get_call_path_with_env
				);
			}
			return {
				state => 'error',
				msg   => $msg,
			};
		}
		return {
			state => 'warning',
			msg   => "#y{all secrets valid, but warnings were encountered.}",
		}	if ($secrets_results->{warn});
		return {
			state => 'ok',	
			msg   => "#G{all secrets valid}",
		}
	}
}
# }}}
# _fix_secrets - fix the secrets {{{
sub _fix_secrets {
	my ($self, %opts) = @_;
	my $ok = 1;

	# FIXME: Find a way to check if secrets are in the manifest (ie credhub
	# secrets), and import them if they're not in the vault but are in credhub
	# (does import skip secrets already in vault?)
	if ($self->is_vaultified && grep {$_->{source} eq 'manifest'} ($self->secrets_plan->secrets)) {
		bail(
			"Cannot safely fix secrets in vaultified environment with manifest ".
			"secrets, as they may already exist in credhub.  Please use the ".
			"'#g{%s add-secrets} #Y{--import}' to import them from ".
			"credhub manually, then add-secrets again without the #Y{--import} ".
			"option to add any missing secrets not found in credhub.",
			$self->get_call_path_with_env
		);
	}

	my ($rotate_results, $rotate_msg) = $self->rotate_secrets(
		notice      => "checking secrets, and repairing if necessary...",
		action      => 'repair',
		'no-prompt' => $opts{noprompt},
		invalid     => 1,
		interactive => 0,
		level       => 'line', # Maybe support full in 'verbose' mode (which is not yet implemented)?
	);
	if (ref($rotate_results) eq 'HASH') {
		return {
			result => 'ok',
			msg    => "#G{no invalid secrets detected.}",
		} if $rotate_results->{empty};
		return {
			result => 'error',
			fatal  => 1,
			msg    => "#r{could not successfully rotate secrets.}"
		} if $rotate_results->{error};
		return {
			result => 'abort',
			fatal  => 1,
			msg    => "#R{user aborted secret rotation.}"
		} if $rotate_results->{abort};
		return {
			result => 'warn',
			msg    => "#y{all secrets valid, but warnings were encountered.}"
		} if $rotate_results->{warn};
		return {
			result => 'ok',
			msg    => "#G{secrets successfully rotated.}"
		}
	}
	
	require Data::Dumper;
	bug(
		"#R{invalid return from rotate_secrets: %s}",
		Data::Dumper::Dumper($rotate_results)
	);
}

# }}}
# _check_release_overrides - check the release overrides {{{
sub _check_release_overrides {
	my ($self) = @_;
	$self->notify("checking for release overrides...");

	my @overrides = ();
	my @outdated = ();
	my $env_releases = $self->manifest_provider->partial_environment(subset=>'releases')->data;
	if (ref($env_releases) eq 'ARRAY' && scalar(@$env_releases)) {

		my $kit_releases = scalar(load_yaml(scalar(run(
			'spruce','merge',
			'--skip-eval','--go-patch','-m',
			'--cherry-pick', 'releases',
			map { $_ =~ m{^/} ? $_ : $self->kit->path($_)} $self->kit_files)))
		)->{releases} // [];

		# Step through each override sorted by release name
		for my $override (sort {$a->{name} cmp $b->{name}} @$env_releases) {
			my ($release) = grep {$_->{name} eq $override->{name}} @$kit_releases;
			push @overrides, [$override->{name}, $override->{version}, $release ? $release->{version} : undef]
				if !$release || $release->{version} ne $override->{version};
		}
	}
	if (!@overrides) {
		info("[[  - >>#G{No release overrides found}");
		return {
			state => 'ok',
			msg   => "no release overrides found",
		}
	}

	info "[[  #E{warning}>>#y{environment overrides the following releases:}";
	for my $override (@overrides) {
		my ($name, $env_version, $kit_version) = @$override;
		if ($kit_version) {
			info(
				"[[     %s#C{%s} #y{v%s} => #%s{v%s}",
				bullet('', '>>', indent => 0),
				$name, $kit_version,
				new_enough($env_version,$kit_version) ? 'G' : 'R', $env_version
			);
		} else {
			info(
				"[[    >>#C{%s} #G{v%s} added (not found in kit)",
				$name, $env_version
			);
		}
	}
	@outdated = grep {!new_enough($_->[1],$_->[2])} @overrides;
	return {
		state => @outdated ? 'outdated' : 'overridden',
		msg   => sprintf(
			"environment overrides %d releases, %d of which are outdated",
			scalar(@overrides), scalar(@outdated)
		),
	};
}

# }}}
# _check_stemcells - check the stemcells {{{
sub _check_stemcells {
	my ($self) = @_;

	if ($self->use_create_env) {
		$self->notify("#Y{create-env environment detected - skipping stemcell checks}"); # TODO: Move this out to caller for customization
		return {
			state => 'ok',
			msg   => "using create-env, no stemcell needed."
		};
	}

	$self->notify("running stemcell checks...");
	my @stemcell_status = $self->_get_stemcell_status(1);

	my (@missing, @alt) = ();
	for my $stemcell_info (@stemcell_status) {
		if ($stemcell_info->{found}) {
			my $wants_latest = $stemcell_info->{latest};
			my %details = $stemcell_info->{found}->%*;
			info(
				"[[%s>>Stemcell #C{%s} (%s/%s) %s%s",
				bullet('good', '', box => 1),
				$stemcell_info->{alias}, $details{os},
				$stemcell_info->{search_term},
				$wants_latest ? "#G{will use v$details{version}}" : '#G{present}',
				$self->cpi_enabled ? " for CPI #C{".$stemcell_info->{cpi}."}" : "",
			);

			# Warn if alternative stemcell is found
			if ($stemcell_info->{alt}) {
				info(
					"[[       #Y{Warning:} >>#C{v%s} would be used, but does not support the #m{%s} CPI",
					$stemcell_info->{version},
					$stemcell_info->{cpi} eq '<default>' ? 'default' : $stemcell_info->{cpi}
				);
				push @alt, $stemcell_info;
			}
			next;
		}

		# Deal with missing stemcells
		info(
			"[[%s>>Stemcell #C{%s} (%s/%s) %s%s#R{!}",
			bullet('bad', '', box => 1),
			$stemcell_info->{alias}, $stemcell_info->{os},
			$stemcell_info->{search_term},
			$stemcell_info->{latest} ? "#R{- no matching stemcells available}" : '#R{missing}',
			$self->cpi_enabled ? "#R{ for CPI }#ri{".$stemcell_info->{cpi}."}":"",
		);
		push(@missing, $stemcell_info);
	}

	if (@missing) {
		# Some stemcells are missing, while others have preferred alternatives
		my @unknown = grep {!defined($_->{alt})} @missing;
		return {
			state => 'error',
			fatal => 1,
			msg   => "required stemcells source unknown - requires manual upload:\n- #R{".join("\n- ", map {$_->{os}."@".$_->{search_term}} @unknown)."}",
		} if @unknown;
		
		return {
			state => 'error',
			msg   => "missing required or preferred stemcells",
			fix_data => {
				missing => \@missing,
				alt     => \@alt,
			}
		}
	} elsif (@alt) {
		# No stemcells missing, but there are preferred alternatives
		return {
			state => 'degraded',
			msg   => "missing preferred stemcells",
			fix_data => {
				missing => \@missing,
				alt     => \@alt,
			},
		}
	} else {
		return {
			state => 'ok',
			msg   => "all required stemcells are present and curent",
		}
	}
}

# }}}
# _fix_stemcells - fix the stemcells on the director {{{
sub _fix_stemcells {
	my ($self, $fix_data, %opts) = @_;

	unless ($fix_data) {
		bail("Cannot fix stemcells without a valid fix_data");
		# Todo: should this just call _check_stemcells() to get the fix_data if missing?
	}

	my ($missing, $alt) = $fix_data->@{qw/missing alt/};
	my @unknown = grep {!defined($_->{alt})} (@$missing, @$alt);
	bail (
		"Sorry, I don't know how to upload the following stemcells:\n%s",
		join("\n", map {"- $_->{os}\@$_->{search_term} for $_->{cpi} CPI"} @unknown)
	) if @unknown;

	# TODO: Honor noprompt
	my @selections = grep {$_} (
		@$missing,
		prompt_for_boolean(
			(scalar(@$alt) == 1 
				? "An alternative stemcell is available for the requested stemcell; upload it?" 
				: sprintf("Alternative stemcells are available for %d requested stemcells; upload them?", scalar(@$alt))
			),
			defined($opts{default}) ? $opts{default} : 1
		) ? @$alt : ()
	);

	unless (@selections) {
		return {
			result => 'ok',
			msg    => "no stemcells selected for upload"
		}
	}

	# Load required modules
	eval {
		require LWP::UserAgent;
		require HTTP::Request::Common;
		require File::Temp;
	};
	if ($@) {
		bail("Required Perl modules for stemcell operations are not available: $@");
	}

	my $agent = LWP::UserAgent->new();
	$agent->env_proxy();

	my $uploaded = 0;
	my $failed = 0;
	my $count = scalar(@selections);
	my $idx = 0;
	info(
		"\n[[  - >>uploading %d stemcell%s to #M{%s} director...",
		$count, $count == 1 ? '' : 's', $self->bosh->alias
	);

	for my $stemcell (@selections) {
		my $url = $stemcell->{alt}{url};
		$stemcell->{version} = $stemcell->{alt}{version};
		info {pending => 1}, "[[  %s>>[#%d/%d] #C{%s}...", bullet('',indent => 3), ++$idx, $count, $stemcell->{alias};

		my $request = HTTP::Request::Common::GET($url);
		my $stemcell_file = File::Temp->new();
		my $response = $agent->request($request, $stemcell_file->filename);

		if ($response->code == 200) {
			info({pending => 1}, "#G{downloaded}...#Ki{%s}...", pretty_bytes($response->header("Content-Length")));
			my ($out, $err, $rc) = $self->bosh->execute({passfail => 1}, 'upload-stemcell', $stemcell_file->filename);
			if ($rc) {
				info("#R{failed to upload}");
				$failed++;
			} else {
				info("#G{uploaded v%s}", $stemcell->{version});
				$uploaded++;
			}
		} else {
			info("#R{failed to download} - error %s", $response->code);
			$failed++;
		}
	}

	if ($failed) {
		return {
			result => 'error',
			msg    => sprintf("uploaded %d stemcell%s, but %d failed", $uploaded, $uploaded == 1 ? '' : 's', $failed)
		}
	}

	return {
		result => 'ok',
		msg    => sprintf("successfully uploaded %d stemcell%s", $uploaded, $uploaded == 1 ? '' : 's')
	}
}

# }}}
# _validate_reactions - validate reaction hooks are valid {{{
sub _validate_reactions {
	my @valid_reactions = qw/pre-deploy post-deploy/;
	my %reaction_validator; @reaction_validator{@valid_reactions} = ();
	my @invalid_reactions = grep ! exists $reaction_validator{$_}, ( $_[0]->_reactions );
	if (@invalid_reactions) {
		bail(
			"Unexpected reactions specified under #y{genesis.reactions}: #R{%s}\n".
			"Valid values: #G{%s}",
			join(', ', @invalid_reactions), join(', ',@valid_reactions)
		);
	}
	return;
}

# }}}
# _process_reactions - handle the specified environment reaction scripts {{{
sub _process_reactions {
	my ($self, $reaction, $reaction_vars) = @_;
	my $ok = 1;

	if ($self->lookup("genesis.reactions.$reaction")) {
		my %env_vars = $self->get_environment_variables('deploy');
		my $actions = $self->lookup("genesis.reactions.$reaction");
		info '';
		bail(
			"Value of #C{genesis.reactions.%s} must be a list of one or more hashmaps",
			$reaction
		) if ref($actions) ne "ARRAY" || scalar(@{$actions}) == 0;

		for my $action (@{$actions}) {
			bail(
				"Values in #C{genesis.reactions.i%s} list must be hashmaps",
				$reaction
			) if ref($action) ne "HASH";
			my @action_type = grep {my $i = $_; grep {$_ eq $i} qw/script addon/} keys(%{$action});
			bail(
				"Values in #C{genesis.reactions.%s} must have one #C{script} or #C{addon} key",
				$reaction
			) unless scalar(@action_type) == 1;
			my $script = $action->{$action_type[0]};
			if ($action_type[0] eq "script") {
				my @args = @{$action->{args}||[]};
				my @cmd = ('bin/'.$action->{script}, @args);
				info (
					"[#M{%s}/#c{%s}: #mi{%s}] Running script \`#G{%s}\` with %s:\n",
					$self->name, $self->type, uc($reaction), $cmd[0], (
						@args ? sprintf('arguments of [#C{%s}]', join(', ',map {"\"$_\""} @args)) : 'no arguments'
					)
				);
				my ($out, $rc) = run({
					onfailure  => 'Failed to execute reaction script.',
					env        => (%env_vars, %{$reaction_vars}),
					stderr     => "&1",
					noexec     => 1
				}, @cmd);
				unless ($rc == 0) {
					$ok = 0;
					error(
						"[#M{%s}/#c{%s}: #ri{%s}] Script `#R{%s}` exited %s\n",
						$self->name, $self->type, uc($reaction), $cmd[0], $rc
					);
				} else {
					info(
						"[#M{%s}/#c{%s}: #mi{%s}] Script `#G{%s}` completed successfully\n",
						$self->name, $self->type, uc($reaction), $cmd[0]
					);
				}
			} elsif ($action_type[0] eq "addon") {
				info (
					"[#M{%s}/#c{%s}: #mi{%s}] Running addon \`#G{%s}\`\n",
					$self->name, $self->type, uc($reaction), $action->{addon}
				);
				my ($rc, $out) = $self->run_hook('addon', script => $action->{addon});
				unless ($rc) {
					$ok = 0;
					error(
						"[#M{%s}/#c{%s}: #ri{%s}] Addon `#R{%s}` failed!\n",
						$self->name, $self->type, uc($reaction), $action->{addon}
					);
				} else {
					info(
						"[#M{%s}/#c{%s}: #mi{%s}] Addon `#G{%s}` completed successfully\n",
						$self->name, $self->type, uc($reaction), $action->{addon}
					);
				}
			}
		}
	}
	return $ok;
}

# }}}
# _reactions - get list of reactions {{{
sub _reactions {
	my ($self) = @_;
	return () unless $self->lookup('genesis.reactions');
	return (keys %{$self->lookup('genesis.reactions',{})})
}

# }}}

# }}}
# _advise_stemcell_updates - advise on available stemcell updates {{{
sub _advise_stemcell_updates {
	my ($self, $fix_data) = @_;
	unless ($fix_data) {
		bail("Cannot fix stemcells without a valid fix_data");
		# Todo: should this just call _check_stemcells() to get the fix_data if missing?
	}

	my ($missing, $alt) = $fix_data->@{qw/missing alt/};
	my @downloadable = grep {$_->{alt}} (@$missing, @$alt);

	my $msg = "\n#Y{The following stemcells are available for download:}";
	my @stemcell_ids = ();
	for my $stemcell_info (@downloadable) {
		my $required = $stemcell_info->{found} ? 0 : 1;
		$msg .= sprintf(
			"\n[[%s>>%s#C{%s} stemcell (%s/%s)",
			bullet(''),
			$required ? "#R{required} " : "#B{preferred} ",
			$stemcell_info->{alias}, $stemcell_info->{os},
			$stemcell_info->{alt}{version}
		);
		push @stemcell_ids, sprintf("%s@%s", $stemcell_info->{alt}{os}, $stemcell_info->{alt}{version});
	}

	my $cmd = Genesis::Commands->current_command;
	my $fix_opt = $cmd eq 'deploy'
		? '--fix-stemcells|--fix-checks|-F'
		: '';

	$msg .= "\n\nThese can be downloaded by running the following command:\n";
	$msg .= "[[  > >>#G{%s do upload-stemcells %s}";
	$msg .= (
		"\n\n#Yu{Note:} You can also use the #Y{%s} argument to the #G{%s} command ".
		"to automatically fetch and upload stemcells.\n\n"
	) if $fix_opt;

	info(
		$msg,
		join(' ', $self->get_call_path, '<parent-bosh-director-env>'),
		join(' ', map {"'$_'"} @stemcell_ids),
		$fix_opt ? ($fix_opt, $cmd) : (),
	);
}

# }}}
# _get_stemcell_status - get detailed stemcell status information {{{
sub _get_stemcell_status {
	# This will return an array of stemcell statuses (in the order given)
	# that will contain a hash of the following keys:
	#  - alias: the alias of the stemcell (specified in the manifest)
	#  - found: the stemcell that satisfies the request, or undef if not found
	#  - alt: the recommended stemcell to use if cpi not found
	#  - latest: true if searching for the latest.
	#  - cpi: the cpi name (or <default> if not specified)
	#  - search_type: exact, latest, or latest-minor
	#  - search_term: the stemcell version requested

	my ($self, $recalculate) = @_;

	$self->{__stemcell_status} = undef if $recalculate;
	return wantarray ? @{$self->{__stemcell_status}} : $self->{__stemcell_status}
		if defined $self->{__stemcell_status};

	my $stemcells_to_check = $self->partial_manifest_lookup('stemcells');
	my %available = $self->bosh->stemcells;
	my %newest_by_os = ();
	for my $key (reverse sort {by_semver($available{$a}{version}, $available{$b}{version})} keys %available) {
		my ($os, $version) = split('@', $key, 2);
		push @{$newest_by_os{$os}}, $key;
	}
	my $cpi = $self->cpi_enabled ? $self->cpi_name : '<default>';
	my @results = ();

	for my $stemcell_info (@$stemcells_to_check) {
		my ($alias, $os, $version) = @$stemcell_info{qw/alias os version/};
		$alias //= "stemcell-$os-$version";
		my $newest = $newest_by_os{$os}->[0];
		my $result = {alias => $alias, os => $os, search_term => $version, cpi => $cpi};
		my ($wants_latest,$major_version) = $version =~ /^((?:(\d+)\.)?latest)$/;

		# Finding "latest" stemcells is a bit tricky, because we need to
		# ballance latest known version vs latest available version for
		# the CPI.  We also support getting the latest minor version of a
		# major version, so we need to check for that too.

		# TODO:  Should latest check for latest available upstream, or just local (current behavior)?
		if ($wants_latest) {
			$result->{latest} = 1;
			$result->{search_type} = 'latest';
			my @targets = ($newest_by_os{$os}->@*);
			my $latest_major_version = int($available{$targets[0]}{version});
			if (defined($major_version) && $major_version != $latest_major_version) {
				$result->{search_type} = 'latest-minor';
				@targets = (
					grep {$major_version == int($available{$_}{version})}
					@targets
				);
			}
			# There exists one or more stemcells that match the desired latest version
			if (@targets) {
				# Check if the latest version is available for the desired CPI
				my @cpi_targets = grep {
					in_array($cpi, $available{$_}{cpis}->@*)
				} @targets;
				if (@cpi_targets) {
					$result->{found} = $available{$cpi_targets[0]};
				}
				if (!@cpi_targets || $cpi_targets[0] ne $targets[0]) {
					require Service::BOSH::Stemcell;
					$result->{alt} = Service::BOSH::Stemcell->find(
						$self->iaas, $available{$targets[0]}->@{qw/os version/},
						scalar($self->lookup('bosh-configs.stemcells.type',undef))
					);
					$result->{alt_existing_cpis} = $available{$targets[0]}->{cpis};
				}
			} else {
				# No stemcells available for the desired os
				require Service::BOSH::Stemcell;
				$result->{alt} = Service::BOSH::Stemcell->find(
					$os,
					$version
				);
				$result->{alt_existing_cpis} = $available{$newest}{cpis};
			}

				# If using a non-default CPI, check if the latest version is available for it

		} else {
			$result->{search_type} = 'exact';
			my $key = "$os\@$version";
			my $match = $available{$key};
			if (in_array($cpi, $match->{cpis}->@*)) {
				$result->{found} = $match;
			} else {
				$result->{alt} = Service::BOSH::Stemcell->find(
					$os,
					$version
				);
				$result->{alt_existing_cpis} = ($available{$key}//{})->{cpis};
			}
		}
		push @results, $result;
	}
	$self->{__stemcell_status} = \@results;
	return wantarray ? @results : \@results;
}

# }}}

1;

=head1 NAME

Genesis::Env::Validation

=head1 DESCRIPTION

This module handles validation and checking operations for Genesis environments,
including environment viability, secrets, releases, stemcells, and reactions.

=head1 METHODS

=head2 Private Methods

=head3 _check_environment_viability()

Checks that the environment is viable for deployment by running check hooks
and validating kit files.

=head3 _check_secrets()

Checks that all required secrets are present and valid.

=head3 _fix_secrets(%opts)

Attempts to fix invalid or missing secrets.

=head3 _check_release_overrides()

Checks for BOSH release overrides in the environment.

=head3 _check_stemcells()

Checks that all required stemcells are available on the BOSH director.

=head3 _fix_stemcells($fix_data, %opts)

Downloads and uploads missing or alternative stemcells.

=head3 _validate_reactions()

Validates that reaction hooks are properly configured.

=head3 _process_reactions($reaction, $reaction_vars)

Processes reaction scripts or addons for the given reaction type.

=head3 _reactions()

Returns the list of configured reactions for the environment.

=cut