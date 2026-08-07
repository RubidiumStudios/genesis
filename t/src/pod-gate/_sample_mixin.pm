# Error-path fixture: a mixin.  No package declaration, filename starts with
# an underscore.  The gate has to recognise these -- they are documented in
# their own .pod but their subs land in whichever package does them, so the
# usual "is this sub documented in this module's .pod" question is asked
# against a different file.

use strict;
use warnings;

sub mixed_in_method {
	my ($self) = @_;
	return $self->{value};
}

sub _mixed_in_helper {
	return 1;
}

1;
