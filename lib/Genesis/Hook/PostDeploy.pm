package Genesis::Hook::PostDeploy;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;
use Genesis::Term qw/in_controlling_terminal decolorize/;
use Genesis::UI qw/prompt_for_boolean/;
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

sub interactive {
	return $_[0]->{interactive} // 0;
}

sub validate_post_deploy_steps {
	my ($self, $steps) = @_;
	bug("validate_post_deploy_steps takes an arrayref of steps")
		unless ref($steps) eq 'ARRAY';

	my (%position, $i);
	$position{$_->{id}} = $i++ for grep {defined $_->{id}} @$steps;

	my %seen;
	for my $step (@$steps) {
		bug("post-deploy step is not a hashref") unless ref($step) eq 'HASH';
		for my $key (qw/id label method retry/) {
			bug(
				"post-deploy step %s is missing its '%s' key",
				defined($step->{id}) ? "'$step->{id}'" : '(unnamed)', $key
			) unless defined $step->{$key};
		}
		my $id = $step->{id};
		bug("duplicate post-deploy step id '%s'", $id) if $seen{$id}++;

		my $method = $step->{method};
		bug(
			"post-deploy step '%s' has method '%s', which this hook cannot resolve",
			$id, $method
		) unless ref($method) eq 'CODE' || $self->can($method);

		bug("post-deploy step '%s' has a non-arrayref args", $id)
			if defined($step->{args}) && ref($step->{args}) ne 'ARRAY';

		for my $dep (sort keys %{$step->{needs} // {}}) {
			# A prerequisite absent from the list entirely is legal: kits build
			# step lists conditionally, and a step that was never declared
			# cannot have failed.  A prerequisite declared LATER is an ordering
			# bug -- list order is execution order.
			bug(
				"post-deploy step '%s' needs '%s', which runs later -- list order ".
				"is dependency order", $id, $dep
			) if exists $position{$dep} && $position{$dep} >= $position{$id};
			my $policy = $step->{needs}{$dep};
			bug(
				"post-deploy step '%s' has unknown policy '%s' for prerequisite ".
				"'%s' (expected skip, run, or abort)", $id, $policy // '', $dep
			) unless ($policy // '') =~ /^(skip|run|abort)$/;
		}
	}
	return 1;
}

sub run_post_deploy_steps {
	my ($self, $steps, %opts) = @_;
	$self->validate_post_deploy_steps($steps);

	my %status = map {($_->{id} => 'unrun')} @$steps;
	my (%root, @failed, @skipped, @notes, %durations, $aborted);
	my $report = sub {
		return {
			failed    => \@failed,
			skipped   => \@skipped,
			notes     => \@notes,
			aborted   => $aborted,
			status    => \%status,
			durations => \%durations,
		};
	};

	# Post-deploy steps configure the thing that was just deployed; after a
	# failed deploy there is nothing to configure, and the runner owns that
	# gate so no kit can forget it.  Cleanup-style step lists opt out.
	return $report->()
		unless $self->deploy_successful || $opts{even_if_failed};

	STEP: for my $i (0..$#$steps) {
		my $step = $steps->[$i];
		my ($id, $label, $retry) = @{$step}{qw/id label retry/};

		# Resolve ALL triggered edges before acting, strongest policy wins
		# (abort > skip > run) -- resolving edges one at a time would let the
		# alphabetical order of prerequisite ids decide whether an abort
		# fires, and a step could end up both noted and skipped.
		my %rank = (run => 1, skip => 2, abort => 3);
		my ($policy, $trigger) = ('', undef);
		for my $dep (sort keys %{$step->{needs} // {}}) {
			next unless ($status{$dep} // '') =~ /^(failed|skipped)$/;
			if (($rank{$step->{needs}{$dep}} // 0) > ($rank{$policy} // 0)) {
				($policy, $trigger) = ($step->{needs}{$dep}, $dep);
			}
		}

		if ($policy eq 'abort') {
			$aborted = $id;
			$status{$id} = 'skipped';
			push @skipped, {
				id => $id, label => $label, retry => $retry,
				reason => 'aborted', blocked_by => $trigger,
				root_cause => $root{$trigger} // $trigger,
			};
			push @skipped, map {
				+{id => $_->{id}, label => $_->{label}, retry => $_->{retry},
					reason => 'aborted'}
			} @{$steps}[$i+1..$#$steps];
			last STEP;
		} elsif ($policy eq 'skip') {
			$status{$id} = 'skipped';
			$root{$id} = $root{$trigger} // $trigger;
			push @skipped, {
				id => $id, label => $label, retry => $retry,
				reason => 'blocked', blocked_by => $trigger,
				root_cause => $root{$id},
			};
			next STEP;
		} elsif ($policy eq 'run') {
			push @notes, {id => $id, label => $label, blocked_by => $trigger};
		}

		my $method = $step->{method};
		my @args = @{$step->{args} // []};
		my $tstart = gettimeofday;
		my ($result, $error);
		# Two-variable eval on purpose: `my $r = eval {...}` would turn a
		# dying step into undef and misread it as "nothing to do".
		my $ok = eval {
			$result = ref($method) eq 'CODE'
				? $method->($self, @args)
				: $self->$method(@args);
			1;
		};
		$durations{$id} = gettimeofday - $tstart;
		if (!$ok) {
			my $err = $@ // '';
			# bail() and bug() mean "stop genesis now"; swallowing them into
			# the report would silently change their meaning for every kit
			# (and discard bail's exit code).  Only foreign exceptions are
			# step failures.
			die $err if decolorize($err) =~ /^\s*\[FATAL\]/;
			($error = decolorize($err)) =~ s/\s+/ /g;
			$error =~ s/^\s+|\s+$//g;
			$error = substr($error, 0, 197).'...' if length($error) > 200;
			$result = 0;
		}
		$status{$id} = !defined($result) ? 'noop' : $result ? 'ok' : 'failed';
		if ($status{$id} eq 'failed') {
			$root{$id} = $id;
			push @failed, {
				id => $id, label => $label, retry => $retry,
				(defined $error ? (error => $error) : ()),
			};
		}
	}
	return $report->();
}

sub report_post_deploy_results {
	my ($self, $report, %opts) = @_;
	my @failed  = @{$report->{failed}  // []};
	my @skipped = @{$report->{skipped} // []};
	my @notes   = @{$report->{notes}   // []};
	return 1 unless @failed || @skipped;

	my %label = map {($_->{id} => $_->{label})} @failed, @skipped;
	my $cmd = scalar $self->env->get_call_path_with_env;
	# Literal token substitution, not sprintf: retry commands that need no
	# call path (plain bosh/safe commands) must not warn, and a literal %
	# in a template must survive.
	my $render_retry = sub {
		(my $out = $_[0]) =~ s/\Q%s\E/$cmd/g;
		return $out;
	};

	my $count = @failed + @skipped;
	my $intro = $opts{intro} // sprintf(
		"The deployment succeeded, but %d post-deploy step%s did not complete:",
		$count, $count == 1 ? '' : 's'
	);
	my $outro = $opts{outro} //
		"The deployment itself is recorded.  Fix the cause, then re-run the ".
		"deploy or complete the steps individually with the commands above.";

	error(
		"\n%s\n%s\n\n%s",
		$intro,
		join("\n",
			(map {
				sprintf("[[  - >>#R{%s}%s - retry with #G{%s}",
					$_->{label},
					defined $_->{error} ? " ($_->{error})" : '',
					$render_retry->($_->{retry}))
			} @failed),
			(map {
				sprintf("[[  - >>#Y{%s} - not run (%s); once fixed: #G{%s}",
					$_->{label},
					$_->{reason} eq 'aborted' && !defined $_->{blocked_by}
						? 'post-deploy aborted'
						: 'blocked by '.($label{$_->{blocked_by}} // $_->{blocked_by}),
					$render_retry->($_->{retry}))
			} @skipped),
			(map {
				sprintf("[[  - >>#C{%s} ran although %s had failed",
					$_->{label}, ($label{$_->{blocked_by}} // $_->{blocked_by}))
			} @notes),
		),
		$outro
	);
	return 0;
}

sub update_director_network_config {
	my $self = shift;
	my $env = $self->env;

	return unless $env->can_build_cloud_configs;

	# Run the director-cloud-config hook to generate and apply the cloud-config
	$env->notify("generating the Network space for the BOSH Director");
	info({pending => 1}, "[[  - >>building director cloud-config...");
	my $tstart = gettimeofday;
	my ($config, $network) = $env->run_hook('cloud-config', purpose => 'director');
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 5, 10));

	# FIXME: Do a check and compare, and ask if different (or just do it if $BOSH_NON_INTERACTIVE is set)
	# or at least show the diff (maybe too late to ask if bosh is already deployed)
	#
	info({pending => 1}, "[[  - >>uploading #c{%s.%s.director} cloud-config...", $env->name, $env->type);
	my $bosh = $env->get_target_bosh({self => !$env->use_create_env});
	my $config_name = join('.',$env->name, $env->type, 'director');
	$tstart = gettimeofday;
	$bosh->upload_config($config, 'cloud', $config_name);
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 5, 10));

	# Check if network has changes, and if so, show them and store them in exodus

	info({pending => 1}, "[[  - >>storing director network details in exodus...");
	$tstart = gettimeofday;
	$env->vault->set_path($env->exodus_base.'/network', $network, flatten => 1, clear => 1);
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 1, 3));

	# Explicit success: without it the return value is whatever info()
	# returned, and a fully successful upload reads as "nothing to do" to
	# run_post_deploy_steps.  Failures above report by bailing.
	return 1;
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
	# A plain boolean, not $self->done(1): marking the whole hook complete
	# is the caller's decision, not a side effect of one step.
	return 1;
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
