package Genesis::CI::Shuttle;
use strict;
use warnings;

use Genesis;

### Class Methods {{{

# options_schema - the keys this backend reads (abstract) {{{
#
# The second block declared as a custom_struct, and the smaller one.
# That type names the field that discriminates and maps each of its
# values to the module owning that shape.  The shape is the provider's,
# which is one class per value of the discriminator, each declaring the
# keys it reads, and a base that validates a block against whichever
# declaration the value selected.
#
# It is named options_schema rather than provider_options_schema because
# the readers that give the provider's method its longer name, which are
# describe, the per-key defaults, the help text, and the wizard, do not
# exist for a shuttle backend, so carrying that prefix here would name
# the method after readers it does not have.
sub options_schema {
	my ($self) = @_;
	bug("Subclass '%s' must implement options_schema()", ref($self) || $self);
}

# }}}
# validate_config - the backend's rules for its own block {{{
#
# The default validates the block against the backend's own declaration,
# so a backend with no cross-field rule writes only that declaration and
# still gets the generic pass, its type checks, its defaults, and the
# error text every other block gets.  A backend with a rule a declaration
# cannot state overrides this and calls SUPER first, as a provider does,
# because the declaration is the floor rather than a subset of what is
# wanted checked.
#
# The discriminator names the key the parent declared to choose this
# class, which no fragment declares, so it is handed through as the one
# key the walk below leaves alone.
sub validate_config {
	my ($class, $config, $path, $discriminator) = @_;

	return $config->validate_subtree(
		$path, $class->options_schema,
		ignore => [$discriminator // 'backend']
	);
}

# }}}
# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
