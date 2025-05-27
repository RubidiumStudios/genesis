package Genesis::Env::Configuration;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::UI;

use constant {
	EXODUS_TIME_FORMAT => "%Y-%m-%d %H:%M:%S %z",
	EXODUS_TIME_FORMAT_SHORT => "%Y%m%d%H%M%S",
};

### Instance Methods {{{

# features - returns the list of features (specified and derived) {{{
sub features {
	my $ref = $_[0]->_memoize(sub {
		my $self = shift;
		my $features = scalar($self->lookup('kit.features', []));
		bail(
			"Environment #C{%s} #G{kit.features} must be an array - got a #y{%s}.",
			$self->name, defined($features) ? (lc(ref($features)) || 'string') : 'null'
		) unless ref($features) eq 'ARRAY';

		my @derived_features = grep {$_ =~ /^\+/} $features;
		bail(
			"Environment #C{%s} cannot explicitly specify derived features:\n  - %s",
			$self->name, join("\n  - ",@derived_features)
		) if @derived_features;
		$features = $self->kit->run_hook('features',env => $self, features => $features)
			if $self->kit->has_hook('features');
		$features;
	});
	return @$ref;
}

# }}}
# has_feature - returns true if the environment requests the given feature {{{
sub has_feature {
	my ($self, $feature) = @_;
	for my $have ($self->features) {
		return 1 if $feature eq $have;
	}
	return 0;
}

# }}}
# params - get all the values from the hierarchal environment. {{{
sub params {
	return $_[0]->_memoize(sub {
		my $manifest_type = envset("GENESIS_UNEVALED_PARAMS")
			? 'unevaluated_environment'
			: 'partial_environment';
		$_[0]->manifest_provider->$manifest_type->data;
	});
}

# }}}
# defines - true if the given path is defined in the hierarchal environment parameters. {{{
sub defines {
	my ($self, $key) = @_;
	my $found;
	if (defined($self->{__params})) {
		(undef, $found) = struct_lookup($self->params(),$key);
	} else {
		(undef, $found) = $self->lookup_unevaled($key);
	}
	return defined($found);
}

# }}}
# lookup - look up a value from the heirarchal evironment {{{
sub lookup {
	my ($self, $key, $default) = @_;
	return struct_lookup($self->params, $key, $default);
}

# }}}
# lookup_unevaled - look up a value from the heirarchal evironment without evaluating operators {{{
sub lookup_unevaled {
	my ($self, $key, $default) = @_;
	return $default unless $self->actual_environment_files();
	return struct_lookup($self->manifest_provider->unevaluated_environment->data, $key, $default);
}

# }}}
# partial_manifest_lookup - look up a value from a best-effort merged manifest for this environment {{{
sub partial_manifest_lookup {
	my ($self, $key, $default) = @_;
	return struct_lookup($self->manifest_provider->partial->data, $key, $default);
}

# }}}
# manifest_lookup - look up a value from a completely merged manifest for this environment {{{
sub manifest_lookup {
	my ($self, $key, $default) = @_;
	return struct_lookup($self->manifest_provider->base_manifest->data, $key, $default);
}

# }}}
# last_deployed_lookup - look up values from the last deployment of this environment {{{
sub last_deployed_lookup {
	my ($self, $key, $default) = @_;
	my $last_manifest = $self->{__last_deployed_lookup_manifest};
	unless ($last_manifest) {
		my $last_manifest_file = $self->last_deployed_manifest(just => 'file');
		die "No successfully deployed manifest found for $self->{name} environment"
			unless $last_manifest_file;
		$last_manifest = load_yaml_file($last_manifest_file);
		$self->{__last_deployed_lookup_manifest} = $last_manifest;
	}
	return struct_lookup($last_manifest, $key, $default);
}

# }}}
# exodus_lookup - lookup Exodus data from the last deployment of this (or named) deployment {{{
sub exodus_lookup {
	my ($self, $key, $default,$for) = @_;
	$key //= '.';
	$for ||= $self->exodus_slug;
	my $path =  $self->exodus_mount().$for;
	debug "Checking if $path path exists...";
	return $default unless $self->vault->has($path);
	debug "Exodus data exists, retrieving it and converting to json";

	my $extended = 0;
	if ($key =~ m#^(/[^:]*)(?::(.*))?#) {
		$path .= $1;
		$key = $2//'';
		$extended = 1;
	}

	my $out;
	if ($extended) {
		eval {$out = $self->vault->get_path($path);};
		bail "Could not get $for exodus data from the Vault: $@" if $@;
		return struct_lookup($out, $key, $default);
	} else {
		eval {$out = $self->vault->get($path);};
		bail "Could not get $for exodus data from the Vault: $@" if $@;
		my $exodus = unflatten($out);
		return struct_lookup($exodus, $key, $default);
	}
}

# }}}
# director_exodus_lookup - lookup Exodus data from the director that deploys this environment {{{
sub director_exodus_lookup {
	my ($self, $key) = (shift, shift);
	my $default = shift if scalar(@_) % 2 == 1;
	my %opts = @_;

	# Return default (with undef source) if this is a create-env environment
	return (wantarray ? ($default, undef) : $default) if $self->use_create_env;

	# Check for cached data
	my $bosh_exodus = undef;
	my $ext_path = undef;
	if ($key =~ m#^(/[^:]*)(?::(.*))?#) {
		$ext_path = $1;
		$key = $2//'';
	}
	if (exists($self->{__director_exodus_cache}{$ext_path//''})) {
		$bosh_exodus = $self->{__director_exodus_cache}{$ext_path//''};
	} else {
		# FIXME: This assumes the bosh deployment is of type 'bosh' -- we need to pass in options to override this if needed.
		my $path = $self->bosh->exodus_path; # changed fromn ${bosh_exodus_mount}${bosh_alias}/$bosh_dep_type";
		my $out;
		if ($ext_path) {
			eval {$out = $self->bosh->vault->get_path("$path$ext_path");}; # changed from $bosh_vault to $self->bosh->vault
			bail "Could not get director exodus data from the Vault: $@" if $@;
		} else {
			eval {$out = $self->bosh->vault->get($path);}; # changed from $bosh_vault to $self->bosh->vault
			bail "Could not get director exodus data from the Vault: $@" if $@;
			$out = unflatten($out);
		}
		$bosh_exodus = $self->{__director_exodus_cache}{$ext_path//''} = $out;
	}
	return $bosh_exodus unless defined($key);
	return struct_lookup($bosh_exodus, $key, $default);
}
# }}}
# deployment_lookup - lookup deployment details for a given timestamp, or list of deployments timestamps {{{
sub deployment_lookup {
	my ($self, $timestamp) = @_;
	my @deployments = map {s{.*/deployments/}{}r} $self->vault->paths($self->exodus_base.'/deployments');
	return @deployments if (!defined($timestamp));

	return unless @deployments;

	# Standardize the timestamp
	if ($timestamp =~ /^latest(?:-(\w+))?$/) {
		my $state = $1;
		bug(
			"Invalid state '%s' specified for latest deployment lookup: expected ".
			"one of 'deployed', 'failed', or 'terminated'.",
			$state
		) if $state && $state !~ /^(deployed|failed|terminated)$/;
		my @ordered_timestamps = sort {$b cmp $a} @deployments;
		while ($timestamp = shift @ordered_timestamps) {
			last unless $state;
			last if $self->vault->get($self->exodus_base."/deployments/$timestamp","state") eq $state;
		}
		if (!defined($timestamp)) {
			bail("No deployments found with state '$state' for environment '%s'", $self->name);
		}
	} elsif ($timestamp < 0) {
		$timestamp = (sort {$a cmp $b} @deployments)[$timestamp];
		return unless $timestamp;
	} elsif ($timestamp =~ /([<>]=?)?(20\d{2})-?(\d{2})-?(\d{2})[T ]?(\d{2}):?(\d{2}):?(\d{2})(?:[Z ]?([+-]\d{4}))?/) {
		my ($cp, $ty, $tm, $td, $tH, $tM, $tS, $tz) = ($1//'', $2, $3, $4, $5, $6, $7, $8//'+0000');

		use Time::Piece;
		my $ts = Time::Piece->strptime("$ty-$tm-$td $tH:$tM:$tS $tz", EXODUS_TIME_FORMAT);
		$timestamp = $ts->gmtime($ts->epoch)->strftime(EXODUS_TIME_FORMAT_SHORT);

		if ($cp eq '<=') {
			$timestamp = (sort {$b cmp $a} grep {$_ le $timestamp} @deployments)[0];
		} elsif ($cp eq '>=') {
			$timestamp = (sort {$a cmp $b} grep {$_ ge $timestamp} @deployments)[0];
		} elsif ($cp eq '<') {
			$timestamp = (sort {$b cmp $a} grep {$_ lt $timestamp} @deployments)[0];
		} elsif ($cp eq '>') {
			$timestamp = (sort {$a cmp $b} grep {$_ gt $timestamp} @deployments)[0];
		} elsif ($cp) {
			bail("Invalid comparison operator '$cp' in timestamp '$timestamp': must be '<', '>', '<=', or '>='");
		}
	}

	my $manifest_data = $self->vault->get($self->exodus_mount.$self->exodus_slug."/deployments/$timestamp");
	if (delete($manifest_data->{__flattened__})) {
		$manifest_data = unflatten($manifest_data);
	}
	$manifest_data->{timestamp} = $timestamp;
	return $manifest_data;
}

# }}}
# dereferenced_kit_metadata - get kit metadata that been filled with environment references {{{
sub dereferenced_kit_metadata {
	my ($self) = shift;
	return $self->kit->dereferenced_metadata(sub {$self->partial_manifest_lookup(@_)}, 1);
}

# }}}
# vault_paths - get the list of paths in the vault for this environment {{{
sub vault_paths {
	my ($self, %opts) = @_;

	$self->manifest_provider
		->base_manifest
		->get_vault_paths(notify=>$opts{notify}//1);
}

# }}}
# scale - returns the scale for the environment {{{
sub scale {
	my ($self) = @_;
	my $scale = $self->lookup(
		['bosh-configs.scale', 'kit.scale']
	);

	return $scale if $scale;
	eval {$scale = $self->director_exodus_lookup('scale',undef)};

	bug(
		"No scale set for %s environment, and no default scale set for ".
		"deployments under %s bosh director.",
		$self->name, $self->bosh->alias
	) if !$scale && $self->kit->requires_scale($self);

	return $scale//'';
}

# }}}
# iaas - returns the iaas for the environment {{{
sub iaas {
	my ($self) = @_;
	my $iaas = $self->lookup(
		['kit.iaas','bosh-configs.iaas']
	);

	return $iaas if $iaas;

	bail(
		"No IaaS type set for %s environment, which uses a create-env deployment. ".
		"Please set the `kit.iaas` in the enviroment file -- you can use #G{%s ".
		"%s edit} to do this.",
		$self->name,
		humanize_bin(),
		humanize_path($self->path($self->name))
	) if $self->use_create_env;

	eval {$iaas = $self->director_exodus_lookup('iaas') }; # FIXME: How to handle multiple CPIs?

	bail(
		"No IaaS type set for %s environment, and no default IaaS type set for ".
		"deployments under %s bosh director.",
		$self->name, $self->bosh->alias
	) if ! $iaas && $self->kit->requires_iaas($self);

	return lc($iaas//'');
}

# }}}
# prunable_keys - list the keys that can be pruned from a manifest and still be deployable {{{
sub prunable_keys {
	return @{$_[0]->_memoize( sub {
		my @keys = (qw(
			meta pipeline params bosh-variables bosh-configs kit genesis exodus compilation
		));
		if (!$_[0]->use_create_env) {
			# bosh create-env needs these, so we only prune them
			# when we are deploying via `bosh deploy`.
			push(@keys, (qw(
				resource_pools vm_types disk_pools disk_types networks azs vm_extensions
			)));
		}
		return \@keys;
	})};
}
# }}}
# _yaml_files - create genesis support yml files and return full ordered merge list {{{
sub _yaml_files {
	my ($self,$skip_eval) = @_;

	my @cc = $self->_cc_yaml_files($skip_eval);
	return (
		$self->_init_yaml_file(),
		$self->kit_files(1), # absolute
		@cc,
		$self->actual_environment_files(),
		$self->_cap_yaml_file(),
	);
}

# }}}
# }}}

1;

=head1 NAME

Genesis::Env::Configuration

=head1 DESCRIPTION

This module contains configuration management methods for Genesis environments,
including feature management, parameter lookups, and metadata access.

=head1 METHODS

=head2 features()

Returns the list of features (specified and derived) for the environment.

=head2 has_feature($feature)

Returns true if the environment requests the given feature.

=head2 params()

Gets all the values from the hierarchical environment.

=head2 defines($key)

Returns true if the given path is defined in the hierarchical environment parameters.

=head2 lookup($key, $default)

Looks up a value from the hierarchical environment.

=head2 lookup_unevaled($key, $default)

Looks up a value from the hierarchical environment without evaluating operators.

=head2 partial_manifest_lookup($key, $default)

Looks up a value from a best-effort merged manifest for this environment.

=head2 manifest_lookup($key, $default)

Looks up a value from a completely merged manifest for this environment.

=head2 last_deployed_lookup($key, $default)

Looks up values from the last deployment of this environment.

=head2 exodus_lookup($key, $default, $for)

Looks up Exodus data from the last deployment of this (or named) deployment.

=head2 director_exodus_lookup($key, $default, %opts)

Looks up Exodus data from the director that deploys this environment.

=head2 deployment_lookup($timestamp)

Looks up deployment details for a given timestamp, or lists deployment timestamps.

=head2 dereferenced_kit_metadata()

Gets kit metadata that has been filled with environment references.

=head2 vault_paths(%opts)

Gets the list of paths in the vault for this environment.

=head2 scale()

Returns the scale for the environment.

=head2 iaas()

Returns the IaaS type for the environment.

=head2 prunable_keys()

Lists the keys that can be pruned from a manifest and still be deployable.

=head2 _yaml_files($skip_eval)

Creates genesis support yml files and returns the full ordered merge list.

=cut