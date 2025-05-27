package Genesis::Env::Deployment;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::UI;
use Archive::Tar;
use File::Path qw/mkpath rmtree/;
use JSON::PP qw/encode_json decode_json/;
use Digest::SHA qw/sha1_hex/;
use Digest::file qw/digest_file_hex/;
use Time::HiRes qw/gettimeofday/;
use Time::Piece;
use IO::Uncompress::Gunzip;
use MIME::Base64 qw/decode_base64/;

use constant {
	EXODUS_TIME_FORMAT => '%Y-%m-%d %H:%M:%S%z',
	EXODUS_TIME_FORMAT_SHORT => '%Y%m%d%H%M%S',
};

### Instance Methods {{{

# has_hook - check if the environment's kit has a specified hook {{{
sub has_hook {
	my $self = shift;
	return $self->kit->has_hook(@_);
}

# }}}
# run_hook - runs the specified hook in the environment's kit {{{
sub run_hook {
	my ($self, $hook, %opts) = @_;
	my @config_hooks = ($hook);
	push(@config_hooks, "addon-".$opts{script})
		if ($hook eq 'addon');

	$self->connect_required_endpoints(@config_hooks);
	$self->download_required_configs(@config_hooks);
	debug "Started run_hook '$hook'";
	return $self->kit->run_hook($hook, %opts, env => $self);
}

# }}}
# shell - provide a bash shell with the hook environment variables and helper functions available {{{
sub shell {
	my ($self, %opts) = @_;
	if ($opts{hook}) {
		my @config_hooks = ($opts{hook});

		if ($opts{hook} =~ /^addon-/) {
			$opts{hook_script} = $opts{hook};
			push(@config_hooks, "addon");
			$opts{hook} = "addon";
		}

		$self->connect_required_endpoints(@config_hooks);
		$self->download_required_configs(@config_hooks);
	}
	info "#Y{Started shell environment for }#C{%s}#Y{:}", $self->name;
	return $self->kit->run_hook('shell', %opts, env => $self);
}

# }}}

# Manifest Management
# manifest_provider - builder for making manifests in different ways {{{
sub manifest_provider {
	return $_[0]->_memoize(sub {
		Genesis::Env::ManifestProvider->new($_[0]);
	});
}

# }}}
# deployment_manifest_type - determine the type of manifest to deploy {{{
sub deployment_manifest_type {
	my ($self) = @_;

	my $entomb = $self->can_be_entombed;
	if ($self->is_vaultified && @{$self->manifest_provider->unevaluated->data->{variables}//[]}) {
		return $entomb ? 'vaultified_entombed' : 'vaultified';
	} else {
		return $entomb ? 'entombed' : 'unredacted';
	}
}

# }}}
# last_deployed_manifest - get the details of last deployed manifest {{{
sub last_deployed_manifest {
	my ($self, %opts) = @_;

	# Deployed manifest data is found in three places:
	# 1. In the environment's exodus data under the deployed/<timestamp>/ subpath
	#    under the nominal exodus mount path (ie /secret/exodus/<env>/<type>)
	#    It contains keys for manifest package, type, and sha1sum, as well as who
	#    deployed it.  The manifest package is a tarball, containing the
	#    manifest.yml and other support files, such as vars, state and store.
	#
	# 2. In the environment's exodus data at the nominal exodus mount path, under
	#    the keys 'manifest', 'manifest_type', 'manifest_sha1'. This is the
	#    most recent deployed manifest, implemented in v3.0.0, but being phased
	#    out in favor of the deployed/<timestamp> method.
	#
	# 3. In the .genesis/manifests/ directory in the deployment repository, under
	#    the name of the environment, with a .yml extension.  This is the legacy
	#    method, and will be phased out in favor of the vault method.
	#
	# If the manifest is found in the repo, but not in the vault, and the
	# deployment is not a create-env deployment, it will be assumed that this is
	# a old deployment or has been lost, and not returned.

	my $manifest_data = $self->_process_deployed_manifests($opts{at});
	return $manifest_data if defined($manifest_data->{not_found});

	# Convert data to the expected format
	my $data = {errors => [], manifest => {}, vars => {}, state => {}, store => {}};
	if ($manifest_data->{source} eq 'exodus-manifest' || $manifest_data->{source} eq 'exodus-deployments') {
		my %results = (
			manifest => {data => $manifest_data->{manifest_data},   found => 1, type => $manifest_data->{manifest_type}},
			vars     => {data => $manifest_data->{vars_data},       found => defined($manifest_data->{vars_data})},
			state    => {data => $manifest_data->{state_data},      found => defined($manifest_data->{state_data})},
			store    => {data => $manifest_data->{store_data},      found => defined($manifest_data->{store_data})}
		);
		$data->{manifest_sha1} = $manifest_data->{manifest_sha1};
		$data->{source} = $manifest_data->{source};
		if ($opts{contents}) {
			for (qw/manifest vars state store/) {
				$data->{$_} = $results{$_}
			}
		} elsif ($opts{files}) {
			for (qw/manifest vars state store/) {
				next unless $results{$_}{found};
				my $path = $self->workpath(sprintf(".genesis/cached/%s.%s", $_, {manifest => 'yml', vars => 'vars', state => 'json', store => 'yml'}->{$_}));
				mkpath(dirname($path));
				mkfile_or_fail($path, $results{$_}{data});
				$data->{$_} = {path => $path, source => 'exodus', found => 1};
			}
		}
	} elsif ($manifest_data->{source} eq 'repository') {
		my $rel_path = abs2rel($manifest_data->{manifest_path}, $self->top->path());
		$data->{manifest_sha1} = sha1_hex(slurp($manifest_data->{manifest_path}));
		$data->{source} = 'repository';
		if ($opts{contents}) {
			$data->{manifest} = {data => slurp($manifest_data->{manifest_path}), found => 1, type => 'unknown', path => $rel_path};
			$data->{vars}     = {found => 0};
		} elsif ($opts{files}) {
			$data->{manifest} = {path => $manifest_data->{manifest_path}, source => 'repository', found => 1};
			$data->{vars}     = {found => 0};
		}
		if ($self->use_create_env) {
			# Need to find the state file
			my $state_path = $manifest_data->{manifest_path};
			$state_path =~ s/.yml$/-state.yml/;
			if (-f $state_path) {
				if ($opts{contents}) {
					$data->{state} = {data => slurp($state_path), found => 1, path => $state_path};
				} elsif ($opts{files}) {
					$data->{state} = {path => $state_path, source => 'repository', found => 1};
				}
			} else {
				push @{$data->{errors}}, "State file not found in repository";
			}
			my $store_path = $manifest_data->{manifest_path};
			$store_path =~ s/.yml$/-store.yml/;
			if (-f $store_path) {
				if ($opts{contents}) {
					$data->{store} = {data => slurp($store_path), found => 1, path => $store_path};
				} elsif ($opts{files}) {
					$data->{store} = {path => $store_path, source => 'repository', found => 1};
				}
			}
		}
	}
	return $data;
}

# }}}
# deployment_cache_setup - set up the deployment cache directory {{{
sub deployment_cache_setup {
	my ($self, $preserve) = @_;
	# This won't survive post-process cleanup; maybe we should move it under
	# $self->top->path('.genesis/deploy-cache'), and clean that up post-deploy?
	my $deploy_cache = $self->workpath('deploy-cache');
	$self->deployment_cache_cleanup unless $preserve;
	mkdir_or_fail($deploy_cache) unless -d $deploy_cache;

	# TODO: This should be done more programatically:
	# - split by _
	# pop last item off as the type
	# join the rest (sorted alphabetically) with -
	# switch on type, build the path.
	$self->{__deployment_cache_files} = {
		manifest => $deploy_cache."/".$self->name.".yml",
		unpruned_manifest => $deploy_cache."/".$self->name."-unpruned.yml",
		redacted_manifest => $deploy_cache."/".$self->name."-redacted.yml",
		vars => $deploy_cache."/".$self->name.".vars",
		redacted_vars => $deploy_cache."/".$self->name."-redacted.vars",
		state => $deploy_cache."/".$self->name."-state.json",
		store => $deploy_cache."/".$self->name."-store.yml",
		deploy_log => $deploy_cache."/".$self->name."-output.log",
	};
}

# }}}
# deployment_cache_cleanup - remove the deployment cache {{{
sub deployment_cache_cleanup {
	my ($self) = @_;
	my $deploy_cache = $self->workpath('deploy-cache');
	if (-d $deploy_cache) {
		debug("cleaning up deployment cache...");
		rmtree($deploy_cache);
	}
}

# }}}
# deployment_cache_path_lookup - return the path to a file in the deployment cache {{{
sub deployment_cache_path_lookup {
	my ($self, $descriptor) = @_;
	bug(
		"No deployment cache file for descriptor '%s'", $descriptor // '<undef>'
	) unless $self->{__deployment_cache_files}{$descriptor};
	return $self->{__deployment_cache_files}{$descriptor};
}

# }}}
# deploy - deploy the environment {{{
sub deploy {
	my ($self, %opts) = @_;
	my $noprompt = delete(%opts{yes});

  $self->deployment_cache_setup;

	my $pruned_deploy_manifest = $self->manifest_provider->deployment(subset=>'pruned',notify=>1);
	my $unpruned_deploy_manifest = $self->manifest_provider->deployment(notify=>0);
	my $manifest_path = $self->deployment_cache_path_lookup('manifest');
	$pruned_deploy_manifest->write_to($manifest_path);
	my $unpruned_manifest_path = $self->deployment_cache_path_lookup('unpruned_manifest');
	$unpruned_deploy_manifest->write_to($unpruned_manifest_path);

	my ($ok, $predeploy_data,$data_fn) = ();
	my $vars_path = $self->vars_file(0, $self->deployment_cache_path_lookup('vars'));
	if ($self->has_hook('pre-deploy')) {
		($ok, $predeploy_data) = $self->run_hook(
			'pre-deploy',
			manifest  => $manifest_path,
			vars_file => $vars_path
		);
		bail "Cannot continue with deployment!\n" unless $ok;
		$data_fn = $self->workpath("predeploy-data");
		mkfile_or_fail($data_fn, $predeploy_data) if ($predeploy_data);
	}

	my $disable_reactions = delete($opts{'disable-reactions'});
	my $reaction_vars;

	if ($self->_reactions) {
		if ($disable_reactions) {
			warning("\nReactions are disabled for this deploy");
		} else {
			$self->_validate_reactions;
			$reaction_vars = {
				GENESIS_PREDEPLOY_DATAFILE => $data_fn,
				GENESIS_MANIFEST_FILE => $unpruned_manifest_path,
				GENESIS_BOSHVARS_FILE => $vars_path,
				GENESIS_DEPLOY_OPTIONS => JSON::PP::encode_json(\%opts),
				GENESIS_DEPLOY_DRYRUN => $opts{"dry-run"} ? "true" : "false"
			};
			$ok = $self->_process_reactions('pre-deploy', $reaction_vars);
			bail(
				"Cannnot deploy: environment pre-deploy reaction failed!"
			) unless $ok;
		}
	}

	# TODO: Need to implement a cache for capturing the state of the repository
	#       at the moment of deployment, so that if the deployment gets
	#       interrupted, we can detect it, figure out if the deployment is in
	#       progress or completed successfully, and resume it.
	#
	#       This should capture not only the manifest and vars files, but also
	#       the state and store files if using a create-env deployment, as well
	#       as a diff of any dev kits in reference to the version the dev kit was
	#       initiated with.
	#
	#       Ideally, this will be a tarball that is encrypted, with the ecryption
	#       key stored in the vault, and the tarball stored in the deploy-cache.
	#
	#       For now, we will just capture the required files in the deploy-cache
	#       directory, so they can be moved to the appropriate location when the
	#       deployment is complete, and then delete the deploy-cache directory,
	#       replacing the earlier temporary `workpath` directory.
	#
	#       Alternative: we can stuff manifest and vars into a temporary vault
	#       location, and then retrieve them when the deployment is complete.
	#       The state should not have any secrets in it, so it can live in the
	#       file system. The store file is the only problematic one, as it may
	#       contain secrets, but those secrets are generated real-time during
	#       the deployment, so can't be preemptively stored in the vault.

	my $cached_manifest_path = $manifest_path;
	my $cached_vars_path = $vars_path;
	my $cached_unpruned_manifest_path = $self->deployment_cache_path_lookup('unpruned_manifest');
	my $cached_redacted_manifest_path = $self->deployment_cache_path_lookup('redacted_manifest');
	my $cached_redacted_vars_path = $self->deployment_cache_path_lookup('redacted_vars');
	$self->manifest_provider->deployment->redacted->write_to($cached_redacted_manifest_path);
	$self->vars_file('redacted', $cached_redacted_vars_path);

	# Only used by create-env deployments, but need to reference them if they
	# exist when caching the results.
	my $state_path = $self->deployment_cache_path_lookup('state');
	my $store_path = $self->deployment_cache_path_lookup('store');

	# DEPLOY!!!
	$self->notify("all systems #G{ok}, initiating BOSH deploy...");

	my @results;
	my $deploy_started;
	if ($self->use_create_env) {
		# Todo: Show spruce diff of the manifest in non-create-env deployments too
		# Check for differences between the last deployed manifest and the current one
		debug("deploying this environment via `bosh create-env`, locally");
		my $last_manifest = $self->last_deployed_manifest(files => 1, contents => 0);

		my $local_mismatch = 0;
		my ($last_manifest_path, $last_manifest_sha1);
		unless ($last_manifest->{not_found}) {
			if ($last_manifest->{errors}) {
				bail("Errors encountered while retrieving last deployed manifest: %s",
					join("\n", @{$last_manifest->{errors}})
				);
			}
			$last_manifest_path = ($last_manifest->{manifest}{path});
			$last_manifest_sha1 = $last_manifest->{manifest_sha1};
		}

		if ($last_manifest_path && ($last_manifest->{source}||'') ne 'exodus-deployments') {
			# Legacy method of storing state files, and possibly manifests
			my $last_state_path = $last_manifest->{state}{path};
			my $last_manifest_repo_path = $last_state_path =~ s/-state\.yml$/.yml/r; # FIXME: This seems sus... but it seems to work for now.
			my $last_repo_sha1 = sha1_hex(slurp($last_manifest_repo_path));
			my $issue = '';

			# FIXME: exodus deployments use sha2, not sha1, so this check is not valid for them
			if (!defined($last_manifest_sha1) || $last_manifest_sha1 eq '') {
				$issue = "Cannot confirm local cached deployment manifest pertains to ".
				         "the current deployment (sha1 sum missing from exodus data).";
			} elsif ($last_repo_sha1 ne $last_manifest_sha1) {
				$issue = "Manifest in the deployment archive does not match the manifest in the ".
				         "local repository; perhaps you need to perform a #C{git pull}.  #y{Differences ".
				         "will not be accurate for this deployment compared to what was last deployed.}";
			}
			if ($issue) {
				$issue .= "  #R{This may mean your state file is also out of date!}";
				if (in_controlling_terminal || !$noprompt) {
					warning("\n".$issue);
					prompt_for_boolean(
						"Proceed with BOSH create-env for the #C{${\($self->name)}} anyways? [y|n] ",
						0
					) or bail "Aborted!\n";
					$self->notify("\ncomparing against the last deployed manifest...");
				} else {
					bail(
						"$issue\n\nRefusing to deploy to protect integrity of the environment."
					);
				}
			}
		}

		if ($last_manifest_path) {
			bail(
				"Cannot find state file for previous deployment; cannot proceed with create-env."
			) unless $last_manifest->{state}{path};

			# FIXME: These checks seem redundant to the above "non-exodus" checks --
			#        they should be universal.  Find out why the deviation and unify
			#        if possible
			if ($last_manifest->{manifest}{source} eq 'repository' && !defined($last_manifest->{manifest_sha1})) {
				debug(
					"Local deployment manifest is from a previous version of Genesis - cannot ".
					"confirm that it is correct (no sha1 in exodus); assuming local file is valid"
				);
			} elsif (defined($last_manifest->{manifest_sha1}) && $last_manifest->{manifest_sha1} ne '') {
				my $manifest_sha1 = sha1_hex(slurp($last_manifest_path));
				if ($last_manifest->{manifest_sha1} ne $manifest_sha1) {
					info(
						"Deployed manifest in repository (%s) does not match the sha1 ".
						"recorded in exodus (%s); fetching it from vault.",
						$manifest_sha1, $last_manifest->{manifest_sha1}
					);
					# The manifest in the repo doesn't match the exodus record, so we need to get it from the vault
					my $m = $self->last_deployed_manifest(files => 1, contents => 0, at => '.');
					$last_manifest_path = $m->{manifest}{path};
					bail(
						"Cannot retrieve previously deployed manifest from vault."
					) unless $m->{manifest}{found} && $last_manifest_path;
				}
			}

			my ($diff,$diff_rc) = run(
				{stderr => "&1"},
				"spruce diff '$last_manifest_path' '$manifest_path'"
			);
			if ($diff_rc) {
				bail("Failed to diff the manifests - cannot continue with deployment.\n$diff\n");
			}

			# Check if there are any differences
			if ($diff) {
				my @file_list = ("./".abs2rel($manifest_path,$self->path));
				push(@file_list, "./".abs2rel($last_manifest_path,$self->path))
					if index($last_manifest_path,$self->path) == 0;
				pushd $self->path;
				info("\n");
				run({ onfailure => "Failed to show differences between last deployed manifest and current manifest:\n" },
					'git', 'diff', '--no-index', '--exit-code', '--color=always', @file_list);
				popd;
				info("\n");
			} else {
				info("No differences found between last deployed manifest and current manifest.");
			}
		}

		# Copy state file from last deployment
		if ($last_manifest->{state}{path}) {
			copy_or_fail($last_manifest->{state}{path}, $state_path);
		} else {
			# No previous state file; create an empty one.
			mkfile_or_fail($state_path, '{}');
		}

		# TODO: Ideally we would remove the 'interactive => !$opts{"dry-run"}' for `bosh create-env`
		#       if we can get it to honor the BOSH_NON_INTERACTIVE env var, or --non-interactive flag.
		$deploy_started = time();
		my $bosh_opts = {
			interactive => !$opts{"dry-run"},
			tty => 1,
			stderr => "&1",
			logfile => $self->deployment_cache_path_lookup('deploy_log')
		};
		if ($opts{"dry-run"}) {
			# FIXME: dry-run mode doesn't work for create-env deployments if they
			# require sudo (usually just aws); we need to handle the output on expect
			# by supplying the sudo password when asked (available, but no current
			# expect function).  For now, we'll just display an error and skip the
			# dry-run.
			@results = run($bosh_opts,
				'bosh', 'create-env', '--dry-run', $manifest_path,
				'--state', $state_path,
				'--vars-file', $vars_path
			);
		} else {
			@results = run($bosh_opts,
				'bosh', 'create-env', $manifest_path,
				'--state', $state_path,
				'--vars-store', $store_path,
				'--vars-file', $vars_path
			);
		}
	} else {
		# Use BOSH director to deploy
		debug("deploying this environment to our BOSH director");
		# TODO: Set $deploy_started to record the time of the deployment
		$deploy_started = time();
		@results = $self->bosh->deploy(
			$manifest_path,
			vars_file => $vars_path,
			%opts
		);
	}

	# Check for errors in deployment
	my ($out,$rc,$err) = @results;
	if ($rc) {
		$out ||= '';
		$err ||= '';
		my @err = ();
		push @err, "STDOUT:",$out if $out;
		push @err, "STDERR:",$err if $err;

		# FIXME: Reactions should be able to intercept a failed deployment
		error(
			"Failed to deploy #C{%s}:\nExit Code: %s\n%s",
			$self->name, $rc, join("\n", @err)
		);
		return $rc;
	}

	# Process the deployment results
	if ($self->use_create_env) {
		# Upload the director's CA certificate to the vault
		my $director_configs = $self->deployment_manifest(redact => 0);
		$director_configs = $director_configs->{jobs}[0]{properties};
		if ($director_configs->{director}{ssl}{cert}) {
			my $ca_path = sprintf("%s/ca", $self->exodus_base);
			unless ($opts{'dry-run'}) {
				$self->vault->query({
					'$GENESIS_EXODUS_MOUNT/'.$ca_path  => $director_configs->{director}{ssl}{cert}
				});
			}
		}
	}

	# Handle post-deployment tasks
	if ($opts{'dry-run'}) {
		info("\n#M{%s}/#c{%s} #G{anticipated to be}%s #G{successful.}\n", $self->name, $self->type, $opts{redeploy} ? " #G{re-deployed}" : "");
		$self->deployment_cache_cleanup;
		return 0;
	}

	# Success!
	info("\n");
	$self->notify(success => "#M{%s}/#c{%s} %s", $self->name, $self->type, success("deployed successfully."));

	# Handle post-deploy hook
	if ($self->has_hook('post-deploy')) {
		($ok, undef) = $self->run_hook(
			'post-deploy',
			manifest  => $cached_manifest_path,
			vars_file => $cached_vars_path
		);
		bail "Cannot continue with deployment!\n" unless $ok;
	}

	# Handle post-deploy reactions
	if ($self->_reactions && !$disable_reactions) {
		$ok = $self->_process_reactions('post-deploy', $reaction_vars);
		error(
			"Environment post-deploy reaction failed!"
		) unless $ok;
	}

	# Store deployment information
	my $deploy_info = {
		manifest        => $cached_manifest_path,
		redacted        => $cached_redacted_manifest_path,
		vars            => $cached_vars_path,
		redacted_vars   => $cached_redacted_vars_path,
		state           => (-f $state_path ? $state_path : undef),
		store           => (-f $store_path ? $store_path : undef),
		deploy_started  => $deploy_started,
		deploy_log      => $self->deployment_cache_path_lookup('deploy_log')
	};

	# Extract exodus data
	if ($opts{'skip-releases-check'}) {
		$self->extract_manifest_exodus($cached_manifest_path);
	} else {
		$self->extract_manifest_exodus($cached_unpruned_manifest_path || $cached_manifest_path);
	}

	# Store deployment to vault
	$self->_store_deployment_to_vault($deploy_info) unless $opts{'dry-run'};

	# Clean up
	$self->deployment_cache_cleanup;

	return 0;
}

# }}}
# extract_manifest_exodus - extract and store exodus data from manifest {{{
sub extract_manifest_exodus {
	my ($self, $manifest_path) = @_;

	# Get the manifest data
	my $manifest_data = eval { load_yaml_file($manifest_path) };
	bail("Failed to parse manifest: $@") if $@;

	# Extract exodus properties
	my $exodus = {};
	for my $job (@{$manifest_data->{instance_groups} || []}) {
		for my $job_spec (@{$job->{jobs} || []}) {
			if ($job_spec->{properties} && $job_spec->{properties}{exodus}) {
				$exodus = deep_merge($exodus, $job_spec->{properties}{exodus});
			}
		}
	}

	# Store exodus data
	if (keys %$exodus) {
		debug("Storing exodus data to vault");
		$self->vault->query({
			map { '$GENESIS_EXODUS_MOUNT/'.$self->exodus_base.'/'.$_ => $exodus->{$_} } keys %$exodus
		});
	}

	return $exodus;
}

# }}}
# notify - send a notification about the environment {{{
sub notify {
	my $self = shift;
	my ($target, $prefix,$postfix) = $_[0] =~ /^(error|warning|fatal|success)$/
		? (shift,"","")
		: ("info","[","]");
	my $opts = ref($_[0]) eq 'HASH' ? shift : {};
	my $msg = shift;
	bug(
		"Invalid message argument to '%s' - expected a string, got undefined value: [%s]",
		$msg,
		join(", ", map {$_//'<undef>'} @_)
	) if grep {!defined} (@_);
	$msg = sprintf($msg, @_) if scalar(@_);

	# Check for custom prefix
	if (ref($self->{notify_prefix_overrides}) eq 'HASH' && defined $self->{notify_prefix_overrides}{$msg}) {
		$prefix = delete($self->{notify_prefix_overrides}{$msg});
		return $self->can($target)->($opts, "%s%s", $prefix, $msg);
	}

	$self->can($target)->($opts, "\n%s#M{%s}/#c{%s}%s %s", $prefix, $self->name, $self->type, $postfix, $msg);
}

# }}}
# add_secrets - add secrets to the environment {{{
sub add_secrets {
	my ($self, %opts) = @_;

	$self->manifest_provider->kit_files(); #process blueprint
	my $plan = $self->secrets_plan(%opts);

	unless ($plan->secrets) {
		if ($plan->filters) {
			info("\nNo applicable secrets found - no need to continue.\n");
		} else {
			$self->notify(success => "doesn't have any secrets to add.\n");
		}
		return ({empty => 1});
	}

	kit_bug(
		"Kits with secrets hook are no longer supported. Check for an upgraded version."
	) if ($self->has_hook('secrets'));

	return $plan->generate_secrets(
		import    => $opts{import},
		level     => $opts{verbose}?'full':'line'
	);
}

# }}}
# check_secrets - check that the environment has no missing or invalid secrets {{{
sub check_secrets {
	my ($self,%opts) = @_;
	my ($action,$action_desc) = delete($opts{validate})
		? ('validate_secrets','validated')
		: ('check_secrets', 'checked');

	$self->manifest_provider->kit_files(); #process blueprint
	my $plan = $self->secrets_plan(%opts);

	unless ($plan->secrets) {
		my $msg = ($plan->filters)
			? "No applicable secrets found"
			: undef;
		return ({empty => 1}, $msg);
	}

	kit_bug(
		"Kits with secrets hook are no longer supported. Check for an upgraded version."
	) if ($self->has_hook('secrets'));

	return $plan->$action(
		level => $opts{verbose}?'full':'line',
	);
}

# }}}
# rotate_secrets - generate new secrets for the environment {{{
sub rotate_secrets {
	my ($self, %opts) = @_;

	$self->manifest_provider->kit_files(); #process blueprint
	my $plan = $self->secrets_plan(%opts);

	unless ($plan->secrets) {
		if ($plan->filters) {
			info("\nNo applicable secrets found - no need to continue.\n");
		} else {
			$self->notify(success => "doesn't have any secrets to rotate.\n");
		}
		exit 0;
	}

	kit_bug(
		"Kits with secrets hook are no longer supported. Check for an upgraded version."
	) if ($self->has_hook('secrets'));

	my %regen_opts = (
		regen_x509_keys => $opts{'regen-x509-keys'},
		update_subject  => $opts{'update-subjects'},
		no_prompt       => $opts{'no-prompt'},
		verbose         => $opts{verbose},
	);

	return $plan->regenerate_secrets(%regen_opts);
}

# }}}
# check - run environment viability checks {{{
sub check {
	# TODO: should be moved to Genesis::Commands::Env::check
	my ($self,%opts) = @_;

	# FIXME: Check CPI exists if custom cpi is in use (not create-env)

	# FIXME: Check if cloud config exists if cloud-config hook exists (not create-env) 

	my $ok = 1;
	my $env_check = $self->_check_environment_viability();
	bail("%s", $env_check->{message}) if $env_check->{fatal};
	$ok = 0 unless $env_check->{status} eq 'ok';
	my $kit_files = $env_check->{kit_files};

	# TODO: Detect 'fix-secrets' option and run it against invalid or missing secrets, then run the check
	if (!exists($opts{check_secrets}) || $opts{check_secrets}) {
		my $secrets_check = $self->_check_secrets();
		my $msg_type = $secrets_check->{status};
		$msg_type = '%s' if $msg_type eq 'ok';

		$self->notify($msg_type => $secrets_check->{msg});
		$ok = 0 unless $secrets_check->{status} =~ /^(ok|warning)$/;
	}

	if ($opts{check_yamls}) {
		if ($self->missing_required_configs('blueprint')) {
			$self->notify("#Y{Required BOSH configs not provided - can't check manifest viability}");
		} else {
			$self->notify("inspecting YAML files used to build manifest...");
			my @yaml_files = $self->format_yaml_files('include-kit' => 1, padding => '  ', kit_files => $kit_files);
			info join("\n",@yaml_files)."\n";
		}
	}

	if ($ok) {
		if ($self->missing_required_configs('manifest')) {
			$self->notify("#Y{Required BOSH configs not provided - can't check manifest viability}");
		} elsif (!exists($opts{check_manifest}) || $opts{check_manifest}) {
			$self->notify("running manifest viability checks...");
			$self->manifest_provider->unredacted->validate or $ok = 0;
		}
	}

	# Check for release overrides in the environment file.
	if (!exists($opts{check_releases}) || $opts{check_releases}) {
		my $release_override_check = $self->check_release_overrides();
		# Really nothing to do here, just check the status
	}

	# TODO: secrets check for Credhub (post manifest generation)
if ((!exists($opts{check_stemcells}) || $opts{check_stemcells}) && !$self->use_create_env) {
		my $stemcells_check = $self->_check_stemcells();
		my $msg_type = $stemcells_check->{status};
		$msg_type = '%s' if $msg_type eq 'ok';

		$self->notify($msg_type => $stemcells_check->{msg});
		$self->_advise_stemcell_updates($stemcells_check->{fix_data}) unless $stemcells_check->{status} eq 'ok';
		$ok = 0 unless $stemcells_check->{status} =~ /^(ok|warning)$/;
	}
	return $ok;
}

# }}}
# get_next_deployment_sequence_number - get the next deployment sequence number {{{
sub get_next_deployment_sequence_number {
	my ($self) = @_;

	my $old_exodus = $self->exodus_lookup(".",{});
	my $sequence = $old_exodus->{sequence};
	return $sequence + 1 if defined($sequence);

	# If sequence is not found, then an older version of Genesis was used and we
	# need to figure out if we need to backfill the deployment audit data

	# If the manifest store is the repository, then we can't backfill the
	# deployment audit data because that isn't supported, so just assume 1;
	return 1 if ($self->manifest_store eq 'repository');

	# If there were no deployment audits, then we can start at 1
	my $last_deployment = $self->deployment_lookup('latest');
	return 1 unless $last_deployment;

	# If the last deployment was terminated, then we can start at one more than
	# the termination sequence number
	return $last_deployment->{sequence} + 1
		if ($last_deployment->{state}//'deployed') eq 'terminated'
		&& defined($last_deployment->{sequence});

	# If the last deployment was not terminated, then we need to backfill the
	# deployment audit data to ensure that the sequence numbers are correct
	$last_deployment = $self->_backfill_deployment_audit_data(
		$old_exodus, $last_deployment
	);
	return $last_deployment->{sequence} + 1;
}

# }}}
# update_deployment_exodus - update the exodus data in the vault {{{
sub update_deployment_exodus {
	my ($self, $state, %deployment_details) = @_;

	# FIXME: Support failed deployments and terminations
	# - leave the current base exodus data as-is, but update the
	#   deployment audit data with the new state and details

	# TBD: The state currently captures the state of the environment, not the last
	#      action performed on it.  This should be updated to reflect the last
	#      action performed instead.  However, how do we capture the state of
	#      the environment after the last action?  One way is to pass in the
	#      $state as a hashref of {action => $result}, and then add the action
	#      and result as fields to the audit data, leaving the state as-is unless
	#      the result is 'success', in which case the state is updated to the action.
	#
	#      When reading the previous audit logs that don't have action and result,
	#      we can assume the action is the listed state, and the result is
	#      'success'.
	#
	#      Should this be refactored to separate out as _create_deployment_audit_log? (Y)
	#
	#      UPDATE: This may hae been implemented, but need to check it against all
	#              the expectations above

	# Authenticate to the vault
	$self->vault->authenticate unless $self->vault->authenticated;

	my $exodus_overrides = delete($deployment_details{exodus_overrides}) // {};

	# Get the completed timestamp from overrides, or use the current time
	my $timestamp = $deployment_details{completed} || Time::Piece->new->strftime(EXODUS_TIME_FORMAT);

	# Determine the sequence number
	my $sequence = $self->get_next_deployment_sequence_number();

	# Build the base exodus data (manifest data and legacy deployment data)
	my $exodus = {};
	my @exodus_cmds = ();
	if ($sequence > 1 && $self->vault->has($self->exodus_base)) {
		push @exodus_cmds, ('rm', $self->exodus_base, "-f");
	}

	my $notify = !delete($deployment_details{quiet});
	my $started = gettimeofday;
	info({pending => 1},
		"[[  - >>storing %s metadata in exodus...",
		$state eq 'deployed' ? 'deployment' : 'termination'
	) if $notify;

	if ($state eq 'deployed') {
		# Manifest info
		if ($deployment_details{manifest}) {
			my $manifest = $deployment_details{manifest};
			$exodus->{manifest} = slurp($manifest->{path});
			$exodus->{manifest_type} = $manifest->{type};
			$exodus->{manifest_sha1} = $manifest->{sha1};
		} else {
			# Legacy kit support:
			my $unredacted = $self->manifest_provider->deployment();
			$exodus->{manifest} = $unredacted->to_string();
			$exodus->{manifest_type} = $self->deployment_manifest_type();
			$exodus->{manifest_sha1} = sha1_hex($exodus->{manifest});
		}

		# BOSH configuration
		$exodus->{bosh} = $self->bosh->exodus;
		$exodus->{bosh_deployment_date} = $timestamp;
		$exodus->{bosh_deployment_type} = $self->type;
		$exodus->{bosh_deployment_version} = $Genesis::VERSION;

		# Deployment sequence (NEW!)
		$exodus->{sequence} = $sequence;
	}

	# Merge in provided overrides
	$exodus = $self->_merge_exodus_overrides($exodus, $exodus_overrides);

	# Store to vault
	if (@exodus_cmds) {
		$self->vault->query({}, @exodus_cmds);
	}
	push @exodus_cmds, (
		'set', $self->exodus_base,
		map {$_ => encode_json($exodus->{$_})} (sort keys %$exodus)
	);

	my @errors = $self->vault->query({all => 1}, @exodus_cmds);
	if (@errors) {
		# Handle errors
		warning(
			"Failed to save all the metadata from the deployment of '#M{%s}' to Exodus.\n".
			"Environment was still successfully %s, but metadata used by addons and ".
			"other kits is outdated.\n%s",
			$self->{name},
			join("\n[[  - >>", '', @errors),
			$state,
			$state eq 'deployed'
				? "\nThis may be resolved by deploying again, or it may be a permissions issue while trying to ".
					"write to vault path '".$self->exodus_base."'\n"
				: '\nThis may be resolved by terminating again, or it may be a permissions issue while trying to '.
					"write to vault path '".$self->exodus_base."'\n"
		);
	}

	# Reset the last deployed manifest
	$self->_reset_last_deployed_manifest;
	info(" #G{done.}%s", pretty_duration(gettimeofday - $started)) if $notify;
	return 1;
}

# }}}

# }}}

### Private Instance Methods {{{

# _unpack_deployment_artifacts - unpack the deployment artifacts tarball {{{
sub _unpack_deployment_artifacts {
	my ($self, $artifacts_data) = @_;

	my $tar = Archive::Tar->new;
	my $compressed_data = decode_base64($artifacts_data);
	$tar->read(IO::Uncompress::Gunzip->new(\$compressed_data))
		or bail("Failed to decompress manifest artifacts");

	# Extract the files from the tarball
	my $contents = {};
	for my $file ($tar->list_files) {
		my $data = $tar->get_content($file);
		if ($file eq 'secrets.json') {
			$contents->{secrets} = decode_json($data);
		} else {
			$contents->{$file} = $data;
		}
	}

	return $contents;
}

# }}}
# _backfill_deployment_audit_data - backfill deployment audit data for legacy deployments {{{
sub _backfill_deployment_audit_data {
	my ($self, $old_exodus, $last_deployment) = @_;

	# Get last deployments sequence number
	$last_deployment //= $self->deployment_lookup('latest') // {};
	bug{
		"last_deployment is not a hashref: %s",
		$last_deployment
	} unless ref($last_deployment) eq 'HASH';

	return undef unless keys %$last_deployment || keys %$old_exodus; # no prior deployments
	my $sequence = (
		$last_deployment->{sequence} //
		scalar(keys $self->exodus_lookup('/deployments', {})->%*)
	) + 1;

	# Case 1: We have no data in exodus, so it must have been terminated
	if (!keys %$old_exodus) {
		return $last_deployment if $last_deployment->{state} eq 'terminated';

		# Create an artificial termination date halfway between the last
		# deployment and now
		my $now = Time::Piece->new;
		my $termination_time = Time::Piece->strptime(
			$last_deployment->{completed} || $last_deployment->{dated} || $now->strftime(EXODUS_TIME_FORMAT),
			EXODUS_TIME_FORMAT
		);
		my $termination_ts = $termination_time + ($now - $termination_time) / 2;
		$termination_ts = $termination_ts->strftime(EXODUS_TIME_FORMAT_SHORT);

		my $placeholder = {
			state => 'terminated',
			started => $termination_time->strftime(EXODUS_TIME_FORMAT),
			completed => $now->strftime(EXODUS_TIME_FORMAT),
			sequence => $sequence,
			reason => 'Terminated via unknown means after last recorded deployment (time unknown)',
		};
		$self->vault->set_path($self->exodus_base."/deployments/$termination_ts", $placeholder, flatten => 1);

	# Case 2: We have data in exodus, but no sequence number, so we need to
	# backfill the deployment audit data
	} else {

		# Sanity check: if exodus has a sequence number, then we don't need to
		# backfill the deployment audit data
		if (defined($old_exodus->{sequence})) {
			return $last_deployment if $old_exodus->{sequence} == $last_deployment->{sequence};
			bail(
				"Sequence number in exodus (%s) does not match the last deployment sequence number (%s) - contact support",
				$old_exodus->{sequence}, $last_deployment->{sequence}
			);
		};

		my $deployment_time = Time::Piece->strptime($old_exodus->{dated}, EXODUS_TIME_FORMAT);
		my $deployment_ts = $deployment_time->strftime(EXODUS_TIME_FORMAT_SHORT);
		my $last_deployment_ts = $last_deployment->{timestamp};
		my $genesis_version = $old_exodus->{version}//'(unknown version)';
		my $reason = $old_exodus->{reason}//'Unknown reason';
		my $deployment_data = $self->_build_deployment_audit_data(
			'deploy', 'success', $sequence,
			$deployment_time->strftime(EXODUS_TIME_FORMAT),
			kit => {
				name => $old_exodus->{kit_name},
				version => $old_exodus->{kit_version},
				is_dev => $old_exodus->{kit_is_dev} ? JSON::PP::true : JSON::PP->false,
				features => $old_exodus->{features},
			},
			user => {
				shell => $old_exodus->{deployer},
				vault => 'unknown',
				git => 'unknown',
				concourse => 'unknown',
			},
			manifest => {
				storage => 'repository',
				type => $old_exodus->{manifest_type},
				sha1 => $old_exodus->{manifest_sha1},
			},
			reason => $reason,
			genesis_version => $genesis_version,
		);
		$self->vault->set_path(
			$self->exodus_base."/deployments/$deployment_ts",
			$deployment_data,
			flatten => 1
		);

		# Update exodus with the new sequence number
		$self->vault->set($self->exodus_base, "sequence", $sequence);
	}
	return $self->deployment_lookup('latest');
}

# }}}
# _create_deployment_audit_log - create deployment audit log entry {{{
sub _create_deployment_audit_log {
	my ($self, $action, $result, %audit_data) = @_;
	my $bails_with = delete($audit_data{bails_with});
	$bails_with = ['%s', $bails_with] if $bails_with && ref($bails_with) ne 'ARRAY';
	my $returns = delete($audit_data{returns});

	my $timestamp = $audit_data{completed} || Time::Piece->new->strftime(EXODUS_TIME_FORMAT);
	my $deployment_time = $timestamp =~ s/\+.*$//r =~ s/[^0-9]//gr; # YYYYMMDDHHMMSS

	my $artifact_file = $self->workpath("artifacts-$deployment_time.tar.gz");
	# TODO: Support untarred version of the artifacts
	if ($action eq 'deploy') {
		$self->_build_deployment_artifacts(
			$artifact_file,
			log      => $self->deployment_cache_path_lookup('deploy_log'),
			manifest => $self->deployment_cache_path_lookup('manifest'),
			unpruned => $self->deployment_cache_path_lookup('unpruned_manifest'),
			vars     => $self->deployment_cache_path_lookup('vars'),
			state    => $self->deployment_cache_path_lookup('state'),
			store    => $self->deployment_cache_path_lookup('store'),
			secrets  => [keys($self->manifest_provider->vault_paths(notify => 0)->%*)],
			# TODO: add the dev kit, the ops directory and the env and its ancestors.
		);
		$audit_data{manifest} = {
			type => $self->manifest_provider->deployment->type,
			sha2 => digest_file_hex(
				$self->deployment_cache_path_lookup('manifest'), 'SHA-256'
			),
		};
	} elsif ($action eq 'terminate') {
		$self->_build_deployment_artifacts(
			$artifact_file,
			log      => $self->deployment_cache_path_lookup('deploy_log'),
			# manifest => $self->deployment_cache_path_lookup('manifest'),
			# unpruned => $self->deployment_cache_path_lookup('unpruned_manifest'),
			# vars     => $self->deployment_cache_path_lookup('vars'),
			# state    => $self->deployment_cache_path_lookup('state'),
			# store    => $self->deployment_cache_path_lookup('store'),
			# secrets  => [keys($self->manifest_provider->vault_paths(notify => 0)->%*)],
		);
	} else {
		bail("Invalid action: %s", $action);
	}

	my $sequence = delete($audit_data{sequence}) // $self->get_next_deployment_sequence_number();
	my $deployment_data = $self->_build_deployment_audit_data(
		$action, $result, $sequence, $timestamp, 'flatten',
		%audit_data,
	);

	# Add the deployment audit data to the exodus commands
	my @exodus_cmds = ();
	push @exodus_cmds, (
		'set', $self->exodus_base."/deployments/$deployment_time",
		'__flattened__=1',
		map {
			"$_=$deployment_data->{$_}"
		} keys %$deployment_data
	);
	push(
		@exodus_cmds, "artifacts\@$artifact_file"
	) if -f $artifact_file;

	my ($out, $rc, $err) = $self->vault->authenticate->query(
		{ redact => 1 },
		@exodus_cmds
	);
	if ($rc) {
		bail(
			"Failed to set deployment audit data in exodus: %s\n%s",
			$out, $err
		);
	}

	bail(@$bails_with) if $bails_with;
	return $returns
		? (ref($returns) eq 'CODE' ? $returns->($self, $out, $rc, $err) : $returns)
		: 1;
}

# }}}
# _store_deployment_to_vault - store deployment artifacts to vault {{{
sub _store_deployment_to_vault {
	my ($self, $deploy_info) = @_;

	# Implementation would go here to store deployment artifacts
	# This is a placeholder for the actual implementation
	debug("Storing deployment artifacts to vault");

	# Store to exodus
	my $manifest_type = $self->deployment_manifest_type;
	my $manifest_data = slurp($deploy_info->{manifest});
	my $manifest_sha1 = sha1_hex($manifest_data);

	$self->vault->query({
		'$GENESIS_EXODUS_MOUNT/'.$self->exodus_base.'/manifest' => $manifest_data,
		'$GENESIS_EXODUS_MOUNT/'.$self->exodus_base.'/manifest_type' => $manifest_type,
		'$GENESIS_EXODUS_MOUNT/'.$self->exodus_base.'/manifest_sha1' => $manifest_sha1,
	});

	return 1;
}

# }}}
# _process_deployed_manifests - process deployed manifests from various sources {{{
sub _process_deployed_manifests {
	my ($self, $at) = @_;

	# This would need to be implemented based on the actual requirements
	# For now, returning a not_found response
	return {not_found => 1} unless $at;

	# Placeholder implementation
	return {
		source => 'unknown',
		manifest_data => '',
		manifest_sha1 => '',
		manifest_type => 'unknown'
	};
}

# }}}

# }}}

1;

=head1 NAME

Genesis::Env::Deployment

=head1 DESCRIPTION

This module handles deployment operations for Genesis environments, including
manifest management, deployment execution, and secret operations.

=head1 METHODS

=head2 has_hook($hook_name)

Checks if the environment's kit has the specified hook.

=head2 run_hook($hook, %opts)

Runs the specified hook in the environment's kit.

=head2 shell(%opts)

Provides a bash shell with hook environment variables and helper functions.

=head2 manifest_provider()

Returns a manifest provider for building manifests.

=head2 deployment_manifest_type()

Determines the type of manifest to deploy.

=head2 last_deployed_manifest(%opts)

Gets the details of the last deployed manifest.

=head2 deployment_cache_setup($preserve)

Sets up the deployment cache directory.

=head2 deployment_cache_cleanup()

Removes the deployment cache directory.

=head2 deployment_cache_path_lookup($descriptor)

Returns the path to a file in the deployment cache.

=head2 deploy(%opts)

Deploys the environment using BOSH.

=head2 extract_manifest_exodus($manifest_path)

Extracts and stores exodus data from the manifest.

=head2 notify($level, $msg, @args)

Sends a notification about the environment.

=head2 add_secrets(%opts)

Adds secrets to the environment.

=head2 check_secrets(%opts)

Checks that the environment has no missing or invalid secrets.

=head2 rotate_secrets(%opts)

Generates new secrets for the environment.

=cut