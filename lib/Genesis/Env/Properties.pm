package Genesis::Env::Properties;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::UI;
use Genesis::Commands qw/known_commands/;

use Digest::SHA qw/sha1_hex/;

### Instance Methods {{{

# Public Accessors: name, file, kit, top {{{
sub name   { $_[0]->{name};   }
sub file   { $_[0]->{file};   }
sub kit    { $_[0]->{kit}    || bug("Incompletely initialized environment '".$_[0]->name."': no kit specified"); }
sub top    { $_[0]->{top}    || bug("Incompletely initialized environment '".$_[0]->name."': no top specified"); }

# }}}
# Delegations: type, path {{{
sub type   { $_[0]->top->type; }
sub path   { shift->top->path(@_); }
# }}}

# Information Lookup
# signature - unique 12-character id for the environment based on name, type and file {{{
sub signature {
	return $_[0]->_memoize( sub {
		my ($self) = @_;
		my $absfile = $self->path($self->file);
		my $sig_string = sprintf("%s/%s@%s:%s",
			$self->name,
			$self->type,
			$absfile,
			(-f $absfile ? slurp($absfile) : '')
		);
		return substr(sha1_hex($sig_string),0,12)
	});
}
# }}}
# deployment_name - returns the deployment name (env name + env type) {{{
sub deployment_name {
	$_[0]->_memoize('__deployment', sub {
		my $self = shift;
		sprintf('%s-%s',$self->name,$self->top->type);
	});
}

# }}}
# sub manifest_store - returns the type of manifest store: exodus, hybrid, or repository {{{
sub manifest_store {
	# If the environment supports a version of Genesis lower than 3.1.0-rc9, then
	# the manifest store is always 'repository' because earlier versions of Genesis
	# cannot update the exodus deployment audit data.
	# FIXME: This should be 3.1.0 when released
	return 'repository' unless $_[0]->feature_compatibility("3.1.0-rc9");
	shift->top->config->get('manifest_store','hybrid');
}

# }}}
# deployment_state - returns the status of the deployment {{{
sub deployment_state {
	my $self = shift;
	my $exodus = $self->exodus_lookup();
	my $latest_deploy = $self->deployment_lookup('latest');
	return 'undeployed' unless $latest_deploy || $exodus;
	if (!defined $exodus->{sequence}) {
		return 'terminated' if ($latest_deploy->{state}//'') eq 'terminated';
		$latest_deploy = $self->_backfill_deployment_audit_data($exodus, $latest_deploy);
	} elsif ($exodus->{sequence} != ($latest_deploy->{sequence}//0)) {
		$latest_deploy = $self->_backfill_deployment_audit_data($exodus, $latest_deploy);
	}
	return $latest_deploy->{state};
}

# }}}
# is_bosh_director - returns true if the environment represents a BOSH director deployment {{{
sub is_bosh_director {
	my $self = shift;
	$self->kit->id =~ /^bosh\// || $self->kit->metadata->{is_bosh_director};
	# RISK: This is very fragile, rework for better diagnosis
}

# }}}
# use_create_env - true if the deployment uses bosh create-env {{{
sub use_create_env {

	return 'unknown' if $_[0]->_get_memo() && $_[0]->_get_memo() eq "processing";
	return $_[0]->_memoize(sub {
		my ($self) = @_;
		$self->_set_memo("processing");
		my $is_bosh_director = $self->is_bosh_director;

		sub clear_and_bail {
			my $self = shift;
			$self->_clear_memo('__use_create_env');
			bail(@_);
		}

		sub validate_create_env_state {
			my ($self,$is_create_env,$has_bosh_env,$env_type,$is_bosh_kit, $is_310plus) = @_;
			clear_and_bail($self,
				"This #M{$env_type} environment specifies an alternative bosh_env, but ".
				"is marked as a create-env (proto) environment. Create-env deployments ".
				"can't use a #C{genesis.bosh_env} value, so please remove it, or mark ".
				"this environment as a non-create-env environment.  It may be that ".
				"bosh_env is configured in an inherited environment file."
			) if $is_create_env && $has_bosh_env;
			return unless $is_bosh_kit;
			clear_and_bail($self,
				"This #M{$env_type} environment does not use create-env nor does it ".
				"specify an alternative #C{genesis.bosh_env} as a deploy target.  ".
				"Please provide the name of the BOSH environment that will deploy this ".
				"environment, or mark this environment as a create-env environment."
			) if $is_310plus && !($is_create_env || $has_bosh_env );
			clear_and_bail($self,
				"This #M{$env_type} environment does not use create-env (proto) or ".
				"specify an alternative #C{genesis.bosh_env} as a deploy target.  ".
				"Please provide the name of the BOSH environment that will deploy this ".
				"environment, or mark this environment as a create-env environment."
			) unless $is_create_env || $has_bosh_env;
		}

		my $different_bosh_env = ($self->bosh_env->{description}//$self->name) ne $self->name;

		if ($self->kit->feature_compatibility("2.8.0")) {
			# Kits that are explicitly compatible with 2.8.0 can specify if they
			# support or require create-env deployments.

			my $kuce = $self->kit->metadata('use_create_env')||'';
			if ($kuce eq 'yes') {
				clear_and_bail($self,
					"This kit only allows create-env deployments, but this environment ".
					"specifies an alternative bosh_env.  Please remove the ".
					"#C{genesis.bosh_env} entry from the environment file."
				) if $different_bosh_env;
				return 1;
			};
			if ($kuce eq 'no') {
				clear_and_bail($self,
					"BOSH environments must specify the name of the parent BOSH director ".
					"that will deploy this enviornment under #C{genesis.bosh_env} in the ".
					"file, because unlike other kits, it cannot derive its director from ".
					"its environment name."
				) if $is_bosh_director && !$different_bosh_env;
				return 0 ;
			}

			# Allowed, but not reuqired to use create-env
			my $is_create_env = undef;
			my $euce = $self->lookup('genesis.use_create_env', undef);
			my $is_310plus = $self->feature_compatibility("3.1.0-rc1");
			if ($is_310plus && $is_bosh_director) {
				# proto feature removed in 3.1.0-rc1
				$is_create_env = $euce || !$different_bosh_env;
			} elsif ($euce) {
				$is_create_env = 1;
			} elsif ( $is_bosh_director && $different_bosh_env) {
				$is_create_env = 0;
			} elsif (grep {$_ eq 'proto'} @{$self->lookup('kit.features', [])}) {
				$is_create_env = 1;
			} else {
				$is_create_env = 0;
			}

			validate_create_env_state(
				$self,$is_create_env,$different_bosh_env,$self->type,
				$is_bosh_director,$is_310plus
			);
			return $is_create_env;
		}

		# Before 2.8.0, we only support create-env deployments for bosh deployments.
		return 0 unless $is_bosh_director;

		# If creating a new bosh environment, we need to do some special handling.

		# Support pre-v2.8.0 create env schemes...
		my $euce;
		if ($self->exists) {
			my $features = scalar($self->lookup(['kit.features', 'kit.subkits'], []));
			$euce = scalar(grep {$_ =~ /^(proto|bosh-init|create-env)$/} @$features) ? 1 : 0; # FIXME: remove bosh-init prior to 3.1.0, proto prior to 3.2.0
		} else {
			$euce = !$ENV{GENESIS_BOSH_ENVIRONMENT};
		}
		dump_var detected=>$euce, diff => $different_bosh_env;
		validate_create_env_state($self,$euce,$different_bosh_env,"bosh",1);
		return $euce;
	});
}

# }}}
# can_build_cloud_configs - returns true if the environment can build a cloud config {{{
sub can_build_cloud_configs {
	my $self = shift;
	return 0 unless $self->feature_compatibility("3.1.0-rc.9");
	return 0 unless $self->lookup('genesis.manage-cloud-configs')//1;
	return 1;
}

# }}}
# feature_compatibility - returns true if the min version for the environment meets or exceeds the specified version {{{
sub feature_compatibility {
	my ($self,$version) = @_;
	trace("Comparing %s environment specified version (%s) to %s feature base", $self->name, $self->{__min_version}, $version);
	return new_enough($self->{__min_version},$version);
}

# }}}
# get_call_path - returns the path to the genesis binary {{{
sub get_call_path {
	my ($self) = @_;
	return $self->_memoize(sub {
		my $bin = $ENV{GENESIS_CALL_BIN} || humanize_bin();
		$bin = "'$bin'" if $bin =~ / \(\)!\*\?/;
		return $bin;
	});
}

# }}}
# get_call_path_with_env - returns the path to the genesis binary and the environment name {{{
sub get_call_path_with_env {
	my ($self) = @_;
	my $bits = $self->_memoize(sub {
		my $bin = $self->get_call_path();
		my $is_alt_path = defined($ENV{GENESIS_CALLER_DIR}) && $self->path ne $ENV{GENESIS_CALLER_DIR};

		my $env_ref = $self->name;
		if (($ENV{GENESIS_PREFIX_TYPE}//'') eq 'search') {
			$env_ref = "$ENV{GENESIS_PREFIX_SEARCH}";
		} else {
			$env_ref .= '.yml' if (grep {$_ eq $self->name} known_commands);
			$env_ref = humanize_path($self->path)."/$env_ref" if $is_alt_path;
		}
		$env_ref = "'$env_ref'" if $env_ref =~ / \(\)!\*\?/;
		return [$bin, $env_ref];
	});
	return wantarray ? @$bits : join(' ', @$bits);
}

# workpath - provide the path to the temporary file storage for this envionment {{{
sub workpath {
	my ($self, $relative) = @_;
	return $relative ? "$self->{__tmp}/$relative"
	                 :  $self->{__tmp};
}

# }}}
# potential_environment_files - list the heirarchal environment files possible for this env {{{
sub potential_environment_files {
	my $env = $ENV{PREVIOUS_ENV} || ''; # ci pipelines need to pull cache for previous envs
	return $_[0]->relate($env, ".genesis/cached/$env");
}

# }}}
# actual_environment_files - list the heirarchal environment files that exist for this env {{{
sub actual_environment_files {
	my $ref = $_[0]->_memoize('__actual_files', sub {
		my $self = shift;
		if ($self->{is_from_envvars} && ! -f $self->path($self->file)) {
			my $tmpenv = $self->workpath("reconstructed-env.yml");
			save_to_yaml_file($self->params,$tmpenv);
			return [$tmpenv];
		}
		my @files;
		for my $file (grep {-f $self->path($_)} $self->potential_environment_files) {
			push( @files, $self->_genesis_inherits($file, @files),$file);
		};
		return \@files;
	});
	return @$ref;
}

# }}}
# relate - get hierarchal file relationships with another environment {{{
sub relate {
	my ($self, $them, $common_base, $unique_base) = @_;
	return relate_by_name($self->{name}, ref($them) ? $them->{name} : $them, $common_base, $unique_base);
}

# }}}
# relate_by_name - get hierarchal file relationships between named environments {{{
sub relate_by_name {
	my ($name, $other, $common_base, $unique_base) = @_;
	$common_base ||= '.';
	$unique_base ||= '.';
	$other ||= '';

	my @a = split /-/, $name;
	my @b = split /-/, $other;
	my @c = (); # common

	while (@a and @b) {
		last unless $a[0] eq $b[0];
		push @c, shift @a; shift @b;
	}
	# now @c contains common tokens (us, west, 1)
	# and @a contains unique tokens (preprod, a)

	my (@acc, @common, @unique);
	for (@c) {
		# accumulate tokens: (us, us-west, us-west-1)
		push @acc, $_;
		push @common, "$common_base/".join('-', @acc).".yml";
	}
	for (@a) {
		# accumulate tokens: (us-west-1-preprod,
		#                     us-west-1-preprod-a)
		push @acc, $_;
		push @unique, "$unique_base/".join('-', @acc).".yml";
	}

	trace("[env $name] in relate(): common $_") for @common;
	trace("[env $name] in relate(): unique $_") for @unique;

	return wantarray
		? (@common, @unique)
		: { common => \@common, unique => \@unique };
}

# }}}
# format_yaml_files - return the list of all yaml files used to create the manifest {{{
sub format_yaml_files {
	my ($self, %options) = @_;
	my $local_label = $options{'local-label'} || "./";
	my $padding = $options{padding} || '';

	my @files;
	if ($options{'include-kit'}) {
		my $kit_label   = $options{'kit-label'} || "#G{".$self->kit->id.":} ";
		$local_label = sprintf("%*s", length($kit_label), "#C{local:} ");
		my $env_path = $self->path();
		for ($options{kit_files} ? $options{kit_files}->@* : $self->kit_files) {
			if ($_ =~ qr/^$env_path\/(.*)$/) {
				push @files, "$padding$local_label$1";
			} else {
				push @files, "$padding$kit_label#K{$_}";
			}
		}
	}
	push @files, map {(my $f = $_) =~ s/^\.\//$padding$local_label/; $f}
		($self->actual_environment_files);
	return @files;
}

# }}}
# }}}

1;

=head1 NAME

Genesis::Env::Properties

=head1 DESCRIPTION

This module contains basic property accessors and information lookup methods
for Genesis environments.

=head1 METHODS

=head2 name()

Returns the environment name.

=head2 file()

Returns the environment file name.

=head2 kit()

Returns the kit object associated with this environment.

=head2 top()

Returns the top-level Genesis object.

=head2 type()

Returns the deployment type.

=head2 path(@paths)

Returns paths relative to the deployment root.

=head2 signature()

Returns a unique 12-character ID for the environment.

=head2 deployment_name()

Returns the deployment name (env name + env type).

=head2 manifest_store()

Returns the type of manifest store: exodus, hybrid, or repository.

=head2 deployment_state()

Returns the status of the deployment.

=head2 is_bosh_director()

Returns true if the environment represents a BOSH director deployment.

=head2 use_create_env()

Returns true if the deployment uses bosh create-env.

=head2 can_build_cloud_configs()

Returns true if the environment can build a cloud config.

=head2 feature_compatibility($version)

Returns true if the min version for the environment meets or exceeds the specified version.

=head2 get_call_path()

Returns the path to the genesis binary.

=head2 get_call_path_with_env()

Returns the path to the genesis binary and the environment name.

=head2 workpath($relative)

Provides the path to the temporary file storage for this environment.

=head2 potential_environment_files()

Lists the hierarchical environment files possible for this env.

=head2 actual_environment_files()

Lists the hierarchical environment files that exist for this env.

=head2 relate($them, $common_base, $unique_base)

Gets hierarchical file relationships with another environment.

=head2 relate_by_name($name, $other, $common_base, $unique_base)

Gets hierarchical file relationships between named environments.

=head2 format_yaml_files(%options)

Returns the list of all yaml files used to create the manifest.

=cut