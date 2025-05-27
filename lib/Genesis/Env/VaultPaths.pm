package Genesis::Env::VaultPaths;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;

### Instance Methods {{{

# vault_paths - get the list of paths in the vault for this environment {{{
sub vault_paths {
	my ($self, %opts) = @_;

	$self->manifest_provider
		->base_manifest
		->get_vault_paths(notify=>$opts{notify}//1);
}

# }}}
# env_vault_slug {{{
sub env_vault_slug {
	(my $p = $_[0]->name) =~ s|-|/|g;
	return $p;
}
# }}}
# secrets_mount - returns the Vault path under which all secrets are stored (env: GENESIS_SECRETS_MOUNT) {{{
sub default_secrets_mount { '/secret/'; }
sub secrets_mount {
	$_[0]->_memoize(sub{
		(my $mount = $_[0]->lookup('genesis.secrets_mount', $_[0]->default_secrets_mount)) =~ s#^/?(.*?)/?$#/$1/#;
		return $mount
	});
}

# }}}
# secrets_slug - returns the component of the Vault path under the mount that represents this environment (env: GENESIS_SECRETS_SLUG) {{{
sub default_secrets_slug {
	return $_[0]->env_vault_slug()."/".$_[0]->top->type;
}
sub secrets_slug {
	$_[0]->_memoize(sub {
		my $slug = $_[0]->lookup(
			['genesis.secrets_path','params.vault_prefix','params.vault'],
			$_[0]->default_secrets_slug
		);
		$slug =~ s#^/?(.*?)/?$#$1#;
		return $slug
	});
}

# }}}
# secrets_base - returns the full Vault path for secrets stored for this environment with / suffix (env: GENESIS_SECRETS_BASE) {{{
sub secrets_base {
	$_[0]->_memoize(sub {
		$_[0]->secrets_mount . $_[0]->secrets_slug . '/'
	});
}

# }}}
# exodus_mount - returns the Vault path under which all Exodus data is stored (env: GENESIS_EXODUS_MOUNT) {{{
sub default_exodus_mount { $_[0]->secrets_mount . 'exodus/'; }
sub exodus_mount {
	$_[0]->_memoize(sub {
		(my $mount = $_[0]->lookup('genesis.exodus_mount', $_[0]->default_exodus_mount)) =~ s#^/?(.*?)/?$#/$1/#;
		return $mount;
	});
}

# }}}
# FIXME: These env references aren't being used anywhere
# exodus_slug - returns the component of the Vault path under the Exodus mount for this evironments Exodus data {{{
sub exodus_slug {
	sprintf("%s/%s", $_[0]->name, $_[0]->type);
}

# }}}
# exodus_base - returns the full Vault path of the Exodus data for this environment (env:  GENESIS_EXODUS_BASE) {{{
sub exodus_base {
	$_[0]->_memoize(sub {
		$_[0]->exodus_mount . $_[0]->exodus_slug
	});
}

# }}}
# ci_mount - returns the Vault path under which all CI secrets are stored (env: GENESIS_CI_MOUNT) {{{
sub default_ci_mount { $_[0]->secrets_mount . 'ci/'; }
sub ci_mount {
	$_[0]->_memoize(sub {
		(my $mount = $_[0]->lookup('genesis.ci_mount', $_[0]->default_ci_mount)) =~ s#^/?(.*?)/?$#/$1/#;
		return $mount;
	});
}

# }}}
# ci_base - returns the full Vault path under which the CI secrets for this environment are stored (env: GENESIS_CI_BASE) {{{
sub ci_base {
	$_[0]->_memoize(sub {
		my $default = sprintf("%s%s/%s/", $_[0]->ci_mount, $_[0]->type, $_[0]->name);
		(my $base = $_[0]->lookup('genesis.ci_base', $default)) =~ s#^/?(.*?)/?$#/$1/#;
		return $base
	});
}

# }}}
# ocfp_config_mount - returns the Vault path under which all ocfp_config data is stored (env: GENESIS_OCFP_CONFIG_MOUNT) {{{
sub default_ocfp_config_mount { $_[0]->secrets_mount . $_[0]->lookup('params.ocfp_vault_config_prefix','config') . '/'; }
sub ocfp_config_mount {
	$_[0]->_memoize(sub {
		(my $mount = $_[0]->lookup('genesis.ocfp_config_mount', $_[0]->default_ocfp_config_mount)) =~ s#^/?(.*?)/?$#/$1/#;
		return $mount;
	});
}

# }}}
# ocfp_config_slug - returns the component of the Vault path under the ocfp_config mount for this evironments ocfp_config data {{{
sub ocfp_config_slug {
	my $param_ocfp_config_slug = $_[0]->lookup('params.ocfp_vault_config_slug');
	return $param_ocfp_config_slug if $param_ocfp_config_slug;
	sprintf("%s/%s", $_[0]->name =~ m/^(.*)-(mgmt|ocf)$/);
}

# }}}
# ocfp_config_base - returns the full Vault path of the ocfp_config data for this environment (env:  GENESIS_OCFP_CONFIG_BASE) {{{
sub ocfp_config_base {
	$_[0]->_memoize(sub {
		$_[0]->ocfp_config_mount . $_[0]->ocfp_config_slug
	});
}

# }}}
# root_ca_path - returns the root_ca_path, if provided by the environment file (env: GENESIS_ROOT_CA_PATH) {{{
sub root_ca_path {
	my $self = shift;
	unless (exists($self->{__root_ca_path})) {
		$self->{__root_ca_path} = $self->lookup('genesis.root_ca_path','');
		$self->{__root_ca_path} =~ s/\/$// if $self->{__root_ca_path};
	}

	return $self->{__root_ca_path};
}

# }}}
# }}}

1;

=head1 NAME

Genesis::Env::VaultPaths

=head1 DESCRIPTION

This module manages all Vault path calculations and lookups for Genesis environments,
including secrets, exodus data, CI paths, and OCFP configuration paths.

=head1 METHODS

=head2 vault_paths(%opts)

Gets the list of paths in the vault for this environment.

=head2 env_vault_slug()

Returns the environment vault slug (environment name with dashes replaced by slashes).

=head2 secrets_mount()

Returns the Vault path under which all secrets are stored.
Environment variable: GENESIS_SECRETS_MOUNT

=head2 default_secrets_mount()

Returns the default secrets mount path: '/secret/'

=head2 secrets_slug()

Returns the component of the Vault path under the mount that represents this environment.
Environment variable: GENESIS_SECRETS_SLUG

=head2 default_secrets_slug()

Returns the default secrets slug based on environment name and type.

=head2 secrets_base()

Returns the full Vault path for secrets stored for this environment with / suffix.
Environment variable: GENESIS_SECRETS_BASE

=head2 exodus_mount()

Returns the Vault path under which all Exodus data is stored.
Environment variable: GENESIS_EXODUS_MOUNT

=head2 default_exodus_mount()

Returns the default exodus mount path based on secrets mount.

=head2 exodus_slug()

Returns the component of the Vault path under the Exodus mount for this environment's Exodus data.

=head2 exodus_base()

Returns the full Vault path of the Exodus data for this environment.
Environment variable: GENESIS_EXODUS_BASE

=head2 ci_mount()

Returns the Vault path under which all CI secrets are stored.
Environment variable: GENESIS_CI_MOUNT

=head2 default_ci_mount()

Returns the default CI mount path based on secrets mount.

=head2 ci_base()

Returns the full Vault path under which the CI secrets for this environment are stored.
Environment variable: GENESIS_CI_BASE

=head2 ocfp_config_mount()

Returns the Vault path under which all ocfp_config data is stored.
Environment variable: GENESIS_OCFP_CONFIG_MOUNT

=head2 default_ocfp_config_mount()

Returns the default OCFP config mount path.

=head2 ocfp_config_slug()

Returns the component of the Vault path under the ocfp_config mount for this environment's ocfp_config data.

=head2 ocfp_config_base()

Returns the full Vault path of the ocfp_config data for this environment.

=head2 root_ca_path()

Returns the root_ca_path, if provided by the environment file.
Environment variable: GENESIS_ROOT_CA_PATH

=cut