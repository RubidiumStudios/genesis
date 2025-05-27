package Genesis::Env::Vault;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::UI;
use Service::Vault;

### Instance Methods {{{

# vault - get the vault instance for the environment, or default to the top level vault {{{
sub vault {
	my $ref = $_[0]->_memoize(sub {
		my ($self) = @_;
		my $vault_info = $self->get_ancestral_vault();
		return $self->top->vault() unless $vault_info;

		my $details = Service::Vault->parse_vault_descriptor($vault_info);

		return Service::Vault::Remote->rebind()
			if (
				in_callback &&
				$ENV{GENESIS_TARGET_VAULT} &&
				$ENV{GENESIS_TARGET_VAULT} eq $details->{url}
			);

		my %filter = ();
		$filter{verify} = ($details->{verify} && $details->{tls} ? 1 : 0 ) if $details->{tls};
		$filter{namespace} = $details->{namespace} || '';
		$filter{strongbox} = $details->{strongbox};

		return Service::Vault::Remote->attach(
			url => $details->{url},
			alias => $details->{alias},
			%filter
		);
	});
	return $ref;

}
# }}}
# with_vault - ensure this environment is able to connect to the Vault server {{{
sub with_vault {
	my $self = shift;
	$ENV{GENESIS_SECRETS_MOUNT} = $self->secrets_mount();
	$ENV{GENESIS_EXODUS_MOUNT} = $self->exodus_mount();
	bail("No vault specified or configured.")
		unless $self->vault;
	return $self;
}

# }}}
# get_ancestral_vault {{{
sub get_ancestral_vault {
	my ($self) = @_;

	my $vault_info = scalar($self->lookup_unevaled('genesis.vault', undef));
	bail(
		"Expecting #C{genesis.vault} to be a singular string value, not a ".lc(ref($vault_info))
	) if ref($vault_info);
	bail(
		"Cannot use spruce operator to specify #C{genesis.vault_info}"
	)	if $vault_info && $vault_info =~ /^\(\(/;
	return $vault_info;
}

# }}}

# }}}

1;

=head1 NAME

Genesis::Env::Vault

=head1 DESCRIPTION

This module handles Vault integration for Genesis environments.

=head1 METHODS

=head2 vault()

Gets the vault instance for the environment, or defaults to the top level vault.
Handles rebinding for callbacks and attachments with proper filters.

=head2 with_vault()

Ensures this environment is able to connect to the Vault server.
Sets up required environment variables and validates vault connectivity.

=head2 get_ancestral_vault()

Retrieves vault information from the environment's ancestry chain.
Validates that the vault info is a string and not a spruce operator.

=cut