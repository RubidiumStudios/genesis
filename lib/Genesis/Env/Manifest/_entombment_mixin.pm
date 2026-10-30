# Mixin to provide entombment functionality - require to use;

use Genesis qw/info bail read_json_from lines/;
use Genesis::Term qw/terminal_width wrap csprintf/;

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

	# A read-only render names references and writes nothing, so its reader
	# reports the counts itself (D123) and the progress here stays silent.
	my $writes = $self->builder->writes_credhub;
	my $say    = $writes ? sub {info(@_)} : sub {};

	$self->env->notify("entombing secrets into Credhub for enhanced security...") if $writes;
	my $src_vault = $self->env->vault;
	$say->(
		{pending => 1},
		"[[  - >>determining vault paths used by manifest from %s...",
		$src_vault->name
	);
	$self->builder->unevaluated(); # Prewarm cache
	my $secret_paths = $self->get_vault_paths(notify=>0);
	my $secrets_count = scalar(keys %$secret_paths);
	if ($secrets_count) {
		$say->("found %d paths.", $secrets_count);
		my %secret_keys = ();

		$say->(
			{pending => 1},
			"[[  - >>retrieving secrets from used vault paths...",
		);
		for (keys %$secret_paths) {
			my ($s,$k) = split ":", $_, 2;
			$s =~ s#^/?#/#; # make sure the secret path starts with a /
			push(@{$secret_keys{$s}}, $k)
		}
		# A read-only render stands in for a deploy that has not yet created
		# every secret, so only the paths the vault holds are read (D129).
		my @held = $writes ? keys %secret_keys : grep {$src_vault->has($_)} keys %secret_keys;
		my %secret_values = @held ? %{
			scalar(read_json_from(
				$src_vault->query({redact_output => 1},"export", @held)
			))
		} : ();
		# BUG FIX for safe export on similar names
		for (map {substr($_,1)} @held) {
			$secret_values{$_} = $src_vault->get("/$_")
				unless (defined($secret_values{$_}));
		}
		$say->("#g{done!}");

		my $local_vault = $self->_setup_local_vault();

		my $credhub = $self->credhub_target();
		$writes ? prime_credhub_cache($credhub) : eval {prime_credhub_cache($credhub)};

		#Design decision: use value-type credhub for each key, and only populate what is needed.
		my $base_path = $self->env->secrets_base();
		my $idx = 0;
		my $w = length("$secrets_count");
		my $entombment_prefix = "genesis-entombed/"; # can be set to another value to prevent conflicts if needed
		$say->(
			"[[  - >>copying Vault values to Credhub: #c{%s} => #B{%s}:",
			$base_path, $credhub->base().($entombment_prefix ? "$entombment_prefix" : "")
		);

		# The lines an unchanged value prints are erased on a terminal and
		# only there, since the codes that erase them are noise in a log.
		my $tty = -t STDERR;
		my $previous_lines=0;
		my %results = (new => 0, failed => 0, altered => 0, 'exists' => 0);
		for my $secret (sort keys %secret_keys) {
			my $vault_label = $secret;
			$vault_label =~ s/^$base_path(.*)/csprintf("#C{$1}")/e;
			my $cred_path = $secret;
			$cred_path =~ s/^$base_path//;
			$cred_path =~ s#^/#_/#;
			for my $key (sort @{$secret_keys{$secret}}) {
				my $value = $secret_values{substr($secret,1)}{$key};
				# What the deploy would generate or must be given stands in
				# the read-only render as a placeholder its reader names.
				if (!$writes && !(defined($value) && length($value))) {
					$local_vault->set($secret, $key,
						($self->builder->{secret_placeholders} || {})->{"$secret:$key"} // '<missing>');
					$results{missing}++;
					++$idx;
					next;
				}
				bail(
					"Manifest references vault path #C{%s:%s} which has no value in ".
					"the vault -- populate it (or fix the reference) and redeploy.",
					$secret, $key
				) unless defined($value) && length($value);
				my ($credhub_var, $secret_sha, $action, $action_color, $existing) = $self->_entomb_secret_for_vault(
					$local_vault, $secret, $key, $value, $credhub, $cred_path, $entombment_prefix
				);
				$results{$action} += 1;
				++$idx;
				next unless $writes;
				my $msg = wrap(sprintf(
					"[[    [%*d/%*d] >>%s:#c{%s} #Kk{[sha1: }#Wk{%s}#Kk{]} #G{=>} #B{%s} ...#%s{%s}",
					$w, $idx, $w, $secrets_count, "#y{$vault_label}", $key, $secret_sha,
					$credhub_var, $action_color, $action
				), terminal_width);
				print STDERR "\r[A[2K" for (1..$previous_lines);
				info $msg;
				$previous_lines=($tty && $existing && $existing eq $value) ? scalar(lines($msg)) : 0;
			}
		}
		print STDERR "\r[A[2K" for (1..$previous_lines);
		$self->builder->{entombment_results} = {%results, total => $idx};
		# FIXME: use pretty_duration and style consistent with *_secrets output
		$say->(
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
		$self->builder->{entombment_results} = {total => 0};
		$say->("no vault paths in use.\n");
		return 0
	}
}

sub _setup_local_vault {
	my ($self) = @_;
	my $writes = $self->builder->writes_credhub;
	info (
		{pending => 1},
		"[[  - >>starting local in-memory vault to hold references to Credhub...",
	) if $writes;
	my $local_vault = $self->local_vault;
	info ("#g{done!}") if $writes;
	return $local_vault;
}

sub _entomb_secret_for_vault {
	my ($self, $local_vault, $vault_path, $key, $value, $credhub, $cred_path, $entombment_prefix) = @_;
	$entombment_prefix //= 'genesis-entombed/';

	# Capture the pre-write value for display before put_secret may
	# update the credhub cache.
	my $cred_name = credhub_var_name($cred_path, $key, $value, $entombment_prefix);
	my ($existing, $action) = $self->_put_or_name($credhub, $cred_name, $value);

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
	my ($existing, $action) = $self->_put_or_name($credhub, $cred_name, $value);
	my ($secret_sha) = $cred_name =~ /--([0-9a-f]{8})$/;

	my $credhub_var = "(($cred_name))";
	my $color = {new => "gi", exists => "yi", altered => "ri", failed => "Yr"}->{$action};
	return ($credhub_var, $secret_sha, $action, $color, $existing);
}

# _put_or_name - write one entombed value, or only say what a write would do {{{
sub _put_or_name {
	my ($self, $credhub, $cred_name, $value) = @_;
	return ($credhub->get($cred_name), put_secret($credhub, $cred_name, $value))
		if $self->builder->writes_credhub;
	# A read-only render may stand where CredHub cannot be reached at all.
	my $existing = eval {$credhub->get($cred_name)};
	return ($existing, !defined $existing ? 'new' : $existing eq $value ? 'exists' : 'altered');
}
# }}}

1;
