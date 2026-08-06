package Genesis::Env::Secrets::Entombment;


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

# credhub_var_name - deterministic credhub variable name, keyed on the value so a rotation gets a new name {{{
sub credhub_var_name {
	my ($path, $key, $value, $prefix) = @_;
	$prefix //= $DEFAULT_PREFIX;
	my $sha = substr(sha1_hex("${path}--${key}--${value}"), 0, 8);
	return "${prefix}${path}--${key}--${sha}";
}

# }}}
# put_secret - idempotent put, writing only on a difference and returning the action taken {{{
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
# entomb_one_secret - name and put in one call, returning the ((credhub-var)) reference and the action {{{
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
# make_local_vault - spin up a vault scoped to one entombment pass, named for the env unless told otherwise {{{
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
# populate_local_vault - bulk path -> credhub-var substitution, priming the credhub cache once up front {{{
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
