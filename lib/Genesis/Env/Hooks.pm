package Genesis::Env::Hooks;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::Term;
use Genesis::UI;

### Instance Methods {{{

# Kit Components
# kit_files - get list of yaml files from the kit to be used to merge the manifest {{{
sub kit_files {
	my ($self, $absolute) = @_;
	$absolute = !!$absolute; #booleanify it.
	$self->{__kit_files}{$absolute} ||= [$self->kit->source_yaml_files($self, $absolute)];
	return @{$self->{__kit_files}{$absolute}};
}

# }}}
# can_be_entombed - returns true if the environment can be entombed {{{
sub can_be_entombed {
	my $self = shift;
	$self->feature_compatibility('3.0.0-rc.1')
	&& ! $self->use_create_env
	&& scalar($self->lookup('genesis.entomb', 1));
}

# }}}

# }}}

1;

=head1 NAME

Genesis::Env::Hooks

=head1 DESCRIPTION

This module provides hook and kit-related functionality for Genesis environments.

=head1 METHODS

=head2 kit_files($absolute)

Returns the list of YAML files from the kit to be used for manifest merging.
If $absolute is true, returns absolute paths; otherwise returns relative paths.

=head2 can_be_entombed()

Returns true if the environment can be entombed (feature compatibility >= 3.0.0-rc.1,
not a create-env deployment, and genesis.entomb is set).

=cut