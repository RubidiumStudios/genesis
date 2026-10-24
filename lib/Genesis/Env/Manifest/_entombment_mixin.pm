# Mixin to provide entombment functionality - require to use;

use Genesis qw/info debug bail lines uniq/;
use Genesis::Term qw/terminal_width wrap csprintf/;

use Service::Vault;
use Service::Vault::Local;
use Service::Credhub;
use Genesis::Env::Secrets::Entombment qw(
	credhub_var_name put_secret
	make_local_vault prime_credhub_cache
);

sub local_vault {
	return make_local_vault(env => $_[0]->env);
}

# credhub_target - which credhub the entombment writes into.
#
# Defaults to the env's primary credhub (the BOSH director that
# deploys this env, or the env's own credhub if it is a director).
# Subclasses such as Manifest::EntombedSelf override this to target
# a different credhub (e.g. the deployed env's own credhub for
# post-deploy self-uploaded configs).
sub credhub_target {
	return $_[0]->env->credhub;
}

sub _entomb_secrets {
	my ($self, $data) = @_;

	return 1 if $self->{entombed}; # don't do this more than once...

	$self->env->notify("entombing secrets into Credhub for enhanced security...");
	my $src_vault = $self->env->vault;
	info (
		{pending => 1},
		"[[  - >>determining vault paths used by manifest from %s...",
		$src_vault->name
	);
	$self->builder->unevaluated(); # Prewarm cache
	my $secret_paths = $self->get_vault_paths(notify=>0);
	my $secrets_count = scalar(keys %$secret_paths);
	if ($secrets_count) {
		info "found %d paths.", $secrets_count;
		my %secret_keys = ();

		info (
			{pending => 1},
			"[[  - >>retrieving secrets from used vault paths...",
		);
		my %canonical;
		for (keys %$secret_paths) {
			my ($s,$k) = split ":", $_, 2;
			$s =~ s#^/?#/#; # make sure the secret path starts with a /
			push(@{$secret_keys{$s}}, $k);
			# safe trims one trailing and one leading slash from a path and then
			# collapses repeated slashes, so this is the secret safe reads for
			# the spelling.  The spelling still names the CredHub variable.
			$canonical{$s} = $s =~ s#/$##r =~ s#^/##r =~ s#/{2,}#/#gr;
		}

		# One export reads every referenced path, decoded from its raw text so
		# that a value that is not a string is seen as one.  A failed export
		# leaves each path to be read on its own below, where the read says
		# why it failed or finds nothing stored.
		my ($text, $rc, $err) = $src_vault->query(
			{stderr => 0, redact_output => 1, exact => 1}, "export", keys %secret_keys
		);
		debug(
			"safe export of the referenced paths failed, so each is read on its own: %s",
			$err || "exit code $rc"
		) if $rc;
		my ($export, $typed) = $rc ? ({}, {}) : Service::Vault::decode_export_text($text);

		# safe get gives every value of a typed path as the text a flat export
		# gives, so a referenced typed path is read again whole and all its
		# fields come from that one read.  A path the export left out is read
		# the same way, since older safe exports dropped one of two paths when
		# one name begins with the other.  Only referenced paths are read, so a
		# typed value nobody references, such as the numeric pid an older
		# Genesis writes into its network lock, cannot stop entombment.
		my %secret_values;
		for my $path (uniq(sort values %canonical)) {
			$secret_values{$path} = (defined($export->{$path}) && !$typed->{$path})
				? $export->{$path}
				: $src_vault->read_flattened_secret($path);
		}

		# Every reference resolves before the local vault starts or anything
		# is written, so a missing value leaves nothing half entombed.
		for my $secret (sort keys %secret_keys) {
			for my $key (sort @{$secret_keys{$secret}}) {
				my $value = $secret_values{$canonical{$secret}}{$key};
				bail(
					"Manifest references vault path #C{%s:%s} which has no value in ".
					"the vault -- populate it (or fix the reference) and redeploy.",
					$secret, $key
				) unless defined($value) && length($value);
			}
		}
		info ("#g{done!}");

		my $local_vault = $self->_setup_local_vault();

		my $credhub = $self->credhub_target();
		prime_credhub_cache($credhub);

		#Design decision: use value-type credhub for each key, and only populate what is needed.
		my $base_path = $self->env->secrets_base();
		my $idx = 0;
		my $w = length("$secrets_count");
		my $entombment_prefix = "genesis-entombed/"; # can be set to another value to prevent conflicts if needed
		info(
			"[[  - >>copying Vault values to Credhub: #c{%s} => #B{%s}:",
			$base_path, $credhub->base().($entombment_prefix ? "$entombment_prefix" : "")
		);

		my $previous_lines=0;
		my %results = (new => 0, failed => 0, altered => 0, 'exists' => 0);
		for my $secret (sort keys %secret_keys) {
			my $vault_label = $secret;
			$vault_label =~ s/^$base_path(.*)/csprintf("#C{$1}")/e;
			my $cred_path = $secret;
			$cred_path =~ s/^$base_path//;
			$cred_path =~ s#^/#_/#;
			for my $key (sort @{$secret_keys{$secret}}) {
				my $value = $secret_values{$canonical{$secret}}{$key};
				my ($credhub_var, $secret_sha, $action, $action_color, $existing) = $self->_entomb_secret_for_vault(
					$local_vault, $secret, $key, $value, $credhub, $cred_path, $entombment_prefix
				);
				$results{$action} += 1;
				my $msg = wrap(sprintf(
					"[[    [%*d/%*d] >>%s:#c{%s} #Kk{[sha1: }#Wk{%s}#Kk{]} #G{=>} #B{%s} ...#%s{%s}",
					$w, ++$idx, $w, $secrets_count, "#y{$vault_label}", $key, $secret_sha,
					$credhub_var, $action_color, $action
				), terminal_width);
				print STDERR "\r[A[2K" for (1..$previous_lines);
				info $msg;
				$previous_lines=($existing && $existing eq $value) ? scalar(lines($msg)) : 0;
			}
		}
		print STDERR "\r[A[2K" for (1..$previous_lines);
		# FIXME: use pretty_duration and style consistent with *_secrets output
		info(
			"[[  - >>$idx of $secrets_count secrets processed: %s new, %s already exist, %s altered, %s failed",
			@results{('new','exists','altered','failed')}
		);

		bail(
			"Failed to entomb one or more secrets into Credhub.  This may be due ".
			"to a bug in Genesis, communication or authentication error with ".
			"Credhub, or a value that Credhub can't support.\n\n".
			"Please try again without the --entomb option if used, or if deploying, ".
			"use the --no-entomb option, if this persists.\n\n".
			"Please contact the Genesis team, or open a issue on ".
			"#Bu{%s/issues/new}",
			$Genesis::GITHUB
		) if ($results{failed});

		$self->{entombed} = 1;
		return 1
	} else {
		info "no vault paths in use.\n";
		return 0
	}
}

sub _setup_local_vault {
	my ($self) = @_;
	info (
		{pending => 1},
		"[[  - >>starting local in-memory vault to hold references to Credhub...",
	);
	my $local_vault = $self->local_vault;
	info ("#g{done!}");
	return $local_vault;
}

sub _entomb_secret_for_vault {
	my ($self, $local_vault, $vault_path, $key, $value, $credhub, $cred_path, $entombment_prefix) = @_;
	$entombment_prefix //= 'genesis-entombed/';

	# Capture the pre-write value for display before put_secret may
	# update the credhub cache.
	my $cred_name = credhub_var_name($cred_path, $key, $value, $entombment_prefix);
	my $existing  = $credhub->get($cred_name);
	my $action    = put_secret($credhub, $cred_name, $value);

	# 8-char sha for display (the full cred_name already embeds it,
	# but the rendered output prints it separately).
	my ($secret_sha) = $cred_name =~ /--([0-9a-f]{8})$/;

	my %action_colors = (
		new     => 'gi',
		exists  => 'yi',
		altered => 'ri',
		failed  => 'Yr',
	);
	my $action_color = $action_colors{$action};

	my $credhub_var = "(($cred_name))";
	$local_vault->set($vault_path, $key, $credhub_var) if $local_vault;
	return ($credhub_var, $secret_sha, $action, $action_color, $existing);
}

sub _entomb_secret {
	return shift->_entomb_secret_for_vault(@_) if scalar(@_) > 6; # Backwards compatibility
	my ($self, $credhub, $path, $key, $value, $prefix) = @_;
	$prefix //= 'genesis-entombed/';

	my $cred_name = credhub_var_name($path, $key, $value, $prefix);
	my $existing  = $credhub->get($cred_name);
	my $action    = put_secret($credhub, $cred_name, $value);
	my ($secret_sha) = $cred_name =~ /--([0-9a-f]{8})$/;

	my $credhub_var = "(($cred_name))";
	my $color = {new => "gi", exists => "yi", altered => "ri", failed => "Yr"}->{$action};
	return ($credhub_var, $secret_sha, $action, $color, $existing);
}

1;
