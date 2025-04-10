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
	$self->{complete} = 1;
	$self->{error} = $error || undef;
	return $self->{complete};
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

	# This routine allows the properties to be specified in simple string form,
	# then be parsed into the correct instructions for the CPI config.  The
	# properties are specified in the form of:
	#   [!]property_name[@alternate_lookup][:default_value|?][>config_path]
	#
	# The property_name is required, and assumed to be the lookup key in both the
	# 'bosh-configs.cpi' environment configuration, and the 'cpi.properties' section
	# of the OCFP configuration, and is also assumed to be the key under properties
	# in the CPI configuration.
	#
	# The '!' is used to specify that the property is a secret, and should be
	# entombed in the secrets vault.
	#
	# The alternative_lookup is used to specify a different key in the OCFP
	# configuration, and can be specified more than one by using separating them
	# with a comma. The first key that is found will be used.
	#
	# The default_value is used if the property is not found.  The default will
	# be used verbatim, so true, false and null will be their yaml equivalents,
	# so if you want them to be strings, you need to quote them.  Basically,
	# the default value should be a valid JSON value.
	#
	# The config_path is used to specify the path in the CPI configuration that
	# the property should be placed.  This is useful for nested properties, or
	# properties that have different names than the lookup key.

	# Process:  We will use $self->_lookup_cpi_config to get the value for each
	# property, except for the secrets (leave them as-is on the first pass).  We
	# first have to split out the alternative lookups and default values, and
	# storage locations.
	my (%config,%secrets) = ();
	for my $property (@properties) {
		my ($is_secret, $key, $alts, $default, $optional, $path) = 
			$property =~ /^(!?)([^\@:\?\>]+)(?:\@([^:\?\>]+))?(?:(?::([^>]+))|(\?))?(?:>(.+))?$/;
		$path //= $key;
		$default //= '';
		my @lookups = ($key, (split /,/, $alts//''));
		my $value = undef;
		my $iaas = $self->iaas;
		for my $lookup (@lookups) {
			# FIXME: Cannot delete a value by putting null in the env to delete it
			$value =
				$self->env->lookup("bosh-configs.cpi.$lookup") //
				$self->env->ocfp_config_lookup("cpi.$iaas.$lookup", undef);
			last if defined $value;
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

	# FIXME: We need to handle when the user has specified a property that is 
	#        not in the passed-in list.

	# Finally, unflatten the config hash
	return unflatten(\%config);
}

sub cpi_entombment_path_for {
	my ($self, $key, $value) = @_;
	my $prefix = $self->{credhub_prefix} // "genesis-entombments/";
	my $stub = 'cpi-config-property';
	my $secret_sha = substr(sha1_hex("$stub--$key--".$value),0,8);
	return "$prefix$stub--$key--$secret_sha";
}

1;

# vim - fdm=marker:foldlevel=1:ts=2:sts=2:sw=2:noet
