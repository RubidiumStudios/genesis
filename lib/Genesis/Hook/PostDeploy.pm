package Genesis::Hook::PostDeploy;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;
use Genesis::Term qw/in_controlling_terminal/;
use Genesis::UI qw/prompt_for_boolean/;
use Genesis::Env::NetworkClaims;
use Service::Credhub;
use Time::HiRes qw/gettimeofday/;
use JSON::PP;

sub init {
	my ($class, %ops) = @_;
	my @missing = grep {!defined($ops{$_})} qw/env rc/;
	bug(
		"Missing required arguments for a perl-based kit hook call: %s",
		join(", ", @missing)
	) if @missing;

	my $obj = $class->SUPER::init(%ops);
	return $obj;
}

sub deploy_successful {
	return $_[0]->{rc} == 0;
}

sub data {
	return $_[0]->{data} ||= {};
}

# How often update_director_network_config checks a network claims lock that
# another process holds.  A package variable so tests can shorten it.
our $NETWORK_LOCK_POLL_SECONDS = 5;

sub update_director_network_config {
	my $self = shift;
	my $env = $self->env;

	return unless $env->can_build_cloud_configs;

	$env->notify("generating the Network space for the BOSH Director");
	my $bosh = $env->get_target_bosh({self => !$env->use_create_env});
	my $config_name = join('.', $env->name, $env->type, 'director');

	# The director's own cloud config is built from the claims every deployment
	# on this director has recorded, and the network record is rewritten from
	# it, so both happen under the director's network claims lock.  A signal
	# while the lock is held unwinds through the release below instead of
	# leaving the lock on the director.
	local $SIG{INT}  = sub { die "Interrupted by user\n" };
	local $SIG{TERM} = sub { die "Terminated\n" };
	local $SIG{HUP}  = sub { die "Hung up\n" };
	local $SIG{QUIT} = sub { die "Quit\n" };

	my $acquired = 0;
	my $step = 'taking the network claims lock';
	my $ok = eval {
		$acquired = $self->_acquire_director_network_lock($bosh, $config_name);
		if ($acquired) {
			$step = 'building the director cloud config';
			info({pending => 1}, "[[  - >>building director cloud-config...");
			my $tstart = gettimeofday;
			my ($config, $network) = $env->run_hook('cloud-config', purpose => 'director');
			info("#G{done}" . pretty_duration(gettimeofday - $tstart, 5, 10));

			$step = 'uploading the director cloud config';
			info({pending => 1}, "[[  - >>uploading #c{%s} cloud-config...", $config_name);
			$tstart = gettimeofday;
			$bosh->upload_config($config, 'cloud', $config_name);
			info("#G{done}" . pretty_duration(gettimeofday - $tstart, 5, 10));

			# Strict, because a failed read would look like a record with no
			# claims, and the summary would then show every claim as new
			$step = 'storing the director network details in exodus';
			my $network_path = $env->exodus_base.'/network';
			my $stored = $env->vault->get_path_strict($network_path) // {};
			Genesis::Env::NetworkClaims::claims_summary($network_path, $stored, $network);
			info({pending => 1}, "[[  - >>storing director network details in exodus...");
			$tstart = gettimeofday;
			$env->vault->set_path($network_path, $network, flatten => 1, clear => 1);
			info("#G{done}" . pretty_duration(gettimeofday - $tstart, 1, 3));
		}
		1;
	};
	my $err = $@;

	# Released whenever this process holds it, which covers a signal that
	# lands between taking the lock and recording that it was taken
	my $released = eval {
		if ($bosh->network_locked_by_me) {
			info({pending => 1}, "[[  - >>releasing network claims lock on #M{%s} BOSH director...", $bosh->alias);
			$bosh->clear_network_lock;
			info("#G{done}");
		}
		1;
	};
	error(
		"The network claims lock on the #M{%s} BOSH director could not be released: %s\n".
		"Other deploys on this director will wait for it until it goes stale, which ".
		"is after 30 minutes, or sooner once this process has exited when they run ".
		"on this same host.  This usually means the vault became unreachable or the ".
		"token expired during the step.  Check the vault, then run ".
		"#C{%s bosh-configs upload --type cloud --name %s -y}, which clears a stale ".
		"lock and finishes this step.",
		$bosh->alias, ($@ =~ s/\s+$//r), scalar($env->get_call_path_with_env), $config_name
	) unless $released;

	unless ($ok) {
		# A signal passes through as it came, and the lock waiter has already
		# said what it found; anything else failed after the director deployed
		die $err if $err =~ /^(?:Interrupted by user|Terminated|Hung up|Quit)\s*$/;
		bail(
			"The #M{%s} BOSH director deployed and is working, but its own cloud config ".
			"#C{%s} and its network record in exodus were not updated.  The step failed ".
			"while %s:\n\n%s\n\nThis usually means the vault is sealed or unreachable, ".
			"the token has expired or has no read or write access to #C{%s}, or the ".
			"director refused the cloud config.  Check the vault and the token with ".
			"#C{safe vault status} and #C{safe export %s}, then run #C{%s bosh-configs ".
			"upload --type cloud --name %s -y} to finish this step without a redeploy.",
			$bosh->alias, $config_name, $step, ($err =~ s/\s+$//r), $env->exodus_base.'/network',
			$env->exodus_base.'/network', scalar($env->get_call_path_with_env), $config_name
		);
	}
	return $acquired ? 1 : 0;
}

sub _acquire_director_network_lock {
	my ($self, $bosh, $config_name) = @_;
	my $env = $self->env;

	my $limit = $ENV{GENESIS_NETWORK_LOCK_WAIT} // 300;
	unless ($limit =~ /^\d+$/) {
		warning(
			"GENESIS_NETWORK_LOCK_WAIT is set to '%s', which is not a whole number of ".
			"seconds, so the step waits the default 300 seconds for the network ".
			"claims lock instead.  Set it to a number such as #C{600}, or unset it.",
			$limit
		);
		$limit = 300;
	}
	my $interval = $NETWORK_LOCK_POLL_SECONDS > 0 ? $NETWORK_LOCK_POLL_SECONDS : 5;

	my ($waited, $announced, $lock, $acquire_error) = (0, '');
	while (1) {
		$acquire_error = undef;
		$lock = $bosh->check_network_lock;
		if ($lock->{status} eq 'unlocked') {
			# Another process can take it between the check and here, and then
			# acquire_network_lock refuses; go round again and wait for it.  A
			# refusal that leaves the lock free is a vault failure instead, and
			# waits and counts the same as a held lock does.
			return 1 if eval { $bosh->acquire_network_lock; 1 };
			$acquire_error = ($@ =~ s/\s+$//r) || 'unknown error';
			$lock = $bosh->check_network_lock;
			undef $acquire_error unless $lock->{status} eq 'unlocked';
		}
		last if $lock->{status} eq 'stale' || $waited >= $limit;

		# Said again whenever the reason for waiting changes, so a vault
		# error that clears into a lock held by another process (or the
		# reverse) is not left under the wrong message
		my $reason = defined($acquire_error) ? 'error' : 'held';
		if ($announced ne $reason) {
			$announced = $reason;
			if (defined $acquire_error) {
				info(
					"[[  - >>the network claims lock on #M{%s} BOSH director could not be ".
					"taken (%s); retrying for up to %s...",
					$bosh->alias, $acquire_error, count_nouns($limit, "second")
				);
			} else {
				info(
					"[[  - >>the network claims lock on #M{%s} BOSH director is held %s; ".
					"waiting up to %s for it...",
					$bosh->alias, $lock->{description} // 'by another process',
					count_nouns($limit, "second")
				);
			}
		}
		my $step = $interval < $limit - $waited ? $interval : $limit - $waited;
		sleep($step);
		$waited += $step;
	}

	my $finish = sprintf(
		"%s bosh-configs upload --type cloud --name %s -y",
		scalar($env->get_call_path_with_env), $config_name
	);
	if ($lock->{status} eq 'stale') {
		error(
			"The #M{%s} BOSH director deployed and is working, but its own cloud config ".
			"#C{%s} and its network record in exodus were not updated.  The network ".
			"claims lock on the director is stale: it was taken %s, and that process ".
			"is gone or has held it for more than 30 minutes.  Post-deploy does not ".
			"clear a stale lock unattended, because it cannot tell whether the holder ".
			"left its claims half written.  This usually means an earlier deploy or ".
			"#C{bosh-configs upload} on this director was interrupted.  Check that no ".
			"deploy is running against this director, then run #C{%s}, which clears ".
			"the stale lock and finishes this step without a redeploy.",
			$bosh->alias, $config_name, $lock->{description} // 'by an unknown process', $finish
		);
	} elsif (defined $acquire_error) {
		error(
			"The #M{%s} BOSH director deployed and is working, but its own cloud config ".
			"#C{%s} and its network record in exodus were not updated.  The network ".
			"claims lock on the director is free, but it could not be taken, and it ".
			"still could not be taken after %s.  The last error was: %s.  This usually ".
			"means the vault is sealed or unreachable, the token has expired, or the ".
			"token has no write access to the director's network claims lock in ".
			"exodus.  Check the vault and the token, then run #C{%s} to finish this ".
			"step without a redeploy.",
			$bosh->alias, $config_name, count_nouns($waited, "second"), $acquire_error, $finish
		);
	} else {
		error(
			"The #M{%s} BOSH director deployed and is working, but its own cloud config ".
			"#C{%s} and its network record in exodus were not updated.  The network ".
			"claims lock on the director was held %s, and it was still held after ".
			"waiting %s.  This usually means another deploy on this director held the ".
			"lock, for example while it waited at a confirmation prompt.  Once that ".
			"deploy has finished, run #C{%s} to finish this step without a redeploy.  ".
			"Set #C{GENESIS_NETWORK_LOCK_WAIT} to a number of seconds to wait longer ".
			"next time.",
			$bosh->alias, $config_name, $lock->{description} // 'by another process',
			count_nouns($waited, "second"), $finish
		);
	}
	return 0;
}

sub command {
	my $self = shift;
	my @cmd = ($ENV{GENESIS_CALL_ENV} ||$ENV{GENESIS_CALL});
	for my $arg (@_) {
		$arg = "'$arg'" if ($arg =~ / \(\)!\*\?/);
		push @cmd, $arg;
	}
	return join(" ", @cmd);
}

sub help {
	my ($self, %addons) = @_;

	if ($self->can('cmd_details')) {
		info (
			"\n#Gu{%s}\n[[  >>%s\n",
			$self->{label}, join("\n[[  >>", split("\n",$self->cmd_details()))
		);
		return 1;
	}

	# FIXME: The code below is not being called yes, so may contain errors:
	# - the passed in %addons does not seem compatible with the code below
	#   due to the includsion of $addons{$cmd} already containing the help
	#   output.

	# Loook for any extended addon hooks
	my @module_files = glob($self->kit->path("hooks/addon-*.pm"));
	foreach my $file (@module_files) {
		my $class = $self->load_hook_module($file, $self->kit);
		next unless $class && $class->can('cmd_details');
		my ($cmd) = $file =~ m{addon-(.*)\.pm};
		$addons{"$cmd"} = $class->cmd_details() // 'No help available';
	}

	unless (keys %addons) {
		info "No addons are defined for the %s kit.", $self->env->kit->id;
		return 0
	}

	my ($label, $short, $msg);
	info "The following addons are defined for the %s kit:", $self->env->kit->id;

	foreach my $cmd (sort keys %addons) {
		$label = $cmd =~ s/([^~]*).*/$1/r;
		$short = $cmd =~ s/([^~]*)(~(.*))?/$3/r;
		$short = "|$short" if $short;
		info(
			"\n  #Gu{%s%s}\n[[    >>%s",
			$label, $short, join("\n[[    >>", split("\n",$addons{$cmd}))
		);
	}
}

sub upload_director_cpi_config {
	my $self = shift;
	return $self->env->upload_director_cpi_config(@_);
}

sub upload_stemcells {
	# This will upload the stemcells to the director.  If non-interactive, it will upload the latest stemcell
	# for the IaaS.  If interactive, it will ask the user to select a stemcell to upload.

	# RISK: This assumes that the kit is a bosh director, but doesn't verify it.

	my ($self) = @_;
	return unless $self->deploy_successful;

	my $env = $self->env;
	my $bosh = $env->get_target_bosh({self => 1});

	$env->notify("checking for stemcells on the BOSH director");
	my @stemcells = values $bosh->stemcells()->%*;
	if (@stemcells) {
		info("[[  - >>found %s on the BOSH director", count_nouns(scalar @stemcells, 'existing stemcell'));
		return 1;
	}

	# If interactive, ask the user if they want to upload a stemcell
	if (in_controlling_terminal && $self->{interactive}) {
		my $answer = prompt_for_boolean(
			"[[  - >>no stemcells found on the BOSH director. Do you want to upload a stemcell? [y|n] ",
			1
		);
		return unless $answer;
	}

	# Otherwise, use the Service::BOSH::Stemcell module to upload a suitable stemcell
	my $tstart = gettimeofday;
	info({pending => 1}, "[[  - >>determining available stemcells...");
	my $type_filter = $self->env->lookup('bosh-configs.stemcells.type',undef);
	my @available_stemcells = $bosh->available_stemcells(
		env => $env,
		all => 1,
		type => $type_filter,
	);

	if (!@available_stemcells) {
		info("#R{failed}" . pretty_duration(gettimeofday - $tstart, 2, 5));
		error("No available stemcells found for the IaaS %s", $env->iaas);
		return 0;
	}
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 2, 5));

	my $selected_stemcell;
	if ($self->{interactive}) {
		require Service::BOSH::Stemcell;
		$selected_stemcell = Service::BOSH::Stemcell->select_stemcell(
			stemcells => \@available_stemcells,
			type => $type_filter
		);
	} else {
		# Select the latest available stemcell
		$selected_stemcell = $available_stemcells[0]; # Latest is always first
	}

	info("[[  - >>uploading first stemcell to BOSH director:");

	my $ok = $selected_stemcell->upload(
		$bosh,
		dryrun => 0, # Post-deploy hook is not run in dry-run mode
	);

	if (!$ok) {
		error("Failed to upload stemcells!");
		return 0;
	}

	notice(
		"\nTo add more stemcells later, run:\n".
		"  #G{%s do upload-stemcells [--os <os>] <version>[... <versionN>]}\n".
		"#Ki{(or run with no arguments to be provided with a list to chose from)}\n",
		scalar $self->env->get_call_path_with_env,
	);
	return 1;
}

sub upload_runtime_configs {
	my ($self) = @_;
	my $env = $self->env;
	my $runtime_opts = $env->lookup('bosh-configs.runtime', undef);
	return if !$runtime_opts;

	bail(
		"Runtime configs must be a hash reference, got %s.  Please check the ".
		"'bosh-configs.runtime' setting in the #C{%s} environment.",
		ref($runtime_opts)//(defined($runtime_opts) ? "#B{'$runtime_opts'}" : '#R{<undef>}'),
		$env->name
	) unless ref $runtime_opts eq 'HASH';
	return if !scalar(keys %$runtime_opts);

	bail(
		"The #M{%s} kit does not provide any runtime configs.  Please check the ".
		"'bosh-configs.runtime' setting in the #C{%s} environment.",
		$self->env->kit->id, $self->env->name
	) unless $env->has_hook('runtime-config');

	$env->notify(
		"uploading %s runtime config%s to the BOSH director",
		sentence_join(sort keys %$runtime_opts),
		scalar(keys %$runtime_opts) != 1 ? 's' : ''
	);

	my $tstart = gettimeofday;

	# TODO: Support options in the runtime configs, such as:
	# action => upload (default) or remove
	# merge_with => object to merge with (default: empty)
	# replace_with => object to replace with (default: empty)

	# Right now, we just support the `params` key, which will be the arguments passed in.
	# Validate the runtime configs before proceeding
	my @errors = map {
		my $config = $runtime_opts->{$_};
		sprintf(
			"#Y{%s} is %s",
			$_, ref($config) ? "a ".ref($config) :
			defined($config) ? "'$config'" : '#R{<undef>}'
		);
	} grep {
		my $config = $runtime_opts->{$_};
		!(ref($config) eq 'HASH' || ref($config) eq 'JSON::PP::Boolean');
	} sort keys %{$runtime_opts};
	bail(
		"Runtime config options must be a hash reference or boolean, but:\n%s\n",
		join("\n", map {"  - $_"} @errors)
	) if @errors;

	# Now we can run the runtime configs
	my ($out, $rc, $err) = $env->run_hook('runtime-config', args => $runtime_opts, interactive => $self->{interactive});

	if ($rc) {
		error("Failed to successfully run runtime config hook: %s", $err);
		return 0;
	}
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 2, 5));
	return $self->done(1);
}

sub results {
	return 1;
}

sub _commit_config_credhub_secrets {
	my ($self, $secrets) = @_;
	my @paths = keys %{$secrets || {}};
	return 1 unless @paths;

	my $bosh = $self->env->get_target_bosh({self => 1});
	my $credhub = Service::Credhub->from_bosh($bosh);
	my $start = gettimeofday;
	info({pending => 1},
		"[[  - >>entombing %s secrets into #M{%s} BOSH director's credhub...",
		scalar @paths,
		$self->env->name
	);
	for my $path (@paths) {
		my $secret = $secrets->{$path};
		bail("No value specified for the secret %s", $path) unless $secret;
		# FIXME: set supports ($out, $rc, $err) model so we can check for errors
		# directly instead of capturing bails in an eval block.
		eval {$credhub->set($path, $secrets->{$path})};
		my $err = $@;
		if ($err) {
			info("#G{failed}" . pretty_duration(gettimeofday - $start, 2, 5));
			bail("Failed to entomb the secret %s: %s", $path, $err);
		}
	}
	info("#G{done}" . pretty_duration(gettimeofday - $start, 2, 5));
	return 1
}

1;
