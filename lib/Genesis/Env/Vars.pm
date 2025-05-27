package Genesis::Env::Vars;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::UI;
use JSON::PP qw/encode_json/;

### Instance Methods {{{

# bosh_config_overrides - returns the bosh config overrides for the environment {{{
sub env_config_overrides {
	my ($self, $type) = @_;
	bug("No type specified for bosh config overrides") unless $type;
	my $overrides = $self->lookup('bosh-configs.$type', {});
	# TODO: Need to figure out where to find these overrides
	return $overrides;
}

# }}}
# director_config_overrides - returns the director config overrides for the environment {{{
sub director_config_overrides {
	my $self = shift;
	my $overrides = $self->director_exodus_lookup(['bosh-config/cloud' => '.'], {});
	return $overrides;
}

# }}}

## Secrets Plan
# is_vaultified - returns true if the environment is vaultified {{{
sub is_vaultified {
	my $self = shift;
	return $self->_memoize('__is_vaultified', sub {

		# Short circuit if we don't meed minimum requirements
		return 0 unless $self->feature_compatibility('3.0.0-rc.1')
			&& ! $self->use_create_env
			&& scalar($self->lookup('genesis.vaultify', 1));

		# If credhub is used explicitly, we can assume we're vaultified
		return 1 if $self->kit->uses_credhub;

		# We might still be using credhub, so check each blueprint file for
		# occurances of 'variables' blocks.  Return on finding at least one.
		my @files = map {
			my $f = $_;
			$f =~ /^\// ? $_ : $self->kit->path($_)
		} $self->kit_files;
		push (@files, $self->actual_environment_files);
		for my $file (@files) {
			# Make sure we're using the top path for relative files
			$file = $self->path($file) unless ($file =~ m#^/#);

			my $content = slurp($file) =~ s/\A---\n//r;
			my @pages = split(/\n---\n/,$content);
			for my $page (@pages) {
				if ($page =~ /^- /) {
					# Go-patch-based arrays file - spruce can't handle these, so need to
					# convert to hash format
					$page = "__ops__:\n$page";
				}
				my $data = load_yaml($page);
				next unless $data;
				return 1 if $data->{variables};
				if (exists $data->{__ops__}) {
					return 1 if grep {
						$_->{path} =~ /^\/variables\??\// &&
						$_->{type} ne 'remove'
					} @{$data->{__ops__}};
				}
			}
		}
		return 0;
	});
}

# }}}

# Environment Variables
# get_environment_variables - returns a hash of all environment variables pertaining to this Genesis::Env object {{{
sub get_environment_variables {
	my ($self, $hook) = @_;
	$hook //= '';

	my $env = $self->_memoize(sub {
		my $self = shift;
		# Set up the environment variables

		my %env;

		$env{GENESIS_ROOT}        = $self->path;
		$env{GENESIS_ENVIRONMENT} = $self->name;
		$env{GENESIS_TYPE}        = $self->type;
		$env{GENESIS_PREFIX_TYPE} = $ENV{GENESIS_PREFIX_TYPE} || 'none';

		my ($bin, $env_ref)       = $self->get_call_path_with_env();
		$env{GENESIS_CALL}        =
		$env{GENESIS_CALL_BIN}    = $bin;
		$env{GENESIS_ENV_REF}     = $env_ref;
		$env{GENESIS_CALL_ENV}    = join(' ', $bin, $env_ref);

		if ($ENV{GENESIS_COMMAND}) {
			$env{GENESIS_CALL_PREFIX} = sprintf("%s %s %s", $env{GENESIS_CALL_BIN}, $env_ref, $ENV{GENESIS_COMMAND});
			$env{GENESIS_CALL_FULL} = $env{GENESIS_PREFIX_TYPE} =~ /(^search|file)$/
				? $env{GENESIS_CALL_PREFIX}
				: sprintf("%s %s '%s'", $env{GENESIS_CALL},$ENV{GENESIS_COMMAND}, $self->name);
		}

		# Full param json to reconstitution by from_envvars method.
		$env{GENESIS_ENVIRONMENT_PARAMS} = encode_json($self->params);

		# Genesis minimum version (if specified)
		my $min_version = $self->lookup('genesis.min_version');
		$env{GENESIS_MIN_VERSION} = $min_version if $min_version;

		# Vault ENV VARS
		if (my $descriptor = $self->lookup('genesis.vault')) {
			$env{GENESIS_ENV_VAULT_DESCRIPTOR} = $descriptor;
		}
		$env{GENESIS_TARGET_VAULT} = $env{SAFE_TARGET} = $self->vault->ref;
		$env{GENESIS_VERIFY_VAULT} = $self->vault->connect_and_validate->verify || "";

		# Kit ENV VARS
		$env{GENESIS_KIT_NAME}                 = $self->kit->name;
		$env{GENESIS_KIT_VERSION}              = $self->kit->version;
		$env{GENESIS_KIT_PATH}                 = $self->kit->path;
		$env{GENESIS_MIN_VERSION_FOR_KIT}      = $self->kit->genesis_version_min();
		if ($self->exists) {
			$env{GENESIS_ENV_IAAS}               = $self->iaas();
			$env{GENESIS_ENV_SCALE}              = $self->scale();
			$env{GENESIS_ENV_KIT_OVERRIDE_FILES} = join(' ', $self->kit->env_override_files);
		}

		# Genesis v2.7.0 Secrets management
		# This provides GENESIS_{SECRETS,EXODUS,CI}_{MOUNT,BASE}
		# as well as GENESIS_{SECRETS,EXODUS,CI}_MOUNT_OVERRIDE
		for my $target (qw/secrets exodus ci/) {
			for my $target_type (qw/mount base/) {
				my $method = "${target}_${target_type}";
				$env{uc("GENESIS_${target}_${target_type}")} = $self->$method();
			}
			my $method = "${target}_mount";
			my $default_method = "default_$method";
			$env{uc("GENESIS_${target}_MOUNT_OVERRIDE")} = ($self->$method ne $self->$default_method) ? "true" : "";
		}
		$env{GENESIS_VAULT_ENV_SLUG} = $self->env_vault_slug;
		$env{GENESIS_VAULT_PREFIX} = # deprecated in v2.7.0
		$env{GENESIS_SECRETS_PATH} = # deprecated in v2.7.0
		$env{GENESIS_SECRETS_SLUG} = $self->secrets_slug;
		$env{GENESIS_SECRETS_SLUG_OVERRIDE} = $self->secrets_slug ne $self->default_secrets_slug ? "true" : "";
		$env{GENESIS_ROOT_CA_PATH} = $self->root_ca_path;

		# Credhub support
		my %credhub_env = $self->credhub_connection_env;
		$env{$_} = $credhub_env{$_} for keys %credhub_env;

		# BOSH support
		if ($self->use_create_env) {
			$env{GENESIS_USE_CREATE_ENV} = $self->use_create_env eq 'unknown' ? 'unknown' : 'true';
			for my $bosh_env (qw/ALIAS ENVIRONMENT CA_CERT CLIENT CLIENT_SECRET DEPLOYMENT/) {
				$env{"BOSH_$bosh_env"}=undef; # clear out any bosh variables
			}
		} else {
			$env{GENESIS_USE_CREATE_ENV} = "false";
			$env{BOSH_ALIAS} = $self->bosh_alias;
			if ($self->{__bosh} || grep {$_ eq 'bosh'} ($self->kit->required_connectivity($hook))) {
				my %bosh_env = $self->bosh->environment_variables;
				$env{$_} = $bosh_env{$_} for keys %bosh_env;
			}
		}

		return \%env;
	});

	if ($hook ne 'new' && $hook ne 'features' && !defined($env->{GENESIS_REQUESTED_FEATURES})) {
		$env->{GENESIS_REQUESTED_FEATURES} = join(' ', $self->features);
	}

	return %$env
}

# }}}

# }}}

1;

=head1 NAME

Genesis::Env::Vars

=head1 DESCRIPTION

This module handles environment variables and configuration overrides for Genesis environments.

=head1 METHODS

=head2 env_config_overrides($type)

Returns the BOSH config overrides for the environment of the specified type.

=head2 director_config_overrides()

Returns the director config overrides from exodus data.

=head2 is_vaultified()

Returns true if the environment uses vaultified secrets (Credhub variables).
Checks for feature compatibility, kit configuration, and presence of variables blocks.

=head2 get_environment_variables($hook)

Returns a hash of all environment variables pertaining to this Genesis::Env object.
Sets up variables for Genesis, Vault, Kit, BOSH, and Credhub operations.

=cut