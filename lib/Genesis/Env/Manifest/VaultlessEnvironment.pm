package Genesis::Env::Manifest::VaultlessEnvironment;

use strict;
use warnings;

use base 'Genesis::Env::Manifest';

use Genesis qw/workdir/;

sub description { "Environment files only (no kit components), evaluated with no vault - vault values left as their own text" }

sub source_files {
	my $self = shift;
	return [
		$self->builder->environment_files(),
	]
}

# The environment's files are all this merge reads.
sub signature { $_[0]->env->signature }

sub merge_options {
	return {
		eval => 'adaptive'
	}
}

# Vault is made unreachable rather than redacted.  A vault operator that
# answered REDACTED would be indistinguishable from text once a concat had
# taken it in, where one that fails is deferred by the adaptive merge and its
# own text travels with every value built from it.  With no address, no token,
# and a home holding no saferc, spruce fails at the client and never reaches
# the network.
sub merge_environment {
	return {
		VAULT_ADDR  => undef,
		VAULT_TOKEN => undef,
		SAFE_TARGET => undef,
		REDACT      => undef,
		HOME        => workdir('vaultless_home'),
	}
}

sub _merge {
	my $self = shift;
	my ($data, $file, $warnings, $errors) = $self->builder->merge(
		$self,
		$self->source_files,
		$self->merge_options,
		$self->merge_environment
	);
	return ($data,$file);
}

1;
