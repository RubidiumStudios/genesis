package Genesis::CI::Shuttle::S3;
use strict;
use warnings;

use base 'Genesis::CI::Shuttle';
use Genesis::Config ();

### Class Methods {{{

# The two keys an S3 credential is, each read from auth's path under its own name by default.
my @AUTH_KEYS = qw/access_key_id secret_access_key/;

# options_schema - the keys the S3 backend reads {{{
#
# The region and the endpoint live here rather than on the block, because
# S3 is the backend that reads them.  auth is this backend's credential: a
# path, or each of its keys where it is held (D171).
sub options_schema {
	return {
		bucket    => {type => 'string', required => 1, description => 'The bucket the resources live in'},
		region    => {type => 'string', description => 'The bucket region'},
		endpoint  => {type => 'string', description => 'A non-default endpoint'},
		auth      => {type => 'any', check => \&_auth_rule, description => 'The credential: the vault secret holding access_key_id and secret_access_key, or each as <path>:<key>'},
		tls_skip_verify => {type => 'boolean', default => Genesis::Config::FALSE, description => "Skip verifying the store's TLS certificate"},
		image     => {type => 'string', default => 'klaue/shuttle-resource', description => 'The resource image'},
		image_tag => {type => 'string', default => 'latest', description => 'The resource image tag'},
	};
}

# }}}
# auth_components - where each key of the credential is held, as a vault reference (D171) {{{
sub auth_components {
	my ($class, $auth) = @_;
	return {} unless defined $auth && (ref($auth) eq 'HASH' || (!ref($auth) && length $auth));

	# A path alone is a block naming it.
	$auth = {path => $auth} unless ref($auth);
	return {map {($_ => $auth->{$_} // "$auth->{path}:$_")} @AUTH_KEYS};
}

# }}}
# }}}
### Private Functions {{{

# _auth_rule - auth is a path, or a block that can give both keys and nothing else {{{
sub _auth_rule {
	my ($auth) = @_;
	return undef unless defined $auth;
	return length($auth) ? undef : 'is empty; name the vault secret holding the credential'
		unless ref($auth);
	return sprintf('is neither a path nor a block naming one; give the vault secret holding %s, '.
		'or each as <path>:<key>', join(' and ', @AUTH_KEYS)) unless ref($auth) eq 'HASH';

	my %takes = map {($_ => 1)} @AUTH_KEYS, 'path';
	if (my @stray = grep {!$takes{$_}} sort keys %$auth) {
		return sprintf('%s is not part of the credential, which takes %s',
			join(', ', @stray), join(' and ', @AUTH_KEYS));
	}
	my @missing = grep {!defined $auth->{path} && !defined $auth->{$_}} @AUTH_KEYS;
	return sprintf('needs %s: name the secret holding %s with #C{path}, or give each as <path>:<key>',
		join(' and ', @missing), @missing > 1 ? 'them' : 'it') if @missing;
	return undef;
}

# }}}
# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
