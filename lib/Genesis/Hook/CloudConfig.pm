package Genesis::Hook::CloudConfig;
use strict;
use warnings;

use Genesis;
use Genesis::Hook::CloudConfig::LookupRef;
use Genesis::Hook::CloudConfig::LookupNetworkRef;
use Genesis::Hook::CloudConfig::LookupSubnetRef;
use IPv4;
use POSIX qw(round);

use parent qw(Genesis::Hook);

# FIXME: What happens if the subnets are restricted to a specific list of AZs in the env file.

# Constants {{{
use constant {
	VM_TYPE          => 'vm_type',
	VM_EXTENSION     => 'vm_extension',
	DISK_TYPE        => 'disk_type',
	NETWORK          => 'network',
	FIRST_SORT_TOKEN => '0000',
	LAST_SORT_TOKEN  => "zzzz",
};

# }}}

# Class Overrides {{{
# init - Initializes the CloudConfig hook, injecting the common properties {{{

my %cloud_configs = ();

sub init {
	my ($class, %opts) = @_;
	$class->check_for_required_args(\%opts, qw/env/);
	my $env = $opts{env};
	bail(
		"Create-env environments do not have deployment cloud configs,as there is ".
		"no director to upload them to."
	) unless $class->_can_build_cloud_config($env);

	my $purpose = $opts{purpose} // $ENV{GENESIS_CLOUD_CONFIG_SUBTYPE};
	my $basename = $opts{basename} // join('.', $env->name, $env->type);
	my $id = join('@', $purpose ? ($basename, $purpose) : ($basename));

	# Set the AZ prefix for the environment (if needed)
	my $az_prefix = $env->name . '-z';

	# Return cached object if it exists
	return $cloud_configs{$id} if ($cloud_configs{$id});

	my $obj = $class->SUPER::init(
		%opts, basename => $basename, id => $id, az_prefix => $az_prefix, contents => {}
	);

	$obj->{overrides} = {
		environment => $env->env_config_overrides('cloud'),
		director    => $env->director_config_overrides('cloud'),
	};

	$obj->{network} //= $obj->_get_bosh_network_data();
	if ($env->is_ocfp) {
		$obj->{ocfp_config} = $env->ocfp_config_lookup(['net','vpc']);
	}

	return $cloud_configs{$id} = $obj;
}

# }}}
# done - Marks the CloudConfig hook as completed, and sets the contents {{{
sub done {
	my ($self, $contents) = @_;

	# Validate that we received a proper config hashref
	bail(
		"CloudConfig hook must return a hashref containing the cloud config - got %s",
		ref($contents) || 'scalar value'
	) unless ref($contents) eq 'HASH';

	# Check validity of the network config, upgrading multiple subnets using a
	# single CIDR range into a Logical Subnet Amalgamation (LSA) definition if
	# needed.

	# RISK: This will change the network config, so if any hook perform method
	#       does stuff with the network config after calling `done`, the subnets
	#       will have been converted to LSAs, and the hook will not be able to
	#       access the original subnets.
	$self->_process_network_subnets($contents->{networks});

	# Force name to be sorted first
	my $sort_name_first = FIRST_SORT_TOKEN.'name'.FIRST_SORT_TOKEN;
	my $sort_cloud_properties_last = LAST_SORT_TOKEN.'cloud_properties'.LAST_SORT_TOKEN;

	my $flat_contents = flatten({}, '', $contents);
	foreach my $k (keys %$flat_contents) {
		if ($k =~ /\.name$/) {
			$flat_contents->{$k =~ s/name$/$sort_name_first/r} = delete($flat_contents->{$k});
		} elsif ($k =~ /\.cloud_properties\./) {
			$flat_contents->{$k =~ s/\.cloud_properties\./.$sort_cloud_properties_last./r} = delete($flat_contents->{$k});
		}
	}
	$contents = unflatten($flat_contents);

	my $filename = $self->env->workdir . "/cloud-config-".$self->{id}.".yml";
	save_to_yaml_file($contents, $filename);
	$contents = slurp($filename)
		=~ s/\b${sort_name_first}:/name:/gr 
		=~ s/\b${sort_cloud_properties_last}:/cloud_properties:/gr
		=~ s/\n([^ -])/\n\n$1/gmr;
	unlink($filename);
	$self->{contents} = $contents;

	return $self->SUPER::done();
}

# }}}
# results - Returns the contents of the cloud config {{{
sub results {
	trace('called results before hook completed') unless $_[0]->completed;
	return undef unless $_[0]->completed; # Should this be an error?
	return wantarray
		? ($_[0]->{contents}, $_[0]->{network})
		: {config => $_[0]->{contents}, network => $_[0]->{network}};
}

# }}}
# _can_build_cloud_config - Returns whether the cloud config can be built for the environment {{{
sub _can_build_cloud_config {
	my ($class, $env) = @_;
	!($env->use_create_env);

}

# }}}
# }}}

# Accessors {{{
sub basename { return shift->{basename}; }
sub contents { return shift->{contents}; }

# }}}

# Public Methods {{{
# name_for - Returns a name for components of the cloud config based on the basename and the provided arguments {{{
sub name_for {
	return join '.', shift->{basename}, join('-', @_);
}

# }}}
# for_scale - Returns the value for a given scale from a map, or a default value if not found {{{
sub for_scale {
	my ($self, $map, $default) = @_;
	my $scale = $self->scale;
	return $map->{$scale} // $default;
}

# }}}
# for_iaas - Returns the value for a given IaaS from a map, or a default value if not found {{{
sub for_iaas {
	my ($self, $map, $default) = @_;
	my $iaas = $self->iaas;
	return $map->{$iaas} // $default;
}

# }}}
# lookup_ref - Returns a lookup reference for a given path {{{
sub lookup_ref {
	my ($self, $paths, $default) = @_;
	return Genesis::Hook::CloudConfig::LookupRef->new($paths, $default);
}

# }}}
# subnet_reference - Returns a reference to a subnet value that can be retrived per subnet {{{
sub network_reference {
	my $self = shift;
	return Genesis::Hook::CloudConfig::LookupNetworkRef->new(@_);
}

# }}}
# subnet_reference - Returns a reference to a subnet value that can be retrived per subnet {{{
sub subnet_reference {
	my $self = shift;
	return Genesis::Hook::CloudConfig::LookupSubnetRef->new(@_);
}

# }}}
# build_cloud_config - Builds the cloud config for the environment {{{
sub build_cloud_config { 
	my ($self,$config) = @_;
	# this is just a wrapper as the config is already assembled, but is included
	# so that if post-processing is needed, it can be done here without changing
	# the kits.
	return $config;
}

# }}}
# build_cpi_azs - Builds the cpi-specific AZs for the environment {{{
sub build_cpi_azs {
	my ($self, %options) = @_;
	# This will build the cpi-specific AZs for environments that have a custom CPI
	# enabled.  Each AZ will be a shadow of the parent's base AZs but will use
	# the deployment names and the deployment's CPI.

	return () unless $self->env->cpi_enabled;

	my $parent_azs = $self->get_available_azs;
	my @azs = ();
	for my $az_name (sort keys %$parent_azs) {
		my $az_defn = $parent_azs->{$az_name};
		my $idx = $az_defn->{index} # This is the index of the az, we currently do not populate it
			// ($az_name =~ m/[^0-9]([0-9]*)$/)[0]
			|| ($az_defn->{name} =~ m/[^0-9]([0-9]*)$/)[0];
		my $config = $self->_az_definition_for(
			$az_defn, %options, name => $self->{az_prefix} . $idx
		);
		push @azs, $config;
		$self->_add_cpi_to_network_az($az_name, $config->{name});
	}

	return (azs => \@azs);
}

# }}}
# _az_definition_for - Returns the definition for a given AZ {{{
sub _add_cpi_to_network_az {
	my ($self, $az_name, $cpi_az_name) = @_;
	my $network = $self->network;
	$network->{azs}{$az_name}{for_cpi}{$self->cpi_name} = $cpi_az_name
}

# }}}
# relinquish_networks - Relinquishes the named network(s) {{{
sub relinquish_networks {
	my ($self, @networks) = @_;
	my $network = $self->network;
	for (@networks) {
		my $network_id = $self->name_for('net', $_);
		delete($network->{subnets}{$_}{claims}{$network_id})
			for keys %{ $network->{subnets} };
	}
}

# }}}
# network_definition - Returns the definition for a given network {{{
sub network_definition {

	# This one is special compared to vm_type_definition, vm_extension_definition,
	# and disk_type_definition.  It will query the exodus data of the deploying
	# BOSH director to get the network definition, as well as what is already
	# allocated, so that allocations can be grown and shrunk as needed.
	#
	# It will also determine the base containing network and subnets, to figure
	# out what is available for allocation, what AZs are available, dns, gateway,
	# etc.
	#
	# It can support a common network definition per network, or support subnets.
	#
	# It also supports definition filters for ocfp and non-ocfp deployments, which
	# generally support different networking allocations.
	#
	# Range of networks will be dynamically determined based on the master range,
	# the existing allocations, and the static values (which can be outside the
	# allocation mask-generated range(s)).

	my ($self, $target, %rules) = @_;
	my $strategy = delete($rules{strategy}) // 'generic';

	# FIXME: Should this just die if the strategy does not match?
	if (($strategy eq 'ocfp') xor $self->env->is_ocfp) {
		# This is an ocfp deployment, but the network is not an ocfp network (or vice versa)
		return ();
	}

	my $network_id = $self->name_for('net', $target);
	my $config = {
		name => $network_id,
		type => 'manual',
	};
	# FIXME: We also need to support 'VIP' networks.

	# This allows kit-provided strategies to be provided.
	my $strategy_method = "_build_${strategy}_network_definition";
	if ($self->can($strategy_method)) {
		# $config is passed by reference, so it can get modified
		$self->$strategy_method($target, $config, %rules);
	} else {
		bail(
			'Network definition strategy %s is not supported by the cloud config hook',
			$strategy
		);
	}

	#TODO: Before we return, we must store a local copy in the object for
	#reference to build other parts of the cloud config.
	$self->update_network($target, $config);

	return $config;
}

# }}}
# _build_generic_network_definition - Builds a generic network definition {{{
sub _build_generic_network_definition {
	my ($self, $target, $config, %options) = @_;
	# This is the generic network definition, which is used for classic Genesis deployments
	# that do not use OCFP, and do not have any special network requirements.
	bug(
		"Generic network definition building is not yet implemented"
	);
}

# }}}
# _available_ocfp_network_models - Returns the available OCFP network models {{{
sub _available_ocfp_network_models {
	# Overridable in hook files to allow kits to provide their own
	return qw(dynamic_subnets subnets);
}

# }}}
# _build_ocfp_network_definition - Builds an OCFP network definition {{{
sub _build_ocfp_network_definition {
	my ($self, $target, $config, %options) = @_;
	# This is the OCFP network definition, which is used for OCFP deployments.

	my $strategy = 'ocfp';

	# OCFP supports dynamic subnets as a network model substrategy, and may
	# support others in the future.  Lets make sure we only have one (although
	# we could support multiple (ie for VIP networks), it would be a bit more
	# complex).
	my @requested_network_models = grep {exists $options{$_}} $self->_available_ocfp_network_models;
	bail(
		'Network definition for %s can only have one network model, but found %d: %s',
		$target, scalar(@requested_network_models), join(', ', @requested_network_models)
	) if (scalar(@requested_network_models) > 1);
	bail(
		'Network definition for %s must have one of the following network models: %s',
		$target, join(', ', $self->_available_ocfp_network_models)
	) unless @requested_network_models;

	my $network_model_builder = "_build_${strategy}_network_model_"
		. $requested_network_models[0];
	bug(
		"Network model %s is not supported for OCFP network definitions",
		$requested_network_models[0]
	) unless $self->can($network_model_builder);

	# Call the network model builder to build the network definition
	return $self->$network_model_builder(
		$target, $config, %options
	);
}

# }}}
# _build_ocfp_network_model_dynamic_subnets - Builds an OCFP network definition with dynamic subnets {{{
sub _build_ocfp_network_model_dynamic_subnets {
	my ($self, $target, $config, %options) = @_;

	my $definition = $options{dynamic_subnets};

	# OCFP Network Range Calculations
	# *-mgmt -
	#   - Owns .0 to .31 of each subnet
	#   - bosh is deployed to 5th
	#   - vault is deployed to 6th
	#   - jumpbox is deployed to 7th
	#   - concourse web is 8th ip
	#   - prometheus is 9th ip
	#   - shield is 10th ip
	#   - doomsday/ocfp-ui is 11th ip
	#   - everything else is dynamic
	#
	#   To Facilitate this, we need the following in ocfp config:
	#   - vpc.subnets.<subnet>.reserved-offsets ie '0-5,7-10'
	#   - vpc.subnets.<subnet>.available-offsets: ie '12-254' or '31-n' n means
	#     last in cidr block -- if not supplied, will assume all available
	#     that are not reserved (generally we do NOT want this)
	#     we technically only need one of these, but both are supported
	#
	#   Note: The 'vpc' path was later changed to 'net' in later versions of the
	#	  OCFP configuration, so we support both paths for backwards compatibility.
	#
	# *-ocfp - Owns .32 to .last of each subnet

	# This will dynamically determine the subnets based on the ocfp
	# configuration in vault, under
	# /secrets/{params.ocfp_config_path}.{env-name}/{mgmt|ocfp}/bosh/iaas/subnets/<name>/<id>
	# with `...ips.[mgmt|ocfp].reserved` for the reserved list.

	# Additional OCFP feature under Dynamic Subnets: Logical Subnet Amalgamation
	#  - If subnets have the same range (which is not allowed by BOSH), we will
	#    combine them into a single subnet with the same range, and allocate each
	#    subnet's static IPs from the same range, dynamically determining the reserved
	#    IP ranges.
	#  - The subnets that use the same range must also have the same gateway, and amalgamate
	#    the DNS servers into a single list with no duplicates.
	#  - The AZ calculation has to also take joined subnets into account, and cannot use different subnet ids,
	#    (we ignore the subnet id, and just use the network id).  

	my $strategy = 'ocfp:dynamic_subnets';
	my $network_id = $config->{name};
	my $subnets = $self->_filter_subnets($definition->{subnets});
	$config->{subnets} = [];

	# We only use the ocfp-* subnets for the network definition
	my $ocfp_subnet_prefix = $self->env->ocfp_subnet_prefix;
	my @ocfp_subnet_names = sort grep {/^${ocfp_subnet_prefix}-/} keys %$subnets;
	bail(
		'No ocfp-* subnets found in the ocfp configuration for network %s',
		$target
	) unless @ocfp_subnet_names;

	my $allocation = delete($definition->{allocation});
	my %vms_per_subnet = ();
	if (defined $allocation->{total_size}) {
		my $vm_count = $allocation->{total_size};
		my $total_subnets = scalar(@ocfp_subnet_names);
		my $per_subnet_count = round($vm_count / $total_subnets);
		my $remaining = $vm_count % $total_subnets;
		for my $subnet_name (@ocfp_subnet_names) {
			$vms_per_subnet{$subnet_name} = $per_subnet_count;
			$vms_per_subnet{$subnet_name}++ if $remaining-- > 0;
		}
	} else {
		my $vm_count = $allocation->{size} // 0;
		$vm_count = 2**(32 - $1) if $vm_count =~ m#^/(\d+)$#;
		for my $subnet_name (@ocfp_subnet_names) {
			$vms_per_subnet{$subnet_name} = $vm_count;
		}
	}
	my $statics = $allocation->{statics} // 0; # Does not include the reserved ips based on network name (ie bosh_ip, vault_a, vault_b, etc)
	$statics = 2**(32 - $1) if $statics =~ m#^/(\d+)$#;

	# Get existing allocations from exodus data
	my $existing_allocations = $self->_get_existing_allocations(); # Different for director and non-drector deployments; prototyping in director

	for my $subnet_name (@ocfp_subnet_names) {
		my $subnet = $subnets->{$subnet_name};
		my $vm_count = $vms_per_subnet{$subnet_name} // 0;
		my $full_range = IPv4->new($subnet->{cidr_block});
		my ($available, $reserved) = $self->_get_subnet_ranges($subnet);

		# Remove existing allocations from available range that are not for the
		# target network
		for my $claiming_network (keys %$existing_allocations) {
			next if ($network_id eq $claiming_network);
			my $alloc = $existing_allocations->{$claiming_network}{$subnet_name};
			$available -= $alloc if ($alloc);
		}

		# Find any existing allocations, but ignore those explicitly reserved
		my $existing = $existing_allocations->{$network_id}{$subnet_name} // IPv4->new();
		$existing -= $reserved if $existing && $reserved;

		# Compare existing and desired allocations, and adjust as needed
		my $allocated_range = $self->_calculate_subnet_allocation(
			$target,
			$available,
			$existing,
			$vm_count
		);  
		$reserved += $full_range->subtract($allocated_range);

		# TODO: We currently just shove statics into the front of the range, but
		# this doesn't account for ips already in use.  We can either actively
		# check for ips in the network range against the bosh deployments, or we
		# allow users to override the statics with a list of offsets to use
		# rather than just a count or mask.(ie 0-3,9) maybe even negative for
		# adding to the end? (-1--3)
		bail(
			'More static IPs requested (%d) than the allocation for the %s subnet for '.
			'network %s allows (%d)',
			$statics, $subnet_name, $target, $vm_count
		) if ($statics > $vm_count);
	
		my $static_range = $self->_calculate_static_allocation(
			$target,
			$allocated_range,
			$statics
		);

		# Check for reserved_ips and "unreserve" them from the reserved range
		# and put them into the static list
		my $reserved_ips = IPv4->new(
			map  {$subnet->{'reserved-ips'}{$_}}
			grep {$_ =~ m/${target}_ip/}
			keys %{$subnet->{'reserved-ips'}//{}}
		);
		while (<$reserved_ips>) {
			$static_range += $_;
			$reserved     -= $_;
		}

		# Standardize the range using IPv4 library for consistent CIDR expression
		# Range must be one cohesive CIDR block.
		my $range = IPv4->new($subnet->{cidr_block});
		my @spans = $range->spans;
		bail(
			"Subnet %s for network %s is not a single CIDR block, but has multiple ranges: %s",
			$subnet_name, $target, join(', ', map {"$_"} @spans)
		) if @spans > 1;
		my @cidrs = $spans[0]->cidrs;
		bail(
			"Subnet %s for network %s is not a single CIDR block, but has multiple CIDRs: %s",
			$subnet_name, $target, join(', ', map {"$_"} @cidrs)
		) if @cidrs > 1;
		my $standardized_range_cidr = $cidrs[0];

		my $fields = {
			az => $self->lookup_az($subnet->{az}), # TODO: Needs to change if we support multiple AZs
			range => $standardized_range_cidr,
			gateway => $subnet->{gateway},
			dns => ref($subnet->{dns}) eq 'ARRAY' ? $subnet->{dns} : [$subnet->{dns}],
			reserved => [map {$_->range} $reserved->spans],
			cloud_properties_for_iaas => $definition->{cloud_properties_for_iaas},
			($static_range->size
				? (static => [map {$_->range} $static_range->spans])
				: ()
			)
		};

		my $subnet_config = $self->_subnet_definition(
			$target, $subnet_name, $fields, $strategy
		);

		push @{$config->{subnets}}, $subnet_config if $full_range->size > $reserved->size;
	}
	

	return 1;
}

# }}}
# network - Returns the network definitions for the environment {{{
sub network {
	my ($self) = @_;

	# TODO: Do we need to build an adapter between the raw exodus data and the
	# network data structure we use internally?  Ideally, we don't want to do
	# that.
	$self->{network} //= $self->_get_bosh_network_data();
}

# }}}
# update_network - Updates the network definitions for the environment {{{
sub update_network {
	my ($self, $target, $config) = @_;
	my $network = $self->name_for('net', $target);

	# clear out any existing allocations for this network
	delete($_->{claims}{$network}) for (values %{$self->network->{subnets}});

	# Calculate and store the new allocations
	for my $subnet (@{$config->{subnets}}) {
		my $subnet_id = $subnet->{name};
		my $range     = $subnet->{range};
		$self->network->{subnets}{$subnet_id}{claims}{$network} = IPv4
			->new($range)
			->subtract(@{$subnet->{reserved}})
			->range;
	}
}

# }}}
# get_allocated_networks - Returns the allocated networks for the environment {{{
sub get_allocated_networks {
	my ($self) = @_;
	my $network_allocations = {};
	for my $subnet (keys %{$self->network->{subnets}}) {
		my $subnet_az = $self->network->{subnets}{$subnet}{az};
		for my $network (keys %{$self->network->{subnets}{$subnet}{claims}}) {
			$network_allocations->{$network}{$subnet} = {
				allocated => $self->network->{subnets}{$subnet}{claims}{$network},
				az => $subnet_az
			};
		}
	}
	return $network_allocations;
}

sub lookup_az {
	my ($self, $az) = @_;
	bail(
		"No availability zones available; you may need to run a deploy on the ".
		"#M{%s} BOSH director to update its network information.",
		$self->env->bosh->alias
	) unless keys %{$self->network->{azs}};
	# This code is autoviving the azs hash, so we need to check for the key
	# TBD: Should we check for the full name as well in all the existing azs?
	my $base_az = $az;
	if (! exists $self->network->{azs}{$az}) {
		# Find the base_az that contains the given az as a name
		$base_az = (grep {$_->{name} eq $az} values %{$self->network->{azs}})[0];
		bail(
			"Availability zone %s not found in the available AZs for the network",
			$az
		) unless $base_az;
	}

	my $az_name = $self->network->{azs}{$base_az}{for_cpi}{$self->cpi_name}
		if $self->cpi_enabled;
	return $az_name//$self->network->{azs}{$base_az}{name}; # Director cpi is default
}

# }}}
# get_available_azs - Returns the available AZs for network namespace {{{
#
sub get_available_azs {
	return $_[0]->network->{azs};
}

# }}}
# get_available_azs_in_network - Returns the available AZs for a given network {{{
sub get_available_azs_in_network {
	my ($self, $target) = @_;
	my $allocated_subnets = $self
		->get_allocated_networks
		->{$self->name_for('net',$target)};
	return [
		(uniq sort map {$allocated_subnets->{$_}{az}//($allocated_subnets->{$_}{azs}->@*)} keys %$allocated_subnets)
	];
}

# }}}
# get_network_size - Returns the size of the network for the given target {{{
sub get_network_size {
	my ($self, $target, @filters) = @_;

	my $network = $self->get_allocated_networks->{$self->name_for('net',$target)};
	my $size = 0;
	my %valid_azs = ();

	if (@filters) {
		for my $az (@filters) {
			$valid_azs{$az} = 1;
			my $full_az_name = $self->lookup_az($az);
			$valid_azs{$full_az_name} = 1 if $full_az_name;
		}
	} else {
		$valid_azs{$network->{$_}{az}} = 1 for keys %$network;
	}

	for my $subnet (values %{$network}) {
		$size += IPv4->new($subnet->{allocated})->size if $valid_azs{$subnet->{az}};
	}
	return $size;
}

# }}}
# subnets - Returns the subnets for the network {{{
sub subnets {
	my ($self) = @_;
	return $self->{subnets} ||= $self->env->ocfp_config_lookup(['net.subnets','vpc.subnets']);
}

# }}}
# network_cloud_properties_for_iaas - Returns the cloud properties for a given network and cpi {{{
sub network_cloud_properties_for_iaas {
	return shift->_cloud_properties_for_iaas('network', @_);
}

# }}}
# vm_type_definition - Returns the definition for a given vm type {{{
sub vm_type_definition {
	return shift->_config_definition(VM_TYPE, 'vm', @_);
}

# }}}
# vm_extension_definition - Returns the definition for a given vm extension {{{
sub vm_extension_definition {
	return shift->_config_definition(VM_EXTENSION, 'vmx', @_);
}

# }}}
# disk_type_definition - Returns the definition for a given disk type {{{
sub disk_type_definition {
	return shift->_config_definition(DISK_TYPE, 'disk', @_);
}

# }}}
# }}}
#
# Private Methods {{{
# _config_definition - Returns the definition for a given config type {{{
sub _config_definition {
	my ($self, $type, $prefix, $target, %maps) = @_;

	$self->_validate_definition($type, $target, %maps);
	my %config = %{$maps{common}//{}};
	$config{name} = $self->name_for($prefix, $target);
	$config{cloud_properties} = $self->_cloud_properties_for_iaas(
		$type, $target, %{$maps{cloud_properties_for_iaas}//{}}
	) if exists $maps{cloud_properties_for_iaas};

	$self->_process_config_overrides($type, $target, \%config, 'definition');

	# After any overrides, we need to make sure there is a configuration to set
	# Return an empty list if there is no configuration.
	if (exists $config{cloud_properties} && ! keys %{$config{cloud_properties}}) {
		delete($config{cloud_properties});
	}
	return {%config}
		if (grep {$_ !~ m/^(name)$/} keys %config)
		|| ($type eq VM_EXTENSION); # VM Extensions can be empty
	return ();
}

# }}}
# _subnet_definition - Returns the definition for a given subnet {{{
sub _subnet_definition {
	my ($self, $target, $subnet_id, $fields, $strategy) = @_;

	# $target is for named subnets, purely a genesis addition.  It can also be
	# an integer offset of the subnet, or undefined for no subnet (the network
	# base configuration).  The kit can define either a common configuration
	# for a single subnet, or a list of 1 or more subnets, each with their own
	# configuration.  The network_definition method will call this method for
	# either the network base configuration, or for each subnet in the network,
	# providing the map as 'common' for the network base, and target relating
	# to its source.
	#
	# The user's environment can override can specify both a default at the
	# network layer as well as a subnet array for specific over- rides.  The bosh
	# exodus network data will contain common and/or subnet defaults, as well as
	# the existing network allocations, which can be used to determine what is
	# available for allocation, and what is already allocated.
	my $base_config = {
		name => $subnet_id, # Not actually a valid property, but we need it for reference?
		range => $self->_get_network_subnet_property(
			$target, $subnet_id, $fields, 'range', required => 1
		),
		reserved => $self->_get_network_subnet_property(
			$target, $subnet_id, $fields, 'reserved', required => 1
		),
	};

	if ($fields->{az}) {
		$base_config->{az} = $self->_get_network_subnet_property(
			$target, $subnet_id, $fields, 'az'
		);
	} elsif ($fields->{azs}) {
		$base_config->{azs} = $self->_get_network_subnet_property(
			$target, $subnet_id, $fields, 'azs'
		);
	} else {
		bail(
			"No availability zone(s) specified for network %s subnet %s",
			$target, $subnet_id
		);
	}
	my $gateway = $self->_get_network_subnet_property(
		$target, $subnet_id, $fields, 'gateway'
	)	// IPv4->new($base_config->{range})->start->add(1)->address;
	my $dns = $self->_get_network_subnet_property(
		$target, $subnet_id, $fields, 'dns'
	) // [$gateway, '1.1.1.1'];
	$base_config->{gateway} = $gateway;
	$base_config->{dns}     = $dns;
	$base_config->{static}  = $self->_get_network_subnet_property(
		$target, $subnet_id, $fields, 'static'
	) if exists $fields->{static};

	if (exists $fields->{cloud_properties_for_iaas}) {
		my $cloud_properties = flatten(
			$fields->{cloud_properties_for_iaas}{$self->iaas} //
			# TODO: Support glob-style matching for IaaS
			$fields->{cloud_properties_for_iaas}{'*'} //
			{}
		);
		for my $key (keys %$cloud_properties) {
			my $value = $cloud_properties->{$key};
			if (ref($value) eq "Genesis::Hook::CloudConfig::LookupSubnetRef") {
				my $data = $strategy =~ /^ocfp(:.*)?$/
					? scalar $self->env->ocfp_config_lookup(["net.subnets.$subnet_id","vpc.subnets.$subnet_id"])
					: bail "LookupSubnetRef not implemented for strategy $strategy";
				$cloud_properties->{$key} = $value->resolve($self, $data);
			} elsif (ref($value) eq "Genesis::Hook::CloudConfig::LookupNetworkRef") {
				my $data = $strategy =~ /^ocfp(:.*)?$/
					? scalar $self->env->ocfp_config_lookup(['net','vpc'])
					: bail "LookupNetworkRef not implemented for strategy $strategy";
				$cloud_properties->{$key} = $value->resolve($self, $data);
			}
		}
		$base_config->{cloud_properties} = $self->_network_cloud_properties_for_iaas(
			$target, $subnet_id, $self->iaas => unflatten($cloud_properties)
		);
	}

	# After any overrides, we need to make sure there is a configuration to set
	# Return an empty list if there is no configuration.
	delete($base_config->{cloud_properties}) unless keys %{$base_config->{cloud_properties}};
	return $base_config;
}

# }}}
# _get_network_subnet_property - Returns the value for a given property for a network or subnet {{{
sub _get_network_subnet_property {
	my ($self, $target, $subnet_id, $fields, $property, %opts) = @_;
	my $value = $fields->{$property};

	# Check for overrides from the environment, and the bosh exodus data
	my $target_path = "networks.$target.subnet";
	my $override = $self->_process_config_overrides(
		$target_path, $subnet_id, $value, "subnets.$subnet_id.$property"
	);
	$override = $self->_process_config_overrides(
		'network_defaults.subnet', $subnet_id, $value, "subnet_defaults.$property"
	) unless defined($override);
	$value = $override if defined($override);

	bail(
		"No %s specified for network %s subnet %s",
		$property, $target, $subnet_id
	) if (!defined($value) && $opts{required});
	return $value;
}

# }}}
# _network_cloud_properties_for_iaas - Returns the cloud properties for a given network and cpi {{{
sub _network_cloud_properties_for_iaas {
	my ($self, $target, $subnet_id, %map) = @_;
	my $config = $self->_cloud_properties_for_iaas(
		'network_defaults.subnet', $subnet_id, %map
	);
	return $self->_process_config_overrides(
		"networks.$target.subnet", $subnet_id, $config, 'cloud_properties'
	);
}

# }}}
# _cloud_properties_for_iaas - Returns the cloud properties for a given type and cpi {{{
sub _cloud_properties_for_iaas {
	my ($self, $type, $target, %map) = @_;
	my $map_key = (grep {$_ eq $self->iaas} keys %map)[0]
		// (grep {$_ =~ /(?:^|\|)$self->iaas(?:\||$)/} keys %map)[0]
		// '*';
	my $cloud_properties = $map{$map_key} // {}; #TODO: allow glob-style matching

	return $self->_process_config_overrides(
		$type, $target, $cloud_properties, 'cloud_properties'
	);
}

# }}}
# _process_config_overrides - Applies overrides to a given config based on the environment and bosh {{{
sub _process_config_overrides {
	my ($self, $type, $target, $config, $path) = @_;

	# Recursively process each key or array element in the config, keeping track
	# of the path to determine where the overrides can be found.  Locations for
	# the overides are:
	# - environment file:
	#  - bosh-configs.cloud.${type}_defaults.${path}
	#  - bosh-configs.cloud.${type}s.$name.${path}
	# - exodus:
	#   /secret/<bosh-env-name>/<bosh-type>/configs/cloud/${type}/${path} TODO:  This is not implemented yet
	#
	# If the key is an array reference, the key is the first element, and the
	# lookup path is the second element.
	#
	# FIXME:  This only detects overrides for known config properties.  We need
	# to track the overrides that aren't applied, and just apply them at the end.
	# Alternatively, we lookup all the overrides first, and apply them as we go
	# for any matching paths.
	if (ref($config) eq 'HASH') {
		foreach my $key (keys %$config) {
			my $value    = delete($config->{$key});
			my $new_path = $path ? "$path.$key" : $key;

			$config->{$key} = $self->_process_config_overrides(
				$type, $target, $value, $new_path
			);
			delete($config->{$key}) unless defined($config->{$key});
		}

		# Apply overrides for non-processed items here...
	} elsif (ref($config) eq 'ARRAY') {
		foreach my $i (0..$#{$config}) {
			my $element  = $config->[$i];
			my $new_path = $path ? "${path}[$i]" : ".[$i]";
			$config->[$i] = $self->_process_config_overrides(
				$type, $target, $element, $new_path
			);
		}

		# Apply overrides for non-processed items here... (not likely to happen for arrays)
	} elsif (ref($config) eq 'Genesis::Hook::CloudConfig::LookupRef') {
		# This is a lookup referrence, with optional defaults
		$config = $config->default;
	} else {
		my ($override, $src) = $self->env->lookup([
			"bosh-configs.cloud.".count_nouns(2,$type, suppress_count => 1).".$target.$path",
			"bosh-configs.cloud.${type}_defaults.$path"
		]);

		# Unimplemented in upstream deployments so far, so disabling for now
		#($override, $src) = $self->_bosh_exodus_lookup( # This will be cached so don't fetch exodus data for each lookup
		#	"/configs/cloud/$type/$path" =~ s/\./\//gr,
		#) unless defined($override);

		if ($override) {
			trace(
				"Applying override for %s %s %s: %s (from %s)",
				$type, $target, $path, JSON::PP->new->allow_nonref->encode($override), $src
			);
			$config = $override;
		}
	}
	return $config;
}

# }}}
# _validate_definition - Validates the definition for a given vm type {{{
sub _validate_definition {
	my ($self, $type, $target, %maps) = @_;

	# Vaidate that %maps contains the only common and cloud_properties_for_iaas keys
	my @extra_keys = grep {$_ !~ m/^(common|cloud_properties_for_iaas)$/} keys %maps;
	$self->env->kit->kit_bug(
		"Unexpected Cloud Config keys in %s %s in %s: %s\n".
		"Expected: common, cloud_properties_for_iaas",
		$target, $self->env->kit->id, $type, join(", ", @extra_keys)
	) if @extra_keys;

	# Make sure we have at least one of common and cloud_properties_for_iaas keys
	$self->env->kit->kit_bug(
		"No Cloud Config definition for common or cloud_properties_for_iaas for %s %s in %s",
		$target, $self->env->kit->id
	) unless ($maps{cloud_properties_for_iaas} || $maps{common});

	$self->env->kit->kit_bug(
		"Cloud Config common definition for %s %s in %s is not a hashmap",
		$target, $self->env->kit->id
	) unless !defined($maps{common}) || ref($maps{common}) eq 'HASH';

	$self->env->kit->kit_bug(
		"Cloud Config cloud_properties_for_iaas for %s %s in %s is not a hashmap",
		$target, $self->env->kit->id
	) unless !defined($maps{cloud_properties_for_iaas}) || ref($maps{cloud_properties_for_iaas}) eq 'HASH';

	return 1;
}

# }}}
# _bosh_exodus_lookup - Returns the value for a given path in the bosh exodus data {{{
sub _bosh_exodus_lookup {
	my ($self, $path) = @_;
	return undef if $self->env->use_create_env;

	# This will return the value for a given path in the exodus data for the bosh
	# director that is deploying the environment. This will be used to get the
	# overrides if present.
	return $self->env->director_exodus_lookup("$path");
}

# }}}
# _subnet_ranges - Returns the reserved and available IP ranges for a given subnet {{{
sub _get_subnet_ranges {
	my ($self, $subnet) = @_;
	my $range = IPv4->new($subnet->{cidr_block});

	my @reserved_ip_pairs = @{$subnet->{'reserved-ips'}}{
		sort grep {$_ =~ /^reserved/} keys %{$subnet->{'reserved-ips'}}
	};
	my @available_ip_pairs = @{$subnet->{'reserved-ips'}}{
		sort grep {$_ =~ /^available/ } keys %{$subnet->{'reserved-ips'}}
	};

	my $explicit_availabiliy = scalar(@available_ip_pairs) > 0;
	my $explicit_reserved    = scalar(@reserved_ip_pairs) > 0;
	@available_ip_pairs = ($range->start->address, $range->end->address)
		unless @reserved_ip_pairs || @available_ip_pairs;
	@reserved_ip_pairs = (
		$range->start->address, $range->start->add(4)->address,
		$range->end->address,   $range->end->address,
	) unless @reserved_ip_pairs;

	# We only need reserved or available, with available being the default
	my $reserved_range = IPv4->new();
	$reserved_range += [splice(@reserved_ip_pairs, 0, 2)]
		while @reserved_ip_pairs;

	my $available_range = IPv4->new();
	$available_range += [splice(@available_ip_pairs, 0, 2)]
		while @available_ip_pairs;

	if ($explicit_availabiliy) {
		$reserved_range += ($range - $available_range);
	}

	$available_range = $range unless $available_range > 0;
	$available_range -= $reserved_range if $reserved_range > 0;

	# Reserve everything not explicitly available
	return ($available_range->simplify, $reserved_range->simplify);
}

# }}}
# _get_existing_allocations - Returns the existing allocations for a given network {{{
sub _get_existing_allocations {
	my ($self) = @_;
	my $data = $self->network;

	my $ranges = {};
	for my $subnet (keys %{$data->{subnets}}) {
		for my $network (keys %{$data->{subnets}{$subnet}{claims}}) {
			$ranges->{$network}{$subnet} = IPv4->new(
				$data->{subnets}{$subnet}{claims}{$network}
			);
		}
	}
	return $ranges;
}

# }}}
# _calculate_subnet_allocation - Calculates the IP range for a given subnet and network {{{
sub _calculate_subnet_allocation {
	my ($self, $target, $available, $existing, $count) = @_;
	my $needed = $count - $existing->size();

	# FIXME: We currently don't check if the current allocation is within
	# the available range.  This is an oversight that needs to be corrected,
	# but for MVP, we will assume that the existing allocations are within
	# the available range.

	if ($needed < 0) {
		# We remove from the highest end of the existing allocation.
		my $new_span = IPv4->range($existing)->slice(0,$existing->size+$needed);
		# See if we removed enough to handle the negatie need.
		$needed = $existing->size - $new_span->size + $needed;
		bug(
			"Negative IP allocation for network '%s' allocation - not enough allocated IPs to remove",
			$target
		) if $needed < 0;
		$existing = $new_span->simplify;
	}

	if ($needed > 0) {
		bail(
			'Not enough available IPs in the subnet for the network \'%s\' allocation: '.
			' (has %d, needs %d)',
			$target, $available, $needed
		) if ($available < $needed);
		my ($additional, $still_needed) = $available->slice($needed);
		bug(
			"Failed to allocate available range for network '%s' allocation",
			$target
		) if $still_needed;
		return IPv4->new($existing)->add($additional)->simplify;
	}
	return $existing if $needed == 0;
	return $existing->slice($count)->simplify;
}

# }}}
# _calculate_static_allocation - Calculates the static IP range for a given subnet and network {{{
sub _calculate_static_allocation {
	my ($self, $target, $allocated, $count) = @_;
	if ($count =~ m#^(\d+)%#) {
		$count = round($allocated->size() * ($1 / 100));
	}

	# TODO: Support offsets for static IPs instead of just a counts
	my $static_range = IPv4->new();
	if ($count > 0) {
		($static_range) = $allocated->slice($count);
	}
	return $static_range;
}

# }}}
# _get_bosh_network_data - Returns the network data for the BOSH director (self) {{{
sub _get_bosh_network_data {
	return $_[0]->env->director_exodus_lookup('/network');
}

# }}}
# _filter_subnets - Filters and validates subnets based on provided filter criteria {{{
sub _filter_subnets {
	my ($self, $subnet_filter) = @_;

	my $subnets = $self->subnets;
	return $subnets unless defined($subnet_filter);

	$subnet_filter = [$subnet_filter] unless ref $subnet_filter eq 'ARRAY';
	my $selected_subnets = {};

	for my $filter (grep {defined $_} @$subnet_filter) {
		if (ref $filter eq 'Regexp') {
			for my $subnet (keys %$subnets) {
				$selected_subnets->{$subnet} = $subnets->{$subnet} if $subnet =~ $filter;
			}
		} elsif (ref($filter)) {
			bail("Invalid subnet filter type: %s", ref($filter));
		} elsif (defined($subnets->{$filter})) {
			$selected_subnets->{$filter} = $subnets->{$filter};
		} else {
			debug("Invalid subnet name in filter: %s", $filter);
		}
	}

	return $selected_subnets;
}

# }}}

# _az_definition_for - Returns the definition for a given availability zone {{{
sub _az_definition_for {
	my ($self, $az, %options) = @_;
	my $config = {
		name => $options{name} // $az->{name}, # Support CPI Shadow naming
	};
	$config->{cloud_properties} = JSON::PP->new->decode($az->{cloud_properties}) unless $options{virtual};
	$config->{cpi} = $self->cpi_name if ($self->cpi_enabled);
	return $config;
}

# }}}
# _process_network_subnets - Processes the network subnets to match what BOSH needs {{{
sub _process_network_subnets {
	my ($self, $networks) = @_;
	return unless ref($networks) eq 'ARRAY';

	# This will make the subnets in the networks be compatible with BOSH's expectations for
	# network definitions in cloud config.  To do this, we will:
	# - Remove the `name` property from the subnets, as BOSH does not use it.
	# - Transform any subnets that have the same CIDR range into a Logical Subnet Amalgamation (LSA).

	for my $network (@$networks) {
		bail(
			"Network definition is not a hashref: %s", $network
		) unless ref($network) eq 'HASH' && exists $network->{subnets};

		my $subnets = delete($network->{subnets});
		my %subnets_by_range = ();
		push(@{$subnets_by_range{$_->{range}}}, $_) for (@$subnets);
	
		my @lsa_subnets = ();
		my %processed_ranges = ();
		
		# Process subnets in original order to maintain ordering
		for my $subnet (@$subnets) {
			my $range = $subnet->{range};
			next if $processed_ranges{$range}; # Skip if we already processed this range
			
			$processed_ranges{$range} = 1;
			my @subnet_configs = @{$subnets_by_range{$range}};
			
			if (@subnet_configs > 1) {
				# Build a logical subnet amalgamation (LSA) for this range
				my $lsa = $self->_build_logical_subnet_amalgamation(
					$network->{name}, \@subnet_configs
				);
				push @lsa_subnets, $lsa if $lsa;
			} else {
				# Single subnet, remove the name and keep it as is
				delete($subnet_configs[0]->{name});
				push @lsa_subnets, $subnet_configs[0];
			}
		}
		# Replace the subnets with the LSAs
		$network->{subnets} = \@lsa_subnets;
	}
	return 1;
}
# }}}
# _build_logical_subnet_amalgamation - Builds a logical subnet amalgamation for subnets with the same range {{{
sub _build_logical_subnet_amalgamation {
	my ($self, $target, $subnet_configs) = @_;

	# Short-circuit if only one subnet
	return $subnet_configs->[0] unless ref($subnet_configs) eq 'ARRAY' && @$subnet_configs > 1;

	my @subnet_names = sort map {$_->{name}} @$subnet_configs;
	my %subnet_configs_hash = map {$_->{name} => $_} @$subnet_configs;

	# Validate that all subnets have the same range and gateway
	my (%ranges, %gateways) = ();
	for my $subnet_name (@subnet_names) {
		push @{$ranges{$subnet_configs_hash{$subnet_name}->{range}}}, $subnet_name;
		push @{$gateways{$subnet_configs_hash{$subnet_name}->{gateway}}}, $subnet_name;
	}
	bail(
		'Cannot create LSA for subnets with different ranges:\n%s',
		join("\n", map {"%s: %s" } map {$_ => join(', ', @{$ranges{$_}})} keys %ranges)
	) if keys(%ranges) > 1;
	bail(
		'Cannot create LSA for subnets with different gateways:\n%s',
		join("\n", map {"%s: %s" } map {$_ => join(', ', @{$gateways{$_}})} keys %gateways)
	) if keys(%gateways) > 1;

	my ($range) = keys %ranges;
	my ($gateway) = keys %gateways;

	# Deduplicate and merge AZs and DNS entries
	my @azs = uniq sort map {$_->{az}} @$subnet_configs;
	my @dns_servers = uniq sort map { @{$_->{dns} // []} } @$subnet_configs;

	# Build amalgamated configuration
	my $lsa_config = {
		range => $range,
		gateway => $gateway,
		azs => \@azs,
		dns => \@dns_servers,
	};

	# Calculate amalgamated reserved ranges - easiest way to do this is to
	# convert reserved ranges into available ranges for each subnet,
	# add them together, then subtract from the full range.

	my $range_span = IPv4->span($range);
	my $reserved = $range_span - IPv4->new(
		map {$range_span - IPv4->new($_->{reserved}->@*)} @$subnet_configs
	);
	$lsa_config->{reserved} = [map {"$_"} $reserved->spans];

	# Calculate amalgamated static ranges - these should be unique across
	# all subnets, so we can just merge them together and simplify.
	$lsa_config->{static} = [
		map {($_->{static}->@*)} grep {$_->{static}} @$subnet_configs
	];

	# Use cloud properties from first subnet (they should be similar for same range)
	# FIXME: We should validate that all subnets have the same cloud properties
	if ($subnet_configs->[0]{cloud_properties}) {
		$lsa_config->{cloud_properties} = $subnet_configs->[0]{cloud_properties};
	}

	# Check if LSA has any available IPs (not all reserved)
	return $range_span->size > $reserved->size ? $lsa_config : undef;
}

# }}}
# _get_subnet_ref - Returns the subnet reference for a given name {{{
sub _get_subnet_ref {
	my ($self, $name, $all_subnets) = @_;
	# If $all_subnets is not given, get them from $self->network->{subnets}
	$all_subnets //= [keys $self->network->{subnets}->%*];
	return $name if grep {$_ eq $name} @$all_subnets;

	# Check for an LSA (Logical Subnet Amalgamation) containing the name
	my @lsas = grep {$_ =~ /^LSA\|/} @$all_subnets;
	for my $lsa (@lsas) {
		my @subnets = split(/\|/, $lsa);
		return $lsa if grep {$_ eq $name} @subnets;
	}
	bail(
		"Subnet %s not found in the available subnets: %s",
		$name, join(', ', @$all_subnets)
	);
}

# }}}

=old-lsa-code


	# We need to detect if there are multiple subnets with the same range, and
	# amalgamate them into a single logical subnet amalgamation (LSA) if so.
	# The network map (as created by `update_network`) will have the nominal
	# subnet name as the key, but the networks defined in the config will need
	# to use the LSAs instead (the name doesn't matter because it doesn't show
	# up anywhere, but it does need to be unique in the hash).

	# Process each range group
	for my $range (keys %subnets_by_range) {
		my @subnet_configs = @{$subnets_by_range{$range}};
		
		if (@subnet_configs == 1) {
			# Single subnet, use as-is
			my $subnet_config = $subnet_configs[0];
			my $full_range = IPv4->new($subnet_config->{range});
			my $reserved = IPv4->new(@{$subnet_config->{reserved}});
			
			push @{$config->{subnets}}, $subnet_config
				if $full_range->size > $reserved->size;
		} else {
			# Multiple subnets with same range - create LSA
			my $lsa_config = $self->_build_logical_subnet_amalgamation(
				$target, \@subnet_configs,
#				$target, \@subnet_names, \%subnet_configs_hash, $subnets, $strategy
			);
			
			if ($lsa_config) {
				push @{$config->{subnets}}, $lsa_config;
			}
		}
	}

	# Apply subnet filtering after LSA creation
	if (defined($definition->{subnets})) {
		my $built_subnets = [map {$_->{name}} @{$config->{subnets}}];
		my @used_subnets = map {

			$self->_get_subnet_ref($_, $built_subnets)
		} @{$definition->{subnets}};
		
		my ($unused, $used) = compare_arrays($built_subnets, \@used_subnets);
		delete $config->{subnets}{$_} for @$unused;

		return 1;
	}

=cut
1;

# vim - fdm=marker:foldlevel=1:ts=2:sts=2:sw=2:noet
