package Genesis::CI::Shuttle::GCS;
use strict;
use warnings;

use base 'Genesis::CI::Shuttle';

### Class Methods {{{

# options_schema - the keys the GCS backend reads, and no others {{{
#
# There is no region and no endpoint here because the resource takes
# neither, which is the whole reason D105 asked for the block to be
# declared on its backend.  auth is the vault reference to this backend's
# credentials, the same key S3 declares and reads differently, and how one
# reference becomes the JSON key the emitted resource takes is the emitter's
# question rather than this file's.
sub options_schema {
	return {
		bucket    => {type => 'string', required => 1, description => 'The bucket the resources live in'},
		auth      => {type => 'string', description => 'Vault reference for the credentials'},
		image     => {type => 'string', default => 'cfcommunity/shuttle-resource', description => 'The resource image'},
		image_tag => {type => 'string', default => 'latest', description => 'The resource image tag'},
	};
}

# }}}
# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
