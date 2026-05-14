package Genesis::Env::Secrets::Entombment;

# Unified credhub entombment primitives.
#
# Three layers of API:
#
#   Naming layer:
#     credhub_var_name($path, $key, $value, $prefix)
#       Pure function.  Returns a deterministic credhub variable name
#       from the inputs.  Used wherever Genesis decides "what name
#       should this secret have in credhub."
#
#   Write layer:
#     put_secret($credhub, $cred_name, $value)
#       Idempotent put.  Checks existing value (via credhub's cache
#       when preloaded), writes only when missing or changed, verifies
#       the write succeeded.  Returns one of:
#         'new'      first-time write
#         'exists'   value already matched; no write made
#         'altered'  value changed; write made
#         'failed'   write made but verify did not match
#
#     entomb_one_secret($credhub, $path, $key, $value, $prefix)
#       Composition of credhub_var_name + put_secret.  Returns
#       ("(($var))", $action) for inline substitution callers.
#
#     prime_credhub_cache($credhub)
#       Idempotent preload of the credhub cache so subsequent
#       put_secret existing-checks are O(1) cache hits instead of
#       O(N) subprocesses.  Always called by the bulk APIs;
#       per-value callers should call this themselves before a batch.
#
# Higher layers (local-vault lifecycle, bulk populate, and
# full-manifest entomb-and-lookup) build on these primitives and
# are introduced in subsequent tiers of this module.

use strict;
use warnings;

use Exporter 'import';
use Digest::SHA qw/sha1_hex/;

our @EXPORT_OK = qw(
	credhub_var_name
	put_secret
	entomb_one_secret
	prime_credhub_cache
	make_local_vault
	shutdown_local_vault
	populate_local_vault
);

our $DEFAULT_PREFIX = 'genesis-entombed/';

# credhub_var_name - deterministic credhub variable name {{{
#
# Composes a credhub variable name from (path, key, value, prefix)
# such that the same inputs always produce the same name, and any
# change to the value produces a different sha suffix.
#
#   credhub_var_name('secret/foo', 'password', 's3cret', '/cpi/')
#     => "/cpi/secret/foo--password--abc12345"
#
# The 8-character sha1 suffix lets multiple distinct values for the
# same path:key coexist in credhub (e.g. during a rotation) without
# colliding.
sub credhub_var_name {
	my ($path, $key, $value, $prefix) = @_;
	$prefix //= $DEFAULT_PREFIX;
	my $sha = substr(sha1_hex("${path}--${key}--${value}"), 0, 8);
	return "${prefix}${path}--${key}--${sha}";
}

# }}}
# put_secret - idempotent put returning the action taken {{{
#
# Writes $value to $cred_name in $credhub only when it differs from
# what's currently there.  Returns one of 'new' | 'exists' | 'altered'
# | 'failed'.  Callers that want batch efficiency should prime the
# credhub cache via prime_credhub_cache() so the existing-check is
# a single in-memory lookup instead of a per-call subprocess.
sub put_secret {
	my ($credhub, $cred_name, $value) = @_;
	my $existing = $credhub->get($cred_name);
	return 'exists' if defined($existing) && $existing eq $value;

	$credhub->set($cred_name, $value);

	my $verify = $credhub->get($cred_name);
	return 'failed' if !defined($verify) || $verify ne $value;
	return defined($existing) ? 'altered' : 'new';
}

# }}}
# entomb_one_secret - name + put in one call {{{
#
# Convenience wrapper that combines credhub_var_name and put_secret
# for callers that want to entomb a single (path, key, value) without
# managing the var name explicitly.  Returns a 2-tuple of the
# parenthesized credhub-var reference (suitable for direct YAML
# substitution) and the action taken.
sub entomb_one_secret {
	my ($credhub, $path, $key, $value, $prefix) = @_;
	my $name   = credhub_var_name($path, $key, $value, $prefix);
	my $action = put_secret($credhub, $name, $value);
	return ("((${name}))", $action);
}

# }}}
# prime_credhub_cache - idempotent preload helper {{{
#
# Calls $credhub->preload unless it's already preloaded.  Safe to
# call repeatedly.  Returns $credhub for chaining.
sub prime_credhub_cache {
	my ($credhub) = @_;
	$credhub->preload unless $credhub->is_preloaded;
	return $credhub;
}

# }}}
# make_local_vault - spin up an in-memory vault scoped to one entombment pass {{{
#
#   my $lv = make_local_vault(env => $env);                # auto-named
#   my $lv = make_local_vault(name => 'foo-scratch');      # explicit name
#
# Wraps Service::Vault::Local->create.  When `env` is given, the
# vault name defaults to "${env_name}-entomb" so the caller doesn't
# have to invent a unique handle.  Returns the local vault object.
sub make_local_vault {
	my (%opts) = @_;
	require Service::Vault::Local;
	my $name = $opts{name};
	if (!defined $name) {
		my $env = $opts{env};
		my $env_name = $env && $env->can('name') ? $env->name : 'genesis';
		$name = "${env_name}-entomb";
	}
	return Service::Vault::Local->create($name);
}

# }}}
# shutdown_local_vault - tear down a local vault from make_local_vault {{{
#
# Idempotent; no-op when given undef.  Safe to call from cleanup paths.
sub shutdown_local_vault {
	my ($local_vault) = @_;
	return unless defined $local_vault;
	eval { $local_vault->shutdown };
	return;
}

# }}}
# populate_local_vault - bulk path -> credhub-var substitution {{{
#
#   populate_local_vault(
#     paths       => { 'secret/db:password' => [...refs...], ... },
#     vault       => $source_vault,
#     credhub     => $target_credhub,
#     prefix      => '/cpi/',
#     local_vault => $local_vault,
#     on_action   => sub { my (%info) = @_; ... },   # optional callback
#   );
#
# For each path:key in `paths`:
#   1. Fetch the value from `vault`.
#   2. Entomb it into `credhub` via entomb_one_secret (which uses
#      the deterministic credhub_var_name and idempotent put_secret).
#   3. Set the corresponding ((credhub-var)) entry in `local_vault`
#      so subsequent spruce evaluation substitutes credhub indirection
#      for the original vault reference.
#
# `credhub` is preloaded once at entry so every put_secret existing-
# check is an in-memory cache hit instead of a subprocess.
#
# `on_action`, if provided, is called once per path:key with
# (path => , key => , value => , credhub_var => , action => ) for
# progress reporting.
sub populate_local_vault {
	my (%opts) = @_;
	my $paths       = $opts{paths};
	my $vault       = $opts{vault};
	my $credhub     = $opts{credhub};
	my $prefix      = $opts{prefix};
	my $local_vault = $opts{local_vault};
	my $on_action   = $opts{on_action};

	return unless $paths && ref($paths) eq 'HASH' && %$paths;

	prime_credhub_cache($credhub);

	for my $path_key (sort keys %$paths) {
		my ($path, $key) = split /:/, $path_key, 2;
		my $value = $vault->get($path, $key);

		my ($credhub_var, $action) = entomb_one_secret(
			$credhub, $path, $key, $value, $prefix
		);
		$local_vault->set($path, $key, $credhub_var);
		$on_action->(
			path        => $path,
			key         => $key,
			value       => $value,
			credhub_var => $credhub_var,
			action      => $action,
		) if $on_action;
	}
	return;
}

# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
