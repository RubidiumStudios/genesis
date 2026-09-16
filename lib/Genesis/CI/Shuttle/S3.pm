package Genesis::CI::Shuttle::S3;
use strict;
use warnings;

use base 'Genesis::CI::Shuttle';

### Class Methods {{{

# options_schema - the keys the S3 backend reads {{{
#
# The region and the endpoint live here rather than on the block, because
# S3 is the backend that reads them.  auth is the vault reference to this
# backend's credentials, which is what D23 and the configuration surface
# both call it; how that reference becomes the two credentials the
# emitted resource takes is FWT-1153's question and not this file's.
sub options_schema {
	return {
		bucket    => {type => 'string', required => 1, description => 'The bucket the resources live in'},
		region    => {type => 'string', description => 'The bucket region'},
		endpoint  => {type => 'string', description => 'A non-default endpoint'},
		auth      => {type => 'string', description => 'Vault reference for the credentials'},
		image     => {type => 'string', default => 'cfcommunity/shuttle-resource', description => 'The resource image'},
		image_tag => {type => 'string', default => 'latest', description => 'The resource image tag'},
	};
}

# }}}
# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
