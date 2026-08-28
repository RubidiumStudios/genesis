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

	# The default clause may be empty -- `key:` and `key:>path` declare a
	# default of ''.  Absent, the group stays undef, which means required.
	my ($secret, $key, $alts, $default, $optional, $path) =
		$property =~ /^(!?)([^\@:\?\>]+)(?:\@([^:\?\>]+))?(?:(?::([^>]*))|(\?))?(?:>(.+))?$/;
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
		default  => $default,
		optional => $optional ? 1 : 0,
		secret   => $secret  ? 1 : 0,
		path     => $path // $key,
		lookups  => [$key, @alts],
	};
}

sub _entomb_if_needed {
	my ($self, $spec, $value) = @_;

	# Already a reference, so entombment has happened upstream -- doing it
	# again would store a pointer to a pointer.
	return $value if defined($value) && !ref($value) && $value =~ /^\(\(.*\)\)$/;
	return $value unless $spec->{secret};

	bail(
		"Cannot entomb CPI property #C{%s}: no value was found for it in ".
		"#C{bosh-configs.cpi} or the OCFP config, and an empty secret cannot ".
		"be stored.",
		$spec->{key}
	) if !defined($value) || (!ref($value) && $value eq '');

	my $credhub_path = $self->cpi_entombment_path_for($spec->{path}, $value);
	$self->{credhub_secrets}{$credhub_path} = $value;
	return "(($credhub_path))";
}

sub _resolve {
	my ($self, $spec, $routed) = @_;

	# When the operator addressed the property by its CPI path rather than
	# its key, that leaf is where the value is; otherwise sweep the names.
	my @names = defined($routed) ? ($routed) : @{$spec->{lookups}};

	# All operator names before any platform name: consulting both per
	# name lets an OCFP primary beat an operator alt.
	for my $name (@names) {
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

	my @specs = map {$self->_parse_property($_)} @properties;
	my (%by_key, %by_path);
	for my $spec (@specs) {
		$by_key{$_} = $spec for @{$spec->{lookups}};
		$by_path{$spec->{path}} = $spec;
	}

	# Flattened to leaves so a nested block can carry modelled and
	# unmodelled properties together, and each is judged on its own.
	my $raw = Genesis::flatten({}, '', $self->env->lookup_unevaled('bosh-configs.cpi') // {});

	my (%routed, %extra, %unmodelled_under, @path_routed);
	for my $leaf (CORE::keys %$raw) {
		# flatten escapes a literal dot as ~, and that escape does not
		# survive a round trip, so the quoted form is refused outright.
		bail(
			"Cannot set #C{%s} in #C{bosh-configs.cpi}: a quoted key holding a ".
			"literal dot is not supported -- nest it instead.",
			$leaf =~ s/~/./gr
		) if $leaf =~ /~/;

		my $parent = $leaf =~ /^(.*)\.[^.]*$/ ? $1 : '';
		my $spec = $by_key{$leaf} // $by_path{$leaf};
		if ($spec) {
			# Names the two leaves rather than the key and the path: a key
			# colliding with an @alt is the same fault, described wrongly.
			if (my $first = $routed{$spec->{path}}) {
				bail(
					"CPI property #C{%s} is set more than one way in ".
					"#C{bosh-configs.cpi}: #C{%s} and #C{%s} both address it ".
					"-- set only one.",
					$spec->{key}, sort($first, $leaf)
				);
			}
			$routed{$spec->{path}} = $leaf;
			push @path_routed, [$leaf, $parent, $spec] unless $by_key{$leaf};
		} else {
			$extra{$leaf} = 1;
			$unmodelled_under{$parent} = 1;
		}
	}

	# The path form is only worth its rename exposure in a block that also
	# carries unmodelled leaves; alone, the key addresses the same property.
	for my $route (sort {$a->[0] cmp $b->[0]} @path_routed) {
		my ($leaf, $parent, $spec) = @$route;
		next if $unmodelled_under{$parent};
		warning(
			"#C{bosh-configs.cpi.%s} sets a modelled CPI property by its CPI ".
			"path; #C{%s} names the same property and keeps working if the ".
			"CPI renames it.",
			$leaf, $spec->{key}
		);
	}

	my %config;
	for my $spec (@specs) {
		# _resolve's found flag governs whether the platform was consulted,
		# not whether there is a value: a null clears, and lands here.
		my ($value) = $self->_resolve($spec, $routed{$spec->{path}});
		if (!defined $value) {
			next if $spec->{optional};
			bail(
				"CPI property #C{%s} is required: no value was found for it in ".
				"#C{bosh-configs.cpi} or the OCFP config, and the kit declares ".
				"no default. Set it, or have the kit declare #C{%s:} for an ".
				"empty default or #C{%s?} to omit it when unset.",
				$spec->{key}, $spec->{key}, $spec->{key}
			) unless defined $spec->{default};
			$value = eval {JSON::PP->new->utf8->allow_nonref->decode($spec->{default})};
			$value = $spec->{default} if $@;
		}
		$config{$spec->{path}} = $self->_entomb_if_needed($spec, $value);
	}

	for my $leaf (CORE::keys %extra) {
		my ($value) = $self->env->lookup_entombed_self("bosh-configs.cpi.$leaf");
		$config{$leaf} = $value if defined $value;
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
