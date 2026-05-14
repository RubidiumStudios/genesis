package Genesis::Env::Manifest::EntombedSelf;

# Manifest entombed against the deployed env's OWN Credhub instead of
# the parent director's Credhub.
#
# Use case: post-deploy operations that upload env-file data (e.g.
# bosh-configs.director-cpi.cpis) to the newly-deployed BOSH director.
# Those uploads must carry credhub-var references that the new
# director's own Credhub can resolve — not the parent's, where the
# standard Manifest::Entombed pass landed the values.
#
# Inherits every behavior from Manifest::Entombed and only overrides
# credhub_target() to point at $env->get_target_bosh({self => 1})->credhub.

use strict;
use warnings;

use parent 'Genesis::Env::Manifest::Entombed';

sub description {
	"Manifest with secrets entombed into the deployed director's own ".
	"Credhub (instead of the parent director's).  Used for self-uploaded ".
	"post-deploy configs such as bosh-configs.director-cpi.cpis."
}

# credhub_target - the deployed director's own credhub.
sub credhub_target {
	my $self = shift;
	require Service::Credhub;
	return Service::Credhub->from_bosh(
		$self->env->get_target_bosh({self => 1})
	);
}

1;
# vim: ts=2 sw=2 sts=2 noet
