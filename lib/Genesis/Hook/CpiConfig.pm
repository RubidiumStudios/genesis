package Genesis::Hook::CpiConfig;
use strict;
use warnings;

use Genesis;

use IPv4;
use JSON::PP;
use POSIX qw(round);
use Digest::SHA qw/sha1_hex/;

use parent qw(Genesis::Hook);

# TODO: Implement the flyweight pattern to cache cpi config.

sub init {
	my ($class, %ops) = @_;
	my $self = $class->SUPER::init(%ops);
	$self->{cpi_config} = {};
	$self->{credhub_secrets} = {};
	return $self;
}

sub done {
	my ($self, $config, $error) = @_;

	if ($config) {
		# The contents of the cpi config must be converted to a yaml string
		my $filename = $self->env->workdir . '/cpi-config.yaml';
		save_to_yaml_file($config, $filename);
		$self->{contents} = slurp($filename);
	} else {
		$self->{contents} = undef;
	}
	$self->{error} = $error || undef;
	return $self->{complete} = 1;
}

sub results {
	# The results should be a hashref with the following keys:
	#   content - The contents of the cpi config as a yaml string
	#   credhub_secrets - A hashref of the secrets that need to be added to credhub
	#   error - An error message if there was an error during processing
	my $self = shift;
	return (wantarray ? () : undef) unless $self->completed;
	my $results = {
		content => $self->{contents},
		credhub_secrets => $self->{credhub_secrets},
		error => $self->{error}
	};
	return wantarray ? @$results{qw/content credhub_secrets error/} : $results;
}

sub build_cpi_config_for_iaas {
	my ($self, %configs) = @_;

	my $iaas = $self->iaas;
	bail (
		"Unsupported IaaS: %s",
		$iaas
	) unless exists $configs{$iaas};
	my $config = $configs{$iaas};
	$config = $config->() if ref $config eq 'CODE';

	return {
		cpis => [
			{
				name => $self->env->cpi_name,
				type => $iaas,
				properties => $config
			}
		],
	}
}

sub _parse_property {
	my ($self, $property) = @_;

	my ($secret, $key, $alts, $default, $optional, $path) =
		$property =~ /^(!?)([^\@:\?\>]+)(?:\@([^:\?\>]+))?(?:(?::([^>]+))|(\?))?(?:>(.+))?$/;
	bail(
		"Invalid CPI config property specification '%s' in kit cpi-config hook "
		. "(expected [!]key[\@alt][:default|?][>path])",
		$property
	) unless defined $key;

	# The lookup order is the key then its alts; `path` is where the value
	# lands, and defaults to the key when the two vocabularies agree.
	my @alts = split(/,/, $alts // '');
	return {
		key      => $key,
		alts     => \@alts,
		default  => $default // '',
		optional => $optional ? 1 : 0,
		secret   => $secret  ? 1 : 0,
		path     => $path // $key,
		lookups  => [$key, @alts],
	};
}

sub _resolve {
	my ($self, $spec) = @_;

	# All operator names before any platform name: consulting both per
	# name lets an OCFP primary beat an operator alt.
	for my $name (@{$spec->{lookups}}) {
		# Entombed-self, so an env-file (( vault )) arrives already entombed.
		# Presence, not definedness: a null clears the OCFP value.
		my ($value, $found) = $self->env->lookup_entombed_self("bosh-configs.cpi.$name");
		return ($value, 1) if $found;
	}

	my $iaas = $self->iaas;
	for my $name (@{$spec->{lookups}}) {
		my ($json, $found) = $self->env->ocfp_config_lookup("cpi.$iaas.$name", undef);
		next unless $found;
		my $value = eval {JSON::PP->new->utf8->allow_nonref->decode($json)};
		return (($@ ? $json : $value), 1);
	}

	return (undef, 0);
}

sub gather_properties {
	my ($self, @properties) = @_;

	# Process:  We will use $self->_lookup_cpi_config to get the value for each
	# property, except for the secrets (leave them as-is on the first pass).  We
	# first have to split out the alternative lookups and default values, and
	# storage locations.
	# %config is keyed by output path, but the manual-override pass below is
	# keyed by source key. Those agree only while every property leaves >path
	# unset. %consumed records the source keys this map read, so the override
	# pass can tell "the kit does not model this key" from "the kit read this
	# key and emitted it somewhere else".
	my (%config,%secrets,%consumed) = ();
	for my $property (@properties) {
		my $spec = $self->_parse_property($property);
		my ($is_secret, $key, $default, $optional, $path) =
			@{$spec}{qw/secret key default optional path/};
		my @lookups = @{$spec->{lookups}};
		$consumed{$_} = 1 for @lookups;
		my $value = undef;
		my $iaas = $self->iaas;
		for my $lookup (@lookups) {
			($value, my $src) = $self->env->lookup("bosh-configs.cpi.$lookup");
			last if $src;
			if (!defined $value) {
				# If we didn't find it in the environment, lets try the OCFP config
				my ($json,$src) = $self->env->ocfp_config_lookup("cpi.$iaas.$lookup",undef);
				next unless $src;
				$value = eval {
					# If the value is a JSON string, decode it
					JSON::PP->new->utf8->allow_nonref->decode($json);
				};
				$value = $json if $@;
				last;
			}
		}
		if (!defined $value) {
			next if ($optional);

			bail(
				"Missing default for CPI config value for %s, and none found in environment",
				$key
			) unless defined $default;

			# Lets try to parse the default value as JSON
			eval {
				$value = JSON::PP->new->utf8->allow_nonref->decode($default);
			};
			my $err = $@;
			$value = $default if ($err);
		}

		if ($is_secret) {
			my $credhub_path = $self->cpi_entombment_path_for($path,$value);
			$self->{credhub_secrets}{$credhub_path} = $value;
			$value = "(($credhub_path))";
		}

		$config{$path} = $value;
	}

	# Now we need to add in any manual overrides for keys that don't exist in
	# in the kit, but the environment wants to set.
	my $overrides = $self->env->lookup_unevaled('bosh-configs.cpi');
	for my $override (keys %$overrides) {

		# If we already got this value, skip it.  Checking %consumed as well as
		# %config matters as soon as a property declares a >path: the value is
		# then filed under the path, so the source key is absent from %config
		# and the operator's own setting gets copied back in at the top level
		# -- unevaluated (a spruce operator reaches the director as a literal
		# and is rejected as a BOSH variable name) and un-entombed (a '!'
		# secret lands in cleartext beside the credhub reference that was
		# supposed to replace it).
		next if exists $config{$override} || $consumed{$override};

		my $value = $overrides->{$override};
		# FIXME: Need to handle hashes that may contain vault references
		if (!ref($value) && $value =~ /^\(\( ?vault ([^"]* )?"(.*)" ?\)\)$/) {
			# This is a vault reference, so we need to entomb it
			my $vault_base = $1; # TODO: Do we need to resolve this or is the relative path sufficient?
			$value = $self->env->lookup("bosh-configs.cpi.$override");
			my $path = $self->cpi_entombment_path_for($override,$value);
			$self->{credhub_secrets}{$path} = $value;
			$value = "(($vault_base $path))";
		}

		if (defined $value) {
			$config{$override} = $value;
		} else {
			delete($config{$override});
		}
	}

	# Finally, unflatten the config hash
	return unflatten(\%config);
}

sub cpi_entombment_path_for {
	# Both callers pass an output path, not a source key: the CPI-side
	# address, which is structural and may carry dots or array indices.
	my ($self, $path, $value) = @_;
	# This is different between being deployed as a director's default cpi config
	# and a child cpi config.  They always have to be absolute paths, so we need
	# to prefix them with the credhub prefix.

	# The PostDeploy hook, which calls this for deploying a director's cpi will
	# always pass in the prefix, whch is '/cpi-config/properties/'.
	# The child cpi config will not have the prefix, so we need to add it based
	# on the environment's credhub prefix.
	my $prefix = $self->{credhub_prefix} // $self->env->cpi_credhub_base;
	my $stub = 'cpi-config-property';
	my $secret_sha = substr(sha1_hex("$stub--$path--".$value),0,8);

	# BOSH resolves ((name.subkey)) by splitting the reference on its first dot,
	# so a nested property path such as pve.host would have the director ask the
	# config server for a truncated credential name and get a 404 back. Flatten
	# anything outside [A-Za-z0-9_-] so the stored name and the manifest
	# reference agree and carry no dot -- array indices such as nics[0].ip need
	# it too.  The sha still covers the original path, so two paths that flatten
	# alike keep distinct entries.
	(my $safe_name = $path) =~ s/[^A-Za-z0-9_-]/_/g;

	return "$prefix$stub--$safe_name--$secret_sha";
}

1;

# vim - fdm=marker:foldlevel=1:ts=2:sts=2:sw=2:noet
