package Genesis::Env::OCFP;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::Term;
use Genesis::UI;

### Instance Methods {{{

# is_ocfp - returns true if the environment is an OCFP environment {{{
sub is_ocfp {
	my $self = shift;
	return $self->has_feature('ocfp')
}

# }}}
# ocfp_type - returns the type of OCFP environment {{{
sub ocfp_type {
	my $self = shift;
	return '' unless $self->is_ocfp;
	my ($type) = $self->name =~ m/^.*-(mgmt|ocf)$/;
	return $type || 'unknown';
}

# }}}
# ocfp_env - returns the OCFP environment name used in vault {{{
sub ocfp_env {
	my $self = shift;
	$self->name =~ s/^(.*)-(mgmt|ocf)/$1\/$2/r;
}

# }}}
#	ocfp_config - returns the OCFP configuration for the environment {{{
sub ocfp_config {
	my ($self,$path) = @_;
	my $config= $self->_memoize(sub {
		my $ocfp_config = $self->vault->get_path($self->ocfp_config_base);
	});
}

# }}}
# ocfp_config_lookup - look up a value from the OCFP configuration {{{
sub ocfp_config_lookup {
	my ($self, $key, $default) = @_;
	return struct_lookup($self->ocfp_config, $key, $default);
}

# }}}

# }}}

1;

=head1 NAME

Genesis::Env::OCFP

=head1 DESCRIPTION

This module provides Open Cloud Foundry Platform (OCFP) functionality for
Genesis environments.

=head1 METHODS

=head2 is_ocfp()

Returns true if the environment is an OCFP environment (has the 'ocfp' feature).

=head2 ocfp_type()

Returns the type of OCFP environment ('mgmt', 'ocf', or 'unknown').

=head2 ocfp_env()

Returns the OCFP environment name used in vault.

=head2 ocfp_config($path)

Returns the OCFP configuration for the environment.

=head2 ocfp_config_lookup($key, $default)

Looks up a value from the OCFP configuration.

=cut