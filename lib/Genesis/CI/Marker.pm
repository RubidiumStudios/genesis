package Genesis::CI::Marker;

use strict;
use warnings;

use Genesis qw/bug/;

# The propagation marker, in one place.  D34 fixes it as the subject
# "[pipeline] control@<sha> -> <env>" on a deployment-branch commit, naming
# the control commit the branch now holds and the receiving environment, and
# the routing contract's provenance rules make it the only claim a branch
# makes about what it carries.  Everything that writes or reads that string
# goes through this module.
our $PREFIX = '[pipeline] control@';

# build - render the marker subject for one delivery {{{
#
# The sha is written exactly as it is handed over, because only the caller
# has a git handle and knows which abbreviation git resolved for it, and the
# environment is its own name rather than the deployment slug, which is the
# fourth provenance rule under D66.
sub build {
	my ($control_sha, $env) = @_;

	bug("Genesis::CI::Marker::build needs a control sha, got %s",
		defined $control_sha ? "'$control_sha'" : 'undef')
		unless defined $control_sha && $control_sha =~ /^[0-9a-f]{4,40}$/;
	bug("Genesis::CI::Marker::build needs an environment name")
		unless defined $env && length $env;

	return sprintf('%s%s -> %s', $PREFIX, $control_sha, $env);
}

# }}}

1;
