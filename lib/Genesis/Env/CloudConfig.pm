package Genesis::Env::CloudConfig;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::UI;

### Instance Methods {{{

# Config Management
# configs - return the list of configs being used by this environment. {{{
sub configs {
	my @env_configs = map {
		$_ =~ m/GENESIS_([A-Z0-9_-]+)_CONFIG(?:_(.*))?$/;
		lc($1).($2 && $2 ne '*' ? "\@$2" : '');
	} grep {
		/GENESIS_[A-Z0-9_-]+_CONFIG(_.*)?$/;
	} keys %ENV;
	my @configs = sort(uniq(keys %{$_[0]->{__configs}}, @env_configs));
	return wantarray ? @configs : \@configs; # can't just return the above because scalar/list context crazies
}

# }}}
# required_configs - determine what BOSH configs are needed {{{
sub required_configs {
	my ($self, @hooks) = @_;
	return () if $self->use_create_env;
	my @deploy_hooks = $self->_memoize('__deploy_hooks', sub {
		my $self = shift;
		my @h = qw/blueprint check manifest/;
		push @h, grep {$self->kit->has_hook($_)} qw(pre-deploy post-deploy);
	});
	my @expanded_hooks;
	push(@expanded_hooks, ($_ eq 'deploy' ? @deploy_hooks : $_)) for (@hooks);
	return $self->kit->required_configs(uniq(@expanded_hooks));
}

# }}}
# missing_required_configs - determine what BOSH configs are missing {{{
sub missing_required_configs {
	my ($self, @hooks) = @_;
	return grep {!$self->has_config($_)} $self->required_configs(@hooks);
}

# }}}
# has_required_configs - determine what BOSH configs are needed {{{
sub has_required_configs {
	my ($self, @hooks) = @_;
	return scalar($self->missing_required_configs(@hooks)) == 0;
}

# }}}
# download_required_configs - determzoine what BOSH configs are needed and download them {{{
sub download_required_configs {
	my ($self, @hooks) = @_;
	my @configs = $self->missing_required_configs(@hooks);
	return $self unless @configs;
	debug "Missing configs: ".join(', ', @configs);
	$self->with_bosh->download_configs(@configs);
	return $self
}

# }}}
# download_configs - download the specified BOSH configs from the director {{{
sub download_configs {
	my ($self, @configs) = @_;
	@configs = qw/cloud runtime/ unless @configs;

	info "Downloading configs from #M{%s} BOSH director...", $self->bosh->{alias};
	my $err;
	for (@configs) {
		my $file = "$self->{__tmp}/$_.yml";
		my ($type,$name) = split('@',$_);
		$name ||= '*';
		my $label = $name eq "*" ? "all $type configs" : $name eq "default" ? "$type config" : "$type config '$name'";
		info {pending => 1}, bullet('empty',$label."...", box => 1);
		my @downloaded = eval {$self->with_bosh->bosh->download_configs($file,$type,$name)};
		if ($@) {
			$err = $@;
			info(
				"\r".bullet(
					'bad',$label.join("\n      ", ('...failed!',"",split("\n",$err),"")),
					box => 1
				)
			);
		} else {
			info(
				"[2K\r".bullet(
					'good',$label.($name eq '*' ? ':' : ''),
					box => 1
				)
			);
			$self->use_config($file,$type,$name);
			for (@downloaded) {
				$self->use_config($file,$_->{type},$_->{name});
				info(
					bullet('good',$_->{label}, box => 1, indent => 7)
				)if $name eq "*";
			}
		}
	}

	bail(
		"Could not fetch requested configs from #M{%s} BOSH director at #c{%s}\n",
		$self->bosh->{alias}, $self->bosh->{url}
	) if $err;
	return $self;
}

# }}}
# use_config - specify a local file to use for the given BOSH config {{{
sub use_config {
	my ($self,$file,$type,$name) = @_;
	$self->{__configs} ||= {};
	my $label = $type ||= 'cloud';
	my $env_var = "GENESIS_".uc($type)."_CONFIG";
	if ($name && $name ne '*') {
		$label .= "\@$name";
		$env_var .= "_$name";
	}
	$self->{__configs}{$label} = $file;
	$ENV{$env_var} = $file;
	return $self;
}

# }}}
# has_config - determine if the environment has the specific config file set {{{
sub has_config {
	my ($self, $type, $name) = @_;
	!!$self->config_file($type,$name);
}

# }}}
# config_file - retrieve the path of the local file (provided or downloaded) being used for the named BOSH config {{{
sub config_file {
	my ($self, $type, $name) = @_;
	my $label = $type ||= 'cloud';
	my $env_var = "GENESIS_".uc($type)."_CONFIG";
	if ($name && $name ne '*') {
		$label .= "\@$name";
		$env_var .= "_$name";
	}
	return $self->{__configs}{$label} || $ENV{$env_var} || '';
}

sub config_contents {
	my ($self, %opts) = @_;
	my $type = $opts{type} // 'cloud';
	my $name = $opts{name};
	my $to_s = $opts{to_s} // 0;
	my $content = undef;
	# Bug in cloud config download causes all the cloud configs to point at the same file
	# which is already merged together: commenting out the following code for now..
	# if (!defined($name) || $name eq '*') {
	# 	# We need to merge all the configs together for the given type
	# 	my $file_ids = grep { /$type(\@.*)?$/ } $self->configs;
	# 	$name = $self->config_file($type);
	# } else {
	# 	$content = slurp($self->config_file($type,$name));
	# }
	if ($to_s) {
		return slurp($self->config_file($type,$name));
	} else {
		return load_yaml_file($self->config_file($type,$name))
	}
}

# }}}

# Legacy non-generic config methods {{{
# TODO: Remove these
sub download_cloud_config { $_[0]->download_configs('cloud'); }
sub use_cloud_config { $_[0]->use_config($_[1],'cloud'); }
sub cloud_config { return $_[0]->config_file('cloud'); }
sub download_runtime_config { $_[0]->download_configs('runtime'); }
sub use_runtime_config { $_[0]->use_config($_[1],'runtime'); }
sub runtime_config { return $_[0]->config_file('runtime'); }

# }}}

# }}}

### Private Instance Methods {{{

# _check_cloud_config - check the cloud config {{{
sub _check_cloud_config {
	my ($self) = @_;
	bug(
		"Cloud config check is not implemented yet"
	);
}

# }}}
# _fix_cloud_config - fix the cloud config on the director {{{
sub _fix_cloud_config {
	my ($self, $fix_data, %opts) = @_;
	bug(
		"Cloud config fix is not implemented yet"
	);
}

# }}}

# }}}
# director_config_overrides - returns the director config overrides for the environment {{{
sub director_config_overrides {
	my $self = shift;
	my $overrides = $self->director_exodus_lookup(['bosh-config/cloud' => '.'], {});
	return $overrides;
}

# }}}
# get_network_claims - get the network claims for the environment {{{
sub get_network_claims {
	my ($self) = @_;
	my @network_keys = $self->bosh->vault->keys($self->bosh->exodus_path.'/network');
	my $claims = {};
	my $name = $self->name;
	my $type = $self->type;
	for my $claim (grep {/:subnets\..*\.claims\.$name~$type~/} @network_keys) {
		my ($path, $key, $subnet, $network) = $claim =~ m/^([^:]*):(subnets\.(.*?)\.claims\.(?:.*)~net-([^~]*))$/;
		next unless $subnet && $path && $key && $network; # TODO: This should probably issue a warning at least
		# RISK: Assumes one claim per network/subnet, this may be naive
		$claims->{$network}{$subnet}{ips} = $self->bosh->vault->get($path,$key);
		$claims->{$network}{$subnet}{path} = "$path:$key";
	}
	return $claims;
}

# }}}

1;

=head1 NAME

Genesis::Env::CloudConfig

=head1 DESCRIPTION

This module handles BOSH cloud config and runtime config management for
Genesis environments.

=head1 METHODS

=head2 configs()

Returns the list of configs being used by this environment.

=head2 required_configs(@hooks)

Determines what BOSH configs are needed for the given hooks.

=head2 missing_required_configs(@hooks)

Determines what BOSH configs are missing for the given hooks.

=head2 has_required_configs(@hooks)

Checks if all required configs are available for the given hooks.

=head2 download_required_configs(@hooks)

Downloads missing required configs from the BOSH director.

=head2 download_configs(@configs)

Downloads the specified BOSH configs from the director.

=head2 use_config($file, $type, $name)

Specifies a local file to use for the given BOSH config.

=head2 has_config($type, $name)

Determines if the environment has the specific config file set.

=head2 config_file($type, $name)

Retrieves the path of the local file being used for the named BOSH config.

=head2 config_contents(%opts)

Returns the contents of a config file, either as string or parsed YAML.

=head2 Legacy Methods

The following methods are provided for backwards compatibility:
- download_cloud_config()
- use_cloud_config()
- cloud_config()
- download_runtime_config()
- use_runtime_config()
- runtime_config()

=cut