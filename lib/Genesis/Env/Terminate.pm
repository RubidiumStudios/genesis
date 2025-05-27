package Genesis::Env::Terminate;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::UI;
use Time::HiRes qw/gettimeofday/;
use Time::Piece;

use constant {
	EXODUS_TIME_FORMAT => "%Y-%m-%d %H:%M:%S %z",
	EXODUS_TIME_FORMAT_SHORT => "%Y%m%d%H%M%S",
};

### Instance Methods {{{

# terminate - terminate the environment {{{
sub terminate {
	my ($self, %opts) = @_;

	# FIXME: Need to be able to handle deleting the vault deployment without erroring out.
	# Vault kit should offer a backup of the vault contents to file or to running local vault.
	# May be generic enough to use a --backup-vault-to option that takes a file or url.

	my $dryrun =   $opts{dryrun}   //= 0;
	my $force =    $opts{force}    //= 0;
	my $noprompt = $opts{noprompt} //= 0;

	my $reason =     delete($opts{reason}) // '<unspecified>';
	my $term_flags = delete($opts{flags})  // '<unspecified>';
	my %clean_up =   delete(%opts{qw/resources secrets user_secrets networking credhub/});

	my $start_time = Time::Piece->new->strftime(EXODUS_TIME_FORMAT);
	my %audit_data = (
		'started' => $start_time,
		'flags'   => $term_flags,
		'reason'  => $reason,
	);

	# TODO: Do we want to support a full reset where all exodus data and secrets are removed?
	#my $full_reset = delete($opts{'deployment-history'})//0;
	#if ($full_reset && !$clean_up{secrets} && !$clean_up{user_secrets}) {
	#	bail("Cannot perform a full reset and keep any secrets at the same time.");
	#}

	my $ok = undef;

	my $deployment_state = $self->deployment_state();
	if ($deployment_state eq 'undeployed') {
		warning(
			"No exodus data found for #C{%s}; may not exist.%s",
			$self->name,
			$force ? '': "\n\nCowardly refusing to terminate.  Use --force to attempt anyway."
		);
		return 0 unless $force;

	} elsif ($deployment_state eq 'terminated') {
		my $last_deployment = $self->deployment_lookup('latest');
		my ($date, $time) = $last_deployment->{completed} =~ m{^(\d{4}-\d{2}-\d{2}).(\d{2}:\d{2}:\d{2})};
		# FIXME: Parse with Time::Piece, then present in local time

		warning(
			"\nEnvironment #C{%s} has already been terminated%s on %s at %s UTC%s\n\n%s",
			$self->name,
			$last_deployment->{user}{shell} ? ' by #B{'.$last_deployment->{user}{shell}.'}' : '',
			$date, $time,
			$last_deployment->{reason} ? " for reason: '#Y{".$last_deployment->{reason}."}'" : '',
			$force ? 'Forcing termination anyway...' : 'Cowardly refusing to terminate.  Use --force to attempt anyway.'
		);
		return 0 unless $force;
	}

	# All the pronmpting has already been done in the Command phase
	$ENV{BOSH_NON_INTERACTIVE} = 'true';

	my $start = gettimeofday();

	if ($self->has_hook('terminate')) {
		$self->notify(
			'running %s termination hooks before deployment is terminated...%s',
			$self->kit->id,
			$dryrun ? ' (dry-run)' : '',
		);
		$ok = $self->run_hook('terminate', %opts, env => $self, mode => 'before');
		return unless $ok;
	} elsif ($self->is_bosh_director) {
		$self->_create_deployment_audit_log(
			'terminate' => 'failed',
			reason => "Aborted due to unsupported BOSH director kit (no terminate hook) - no --force specified",
			started => $start_time,
			flags => $opts{flags} || '',
			bails_with => [
				"Cowardly refusing to terminate a BOSH director environment without a ".
				"termination hook.  Please upgrade your kit to a version that supports ".
				"termination hooks, or use --force to terminate anyway (this will ".
				"likely leave orphaned resources on your IaaS unless you manually ".
				"cleaned it up first)."
			]
		 ) unless $force;

		warning(
			"\nTerminating a BOSH director environment without a termination hook.  ".
			"This will likely leave orphaned resources on your IaaS unless you ".
			"manually cleaned it up first."
		);
	}

	$self->notify(
		"terminating %s environment...%s",
		$self->use_create_env ? 'create-env' : 'deployed',
		$dryrun ? ' #i{(dry-run)}' : ''
	);
	my $results = {};
	if ($self->use_create_env) {
		$self->notify("preparing to delete a create-env environment...");
		# Gather all the files needed to send to delete-env
		my $files = {};
		$self->deployment_cache_setup;
		if ($self->manifest_store eq 'repository') {
			info(
				"[[  - >>Regenerating the unredacted manifest and vars files as needed for `bosh delete-env`.\n".
				"[[  - >>Using the state file from the local repository."
			);
			# We can use the state file in the repo, but have to generate
			# the manifest and vars files from scratch.
			$self->manifest_provider->unredacted->write_to($self->deployment_cache_path_lookup('manifest'));
			$self->manifest_provider->unredacted(subset=>'bosh_vars')->write_to($self->deployment_cache_path_lookup('vars'));
			my $state_path = grep {-f $_} map {$self->path(".genesis/manifests/".$self->name."-state.$_")} (qw/json yml/);
			bail(
				"Cannot find state file for previous deployment; cannot proceed with delete-env."
			) unless -f $state_path;
			copy_or_fail($state_path, $self->deployment_cache_path_lookup('state'));
			my $store = grep {-f $_} map {$self->path(".genesis/manifests/".$self->name."-store.$_")} (qw/yml json/);
			copy_or_fail($store, $self->deployment_cache_path_lookup('store'))
				if $store;
		} else {
			# We can pull the full manifest, vars and state files from the
			# deployment artifacts in the vault.
			info(
				"[[  - >>Using the unredacted manifest, vars and state file from the deployment archive."
			);
			my $last_deployment = $self->deployment_lookup('latest-deployed');
			bail(
				"Cannot find artifacts for previous deployment; cannot proceed with delete-env."
			) unless $last_deployment->{artifacts};
			my $contents = $self->_unpack_deployment_artifacts($last_deployment->{artifacts});
			for my $filetype (qw/manifest vars state store/) {
				my $path = $self->deployment_cache_path_lookup($filetype);
				my $key = basename($path);
				if ($contents->{$key}) {
					mkfile_or_fail($path, $contents->{$key});
				} elsif ($key =~ /^(manifest|state)$/) {
					# We need the manifest and state files to delete the environment
					# but we don't need the vars or store files.
					bail(
						"Cannot find %s file for previous deployment; cannot proceed with delete-env.",
						$key
					);
				}
			}
		}
		$self->notify("deleting create-env environment...");
		my ($out, $rc) = $self->bosh->delete_env(
			$self->deployment_cache_path_lookup('manifest'),
			%opts,
			vars_file => $self->deployment_cache_path_lookup('vars'),
			state => $self->deployment_cache_path_lookup('state'),
			store => $self->deployment_cache_path_lookup('store'),
		);
		$self->deployment_cache_cleanup;
		$ok = ($rc == 0);
		$results->{delete_env} = $out;
	} else {
		$self->notify("deleting deployment...");
		my ($out, $rc) = $self->bosh->delete_deployment(%opts);
		$ok = ($rc == 0);
		$results->{delete_deployment} = $out;
		$results->{delete_deployment_rc} = $rc;
		if ($ok) {
			if ($clean_up{resources} ) {
				$self->notify("cleaning up any unused resources...");
				$ok = $self->bosh->cleanup(%opts, env => $self, all => 1) ? 1 : 2;
				warning("\n".
					"The contents above is a summary of the resources currently unused ".
					"by any deployment. Further resources may become unused once this ".
					"environment is actually terminated."
				) if $dryrun;
			} else {
				dryrun("\nwould keep any unused resources on the #M{%s} BOSH director.", $self->bosh->{alias}) if $dryrun;
			}
		}
	}

	if ($self->has_hook('terminate')) {
		$self->notify(
			'running %s termination hooks after deployment terminated...%s',
			$self->kit->id,
			$dryrun ? ' (dry-run)' : '',
		);
		$opts{results} = $results;
		my $hook_results = $self->run_hook(
			'terminate', %opts, env => $self, mode => $ok ? 'after' : 'failed'
		);
		# FIXME: The results of the hook should be analyzed instead of just assuming its a boolean.
		$results->{hook} = $hook_results;
		$ok = 0 unless (ref($hook_results) eq 'HASH' ? $hook_results->{success} : $hook_results);
	}

	return $self->_create_deployment_audit_log(
		'terminate' => 'failed',
		%audit_data,
		reason => sub {
		}->($self,$reason),
	) unless $ok;

	# Determine existing claims, configs and secrets
	my %old_exodus = $self->exodus_lookup(".",{})->%*;
	my @genesis_claims = ();
	push @genesis_claims, grep {$_ ne 'type'} keys %old_exodus; # FIXME: why exclude type?
	push @genesis_claims, 'dns_cache';

	my @old_kit_claims = ();
	my $old_kit_meta = $old_exodus{genesis_kit_metadata} // {};
	push @old_kit_claims, @{$old_kit_meta->{exodus_data} // []};
	push @old_kit_claims, @{$old_kit_meta->{bosh_configs} // []};
	push @old_kit_claims, @{$old_kit_meta->{secrets} // []}; # non-generated secrets cannot be safely removed

	my @deployed_claims = ();
	push @deployed_claims, qw/manifest manifest_type manifest_sha1/;

	my @terminated_claims = (@genesis_claims, @old_kit_claims, @deployed_claims);

	# - Remove the claims of the environment (exodus data)
	my @cleaned_claims = @genesis_claims;
	unless ($clean_up{networking}) {
		@cleaned_claims = grep {$_ !~ /^static_ips$/} @cleaned_claims;
		dryrun(
			"\nwould leave static IP assignments in exodus data under %s",
			$self->exodus_base
		) if $dryrun && grep {$_ =~ /^static_ips$/} @genesis_claims;
	}

	$self->notify(
		"cleaning up %s environment claims%s...",
		$self->name,
		$dryrun ? ' #i{(dry-run)}' : ''
	);
	if ($dryrun) {
		my @vault_paths = $self->vault->paths($self->exodus_base);
		if (!@vault_paths) {
			dryrun("\nexodus data not found under %s - skipping", $self->exodus_base);
		} else {
			dryrun(
				"\nwould clean up %d path%s under %s",
				scalar(@vault_paths), scalar(@vault_paths) == 1 ? '' : 's', $self->exodus_base
			);
			if ($clean_up{networking}) {
				@vault_paths = grep {$_ !~ /\/static_ips$/} @vault_paths;
				if (@vault_paths) {
					trace("leaving static IP assignments: ", map {$self->exodus_base."/".$_} @vault_paths);
				}
			}
		}
	} else {
		my ($out, $rc, $err) = $self->vault->query(rm => { all => 1 },
			map { $self->exodus_base."/$_" } @cleaned_claims
		);
		$self->vault->query(tree => $self->exodus_base); # update the local cached copy
		if ($rc) {
			error(
				"Failed to remove all the exodus data from the vault:\n%s",
				$err
			);
		}
	}

	# - Remove the deployment history claims
	if ($self->manifest_store ne 'repository') {
		$self->notify(
			"cleaning up %s deployment history%s...",
			$self->name,
			$dryrun ? ' #i{(dry-run)}' : ''
		);
		if ($dryrun) {
			my @vault_paths = $self->vault->paths($self->exodus_base."/deployed");
			if (!@vault_paths) {
				dryrun("\ndeployment history not found under %s/deployed - skipping", $self->exodus_base);
			} else {
				dryrun(
					"\nwould clean up deployment history under %s/deployed",
					$self->exodus_base
				);
			}
		} else {
			my ($out, $rc, $err) = $self->vault->query(rm => { all => 1 }, $self->exodus_base."/deployed");
			if ($rc) {
				error(
					"Failed to remove the deployment history from the vault:\n%s",
					$err
				);
			}
		}
	}

	# TODO: - Remove the secrets if clean_up{secrets} || clean_up{user_secrets}
	# TODO: - Remove credhub secrets if clean_up{credhub}

	# Update the audit data to say the termination was successful
	if ($dryrun) {
		$self->notify(success => "#C{%s} environment terminated %s- #i{(dry-run)}", $self->name,
			 $ok == 2 ? 'with warnings ' : ''
		);
		return 1;
	}

	# Update the exodus data with the termination audit data
	my $end_time = Time::Piece->new->strftime(EXODUS_TIME_FORMAT);
	$self->update_deployment_exodus('terminated', %audit_data, completed => $end_time);

	$self->notify(success => "#C{%s} environment terminated %s", $self->name,
		 $ok == 2 ? 'with warnings.' : 'successfully.'
	);
	return 1;
}

# }}}

# }}}

1;

=head1 NAME

Genesis::Env::Terminate

=head1 DESCRIPTION

This module handles environment termination operations for Genesis environments.

=head1 METHODS

=head2 terminate(%opts)

Terminates the environment, including:
- Running termination hooks
- Deleting BOSH deployments or create-env environments
- Cleaning up resources, secrets, and networking
- Removing exodus data and deployment history
- Creating termination audit logs

Options include:
- dryrun: Perform a dry run without making changes
- force: Force termination even if already terminated
- reason: Reason for termination
- resources: Clean up unused resources
- secrets: Clean up secrets
- networking: Clean up network assignments

=cut