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

sub gather_properties {
	my ($self, @properties) = @_;

	# Process:  We will use $self->_lookup_cpi_config to get the value for each
	# property, except for the secrets (leave them as-is on the first pass).  We
	# first have to split out the alternative lookups and default values, and
	# storage locations.
	my (%config,%secrets) = ();
	for my $property (@properties) {
		my ($is_secret, $key, $alts, $default, $optional, $path) =
			$property =~ /^(!?)([^\@:\?\>]+)(?:\@([^:\?\>]+))?(?:(?::([^>]+))|(\?))?(?:>(.+))?$/;
		bail(
			"Invalid CPI config property specification '%s' in kit cpi-config hook "
			. "(expected [!]key[\@alt][:default|?][>path])",
			$property
		) unless defined $key;
		$path //= $key;
		$default //= '';
		my @lookups = ($key, (split /,/, $alts//''));
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

		# If we already got this value, skip it
		next if exists $config{$override};

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
	my ($self, $key, $value) = @_;
	# This is different between being deployed as a director's default cpi config
	# and a child cpi config.  They always have to be absolute paths, so we need
	# to prefix them with the credhub prefix.

	# The PostDeploy hook, which calls this for deploying a director's cpi will
	# always pass in the prefix, whch is '/cpi-config/properties/'.
	# The child cpi config will not have the prefix, so we need to add it based
	# on the environment's credhub prefix.
	my $prefix = $self->{credhub_prefix} // $self->env->cpi_credhub_base;
	my $stub = 'cpi-config-property';
	my $secret_sha = substr(sha1_hex("$stub--$key--".$value),0,8);

	# BOSH resolves ((name.subkey)) by splitting the reference on its first dot,
	# so a nested property key such as pve.host would have the director ask the
	# config server for a truncated credential name and get a 404 back. Flatten
	# anything outside [A-Za-z0-9_-] so the stored name and the manifest
	# reference agree and carry no dot. The sha still covers the original key,
	# so two keys that flatten alike keep distinct paths.
	(my $safe_key = $key) =~ s/[^A-Za-z0-9_-]/_/g;

	return "$prefix$stub--$safe_key--$secret_sha";
}

1;

# vim - fdm=marker:foldlevel=1:ts=2:sts=2:sw=2:noet
