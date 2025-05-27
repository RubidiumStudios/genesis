package Genesis::Env::Utils;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::Term;
use Genesis::UI;
use Archive::Tar qw(COMPRESS_GZIP);

### Instance Methods {{{

# vars_file - create yml file and return path for bosh variables {{{
sub vars_file {
	my ($self,$redact,$file) = @_;
	my $manifest = $self->manifest_provider->deployment(subset=>'bosh_vars');
	$manifest = $manifest->redacted if $redact;
	$manifest->notify(sprintf(
		"generating %sBOSH variables file #i{(if applicable)}...",
		$redact ? "redacted " : ""
	));

	return unless scalar(keys %{$manifest->data});
	dump_var "BOSH Variables File" => $manifest->file, "Contents" => $manifest->data;
	if ($file) {
		save_to_yaml_file($manifest->data, $file);
	} else {
		$file = $manifest->file;
	}

	# BOSH variables won't interpolate more than once, so if a bosh variable
	# contains a reference to another bosh variable, it won't be resolved.
	# So, we'll have to resolve it for them.
	my $tries = 0;
	while (1) {
		my ($int_vars, $rc, $err) = $self->bosh->execute(
			'interpolate -l "$1" "$1"', $file
		);
		bail(
			"Failed to interpolate BOSH variables: %s",
			$err||$int_vars
		) if $rc;
		last if $int_vars eq slurp($file);
		save_to_yaml_file(load_yaml($int_vars), $file);
		$tries++;
		bail(
			"Failed to fully interpolate BOSH variables after %d tries, last results were:\n%s",
			$tries, $int_vars
		) if $tries > 9;
	}

	trace("[env $self->{name}] Generated BOSH Variables File $file, contents:");
	trace({raw => 1, level => 2}, slurp($file));
	trace("[env $self->{name}] --- End BOSH Variables File Contents ---");
	return $file;
}

# }}}
# deployment_manifest - get the deployment manifest {{{
sub deployment_manifest {
	my ($self, %options) = @_;
	my $redact = delete($options{redact}) || '';
	bug(
		"Expecting deployment manifest options 'redact' to be '', 'redacted', 'partial' or 'all', got %s",
		defined($redact) ? "'$redact'" : "undefined"
	) unless (grep {$_ eq $redact} ('', qw(redacted partial all)));

	$redact = 'redacted' if ($redact eq '' || $redact eq 'all') && ! can_have_unevaled_vars('manifest');
	my $man_path = $options{deployment_manifest_path} || $self->workpath("manifest.yml");
	if ($options{no_variables}) {
		my $manifest = $self->manifest_provider->unevaluated(notify => 1);
		if ($redact eq 'all' || $redact eq 'redacted') {
			$manifest = $manifest->redacted;
		} elsif ($redact eq 'partial') {
			$manifest = $manifest->partial_redaction;
		}
		$manifest->write_to($man_path);
	} else {
		my $manifest = $self->manifest_provider->deployment(notify => 1);
		if ($redact eq 'all' || $redact eq 'redacted') {
			$manifest = $manifest->redacted;
		} elsif ($redact eq 'partial') {
			$manifest = $manifest->partial_redaction;
		}
		$manifest->write_to($man_path);
	}
	return load_yaml_file($man_path);
}

# }}}
# exodus - return the exodus data for the environment, relative to the given path {{{
sub exodus {
	my ($self, $relative_path) = @_;
	if (defined($relative_path)) {
		$relative_path =~ s/^\///;
		$relative_path =~ s/\/$//;
		$relative_path .= "/" if $relative_path;
	} else {
		$relative_path = "";
	}
	my %filter = (
		map  {my $k = $_; $k =~ s/^$relative_path//; $k => $self->{__exodus}{$_}}
		grep {$_ =~ /^$relative_path/}
		keys %{$self->{__exodus} || {}}
	);
	return wantarray ? %filter : \%filter;
}

# }}}
# secrets_store - get the vault store for the environment {{{
sub secrets_store {
	return $_[0]->_memoize(sub{
		my $self = shift;
		# TODO: Use a builder?
		my $type = scalar($self->lookup('genesis.secrets_store','vault'));
		bug("Unknown secrets store type '$type' specified") unless grep {$_ eq $type} qw/vault credhub/;
		if ($type eq 'credhub') {
			return Genesis::Env::Secrets::Store::Credhub->new($self,$self->credhub);
		} else {
			return Genesis::Env::Secrets::Store::Vault->new($self,$self->vault);
		}
	});
}

# }}}
# secrets_plan - return the secrets plan for the environment {{{
sub secrets_plan {
	my ($self, %opts) = @_;

	my $plan_for = delete($opts{plan_for}) || 'genesis';
	my $recreate = delete($opts{recreate});
	# This should be a builder pattern...
	unless($self->{__secrets_plan}{$plan_for} && !$recreate) {
		if ($plan_for eq 'kit') {
			$self->{__secrets_plan}{$plan_for} = Genesis::Env::Secrets::Parser::FromKit->new($self, %opts)->parse;
		} elsif ($plan_for eq 'manifest') {
			$self->{__secrets_plan}{$plan_for} = Genesis::Env::Secrets::Parser::FromManifest->new($self, %opts)->parse;
		} else {
			$self->{__secrets_plan}{$plan_for} = Genesis::Env::Secrets::Parser->new($self, %opts)->parse;
		}
	}
	return $self->{__secrets_plan}{$plan_for};
}

# }}}
# remove_secrets - remove secrets from the environment {{{
sub remove_secrets {
	my ($self, %opts) = @_;

	my $store = $self->secrets_store(%opts);

	# Determine secrets_store from kit - assume vault for now (credhub ignored)
	my $plan = $self->secrets_plan(%opts);

	unless ($plan->secrets) {
		if ($plan->filters) {
			info("\nNo applicable secrets found - no need to continue.\n");
		} else {
			$self->notify(success => "doesn't have any secrets.\n");
		}
		return ({empty => 1});
	}

	kit_bug(
		"Kits with secrets hook are no longer supported. Check for an upgraded version."
	) if ($self->has_hook('secrets'));

	return $plan->remove_secrets(
		prompt          => $opts{prompt},
		no_prompt       => $opts{'no-prompt'},
		all             => $opts{all},
		verbose         => $opts{verbose},
		level           => $opts{verbose}?'full':'line'
	);
}

# }}}
# import_secrets - import secrets from another store {{{
sub import_secrets {
	my ($self, %opts) = @_;

	my $store = $self->secrets_store(%opts);

	# Determine secrets_store from kit - assume vault for now (credhub ignored)
	my $plan = $self->secrets_plan(%opts);

	unless ($plan->secrets) {
		if ($plan->filters) {
			info("\nNo applicable secrets found - no need to continue.\n");
		} else {
			$self->notify(success => "doesn't have any secrets to import.\n");
		}
		return ({empty => 1});
	}

	return $plan->import_secrets(
		from            => $opts{from},
		level           => $opts{verbose}?'full':'line',
		verbose         => $opts{verbose},
		no_prompt       => $opts{'no-prompt'},
		interactive     => $opts{interactive},
		level           => $opts{verbose}?'full':'line'
	);
}

# }}}

# }}}

### Private Instance Methods {{{

# _cc_yaml_files - returns list of cloud config yaml files to merge into manifest {{{
sub _cc_yaml_files {
	my ($self, @cc_types) = @_;
	return () if $self->use_create_env;
	my @cc = ();
	my @specified_cc_types = @cc_types;
	@cc_types = keys(%{$self->bosh_config_names}) unless (@cc_types); # TODO: All configs, not just cloud
	for my $cc_type (@cc_types) {
		my $cc_type_env = uc($cc_type);
		$cc_type_env =~ s/-/_/g;
		my $cc_var = sprintf('GENESIS_%s_CONFIG', $cc_type_env);
		my $cc_name = $self->lookup(["genesis.configs.$cc_type.name","genesis.$cc_type"]);
		if (envset($cc_var) || $cc_name) {
			# Use ENV value is we have it
			my $cc_file = $ENV{$cc_var};
			# Otherwise, download it if the environment specifies a valid cc name
			unless ($cc_file) {
				$cc_file = $self->workpath(".$cc_type-config");
				$self->download_configs($cc_type) unless $self->has_config($cc_type);
				copy_or_fail($self->config_file($cc_type), $cc_file);
			}
			if (@specified_cc_types && ! -f $cc_file) {
				trace("[env $self->{name}] in _cc_yaml_files(): %s cloud-config file does not exist", uc($cc_type));
			} else {
				my @cc_files = ($cc_file);
				trace("[env $self->{name}] in _cc_yaml_files(): cloud-configs: %s", join(", ", @cc_files));
				push @cc, @cc_files;
			}
		}
	}
	return @cc;
}

# }}}
# _reset_last_deployed_manifest - clear the cache of last deployed manifest used by last_deployed_lookup {{{
sub _reset_last_deployed_manifest {
	my $self = shift;
	undef($self->{__last_deployed_lookup_manifest});
}

# }}}
# _build_deployment_audit_data - build the audit data for a deployment (or termination) {{{
sub _build_deployment_audit_data {
	my ($self, $action, $result, $sequence, $timestamp, @overrides) = @_;

	my $flatten = 'unflattened';
	$flatten = shift(@overrides) if ($overrides[0] =~ /^(un)?flatten(ed)?$/);
	my %overrides = @overrides;

	my $user_data = parse_fixed_width_table({array_rows => 1},
		lines(run({stderr => '/dev/null'},'whdo', '-mH'))
	)->[1];
	my $user = $user_data->[0] // $ENV{USER};
	$user .= " ".($user_data->[3]) if $user_data->[3];

	my $deployment_data = {
		action          => $action,
		result          => $result,
		started         => $timestamp,
		completed       => $timestamp,
		sequence        => $sequence,
		genesis_version => $Genesis::VERSION,
		reason          => 'unspecified',

		kit => {
			id            => $self->kit->id,
			name          => $self->kit->name,
			version       => $self->kit->version,
			is_dev        => $self->kit->is_dev ? JSON::PP::true : JSON::PP->false,
			features      => join(',', $self->params->{kit}{features}->@*),
		},

		user => {
			shell         => $user,
			repo          => scalar($self->top->kit_provider->remote->get_authorized_user), # FIXME: only works for git-based kit providers
			vault         => scalar($self->vault->user),
			concourse     => $ENV{CONCOURSE_USERNAME},
		},
	};

	# Apply any overrides
	$deployment_data = deep_merge($deployment_data, \%overrides, $flatten);
	$deployment_data->{reason} //= 'unspecified';
	return $deployment_data;
}

# }}}
# _build_deployment_artifacts - build the deployment artifacts tarball {{{
sub _build_deployment_artifacts {
	my ($self, $artifact_file, %artifacts) = @_;

	# Secrets aren't a file, but a collection of vault paths, so we need to
	# handle them separately
	my $secrets = delete($artifacts{secrets});

	# Filter out non-existent files, and chdir if they're using absolute paths
	my @files = ();
	my $pwd = Cwd::cwd();
	for my $file (keys %artifacts) {
		my $path = $artifacts{$file};
		next unless $path && -f $path;
		push(@files, {file => $file, path => abs2rel($path, $pwd)});
	}
	return 0 unless @files || $secrets;

	trace("[env $self->{name}] Creating deployment artifacts tarball at $artifact_file, from $pwd:");
	save_to_yaml_file({
		files   => { map {$_->{file} => sha1_hex(slurp("$pwd/$_->{path}"))} @files },
		secrets => $secrets
	}, "$pwd/.manifest");
	
	my $tar = Archive::Tar->new();
	$tar->add_files(".manifest", map {$_->{path}} @files);
	$tar->write($artifact_file, COMPRESS_GZIP);
	unlink "$pwd/.manifest";
	
	return 1;
}

# }}}

# }}}

1;

=head1 NAME

Genesis::Env::Utils

=head1 DESCRIPTION

This module provides utility methods for Genesis environments, including
file operations, manifest handling, and secret management.

=head1 METHODS

=head2 vars_file($redact, $file)

Creates a YAML file containing BOSH variables and returns its path.
Handles variable interpolation to resolve nested variable references.

=head2 deployment_manifest(%options)

Gets the deployment manifest with various redaction options.

=head2 exodus($relative_path)

Returns the exodus data for the environment, optionally filtered by
a relative path.

=head2 secrets_store()

Returns the secrets store (Vault or Credhub) for the environment.

=head2 secrets_plan(%opts)

Returns the secrets plan for the environment.

=head2 remove_secrets(%opts)

Removes secrets from the environment's secrets store.

=head2 import_secrets(%opts)

Imports secrets from another secrets store.

=head2 Private Methods

=head3 _cc_yaml_files(@cc_types)

Returns list of cloud config YAML files to merge into the manifest.

=head3 _reset_last_deployed_manifest()

Clears the cache of last deployed manifest.

=head3 _build_deployment_audit_data($action, $result, $sequence, $timestamp, @overrides)

Builds audit data for a deployment or termination.

=head3 _build_deployment_artifacts($artifact_file, %artifacts)

Builds the deployment artifacts tarball.

=cut