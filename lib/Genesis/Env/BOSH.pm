package Genesis::Env::BOSH;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Service::BOSH::CreateEnvProxy;
use Service::BOSH::Director;
use Service::Vault;
use Genesis::Term;
use Genesis::UI;
use Cwd ();
use Genesis::State;

### Instance Methods {{{

# with_bosh - ensure the BOSH director is available and authenticated {{{
sub with_bosh {
	$_[0]->bosh->connect_and_validate;
	$_[0];
}

# }}}
# bosh_env - return the bosh_env for this environment {{{
sub bosh_env {
	my $data = $_[0]->_memoize(sub {
		my $self = shift;
		my $env_bosh_target = scalar($self->lookup('genesis.bosh_env', $self->is_bosh_director ? undef : $self->{name}));
		return {} unless $env_bosh_target;
		return scalar($self->_parse_bosh_env($env_bosh_target));
	});
	return wantarray ? @$data{'name', 'dep_type','vault_url','exodus_mount','description'} : $data;
}

# }}}
# bosh_alias - return the alias of the bosh used to deploy this environment (diminutive of bosh_env) {{{
sub bosh_alias {
	return $_[0]->bosh_env->{name};
}

# }}}
# bosh - the Service::BOSH::Director (or ::CreateEnvProxy) associated with this environment {{{
sub bosh {
	scalar $_[0]->_memoize(sub {
		my $self = shift;
		my $bosh;
		return Service::BOSH::CreateEnvProxy->new($self) if $self->use_create_env;

		# If we're in a callback or under test, just reload from envirionemnt variables.
		if (in_callback || under_test) {
			if ($ENV{GENESIS_BOSH_ENVIRONMENT} && $ENV{BOSH_CLIENT} && is_valid_uri($ENV{GENESIS_BOSH_ENVIRONMENT})) {
				$ENV{BOSH_ENVIRONMENT} = $ENV{GENESIS_BOSH_ENVIRONMENT};
				$ENV{BOSH_ALIAS} ||= scalar($self->lookup('genesis.bosh_env', $self->{name}));
				$ENV{BOSH_DEPLOYMENT} ||= $self->deployment_name;
				$bosh = Service::BOSH::Director->from_environment();
				return $bosh if $bosh;
			}
		}

		# bosh env can be <alias>[/<deployment-type>]@[http(s?)://<host>[:<port>]/][<mount>]
		my ($bosh_alias,$bosh_dep_type,$bosh_exodus_vault_url,$bosh_exodus_mount) = $self->bosh_env;

		my $bosh_vault = $self->vault;
		if ($bosh_exodus_vault_url) {
			$bosh_vault = Service::Vault->find_single_match_or_bail($bosh_exodus_vault_url);
			bail(
				"Could not access vault #C{$bosh_exodus_vault_url} to retrieve BOSH ".
				"director login credentials"
			) unless $bosh_vault && $bosh_vault->connect_and_validate;
		}

		$bosh = Service::BOSH::Director->from_exodus(
			$bosh_alias,
			vault => $bosh_vault,
			exodus_mount => $bosh_exodus_mount || $self->exodus_mount,
			bosh_deployment_type => $bosh_dep_type,
			deployment => $self->deployment_name,
		) || Service::BOSH::Director->from_alias(
			$bosh_alias,
			deployment => $self->deployment_name
		);
		bail(
			"Could not find BOSH director #M{%s} (under exodus #C{%s%s} or by alias in ~/.bosh/config)",
			$bosh_alias,
			$bosh_exodus_mount || $self->exodus_mount,
			$bosh_vault->name eq $self->vault->name ? "" : " in vault ".$bosh_vault->ref

		) unless $bosh;

		warning(
			"Calling shell has BOSH_ALIAS set to %s, but this environment specifies ".
			"the #M{%s} BOSH director; ignoring \$BOSH_ALIAS set in shell\n",
			$ENV{BOSH_ALIAS}, $bosh->alias
		) if ($ENV{BOSH_ALIAS} && $ENV{BOSH_ALIAS} ne $bosh->{alias});

		if ($ENV{BOSH_ENVIRONMENT}) {
			if (is_valid_uri($ENV{BOSH_ENVIRONMENT})) {
				warning(
					"Calling shell has BOSH_ENVIRONMENT set to %s, but this environment ".
					"specifies the BOSH director at #M{%s}; ignoring \$BOSH_ENVIRONMENT ".
					"set in shell.\n",
					$ENV{BOSH_ENVIRONMENT}, $bosh->url
				) if ($ENV{BOSH_ENVIRONMENT} ne $bosh->url);
			} else {
				error(
					"Calling shell has BOSH_ENVIRONMENT set to %s, but this environment ".
					"specifies the #M{%s} BOSH director; ignoring \$BOSH_ENVIRONMENT set ".
					"in shell.\n",
					$ENV{BOSH_ENVIRONMENT}, $bosh->alias
				) if ($ENV{BOSH_ENVIRONMENT} ne $bosh->alias);
			}
		}

		return $bosh;
	});
}
# }}}
# get_target_bosh - determine the correct BOSH to target for this environment {{{

# REFACTOR: We need an internal method for being able to get the bosh director
#           that this environment is, rather than the director that deloys this
#           environment.  The below does this, but its has too much user-facing
#           output that wouldn't apply to internal usage.
sub get_target_bosh {
	my ($self, $options) = @_;
	my $target;
	my $bosh;
	my $bosh_exodus_path;

	bail(
		"Cannot use the #y{--self} and #y{--parent} options together."
	) if ($options->{self} && $options->{parent});

	if ($self->is_bosh_director && !$self->use_create_env) {
		if ($options->{self}) {
			$target = 'self'
		} elsif ($options->{parent}) {
			$target = 'parent'
		} else {
			$target = $Genesis::RC->get('default_bosh_target' => 'ask');
			if ($target eq 'ask') {
				bail(
					"Environment #C{%s} is a BOSH director deployed by another BOSH ".
					"director.  You must specify either #y{--self} or #y{--parent} option ".
					"to target it or its deploying director respectively.",
					$self->name
				) unless in_controlling_terminal;

				my $self_name = $self->name;
				my $bosh_alias = $self->bosh_alias;
				$target = prompt_for_choice(
					"Which BOSH director do you want to target?",
					['self', 'parent'],
					'self',
					[ map {[ $_, s/: .*//r ]} map {csprintf("%s", $_)} (
						"#C{$self_name}: this environment",
						"#C{$bosh_alias}: the BOSH director that deployed this environment"
					) ]
				);
			}
		}
	} elsif (!$self->is_bosh_director && $self->use_create_env) {
		bail(
			"Environment %s is a #M{create-env} deployment, but not a BOSH director, ".
			"so there is no BOSH director to target.",
			$self->name
		);
	} elsif (!$self->is_bosh_director) {
		bail(
			"Environment %s is not a BOSH director, so the #y{--self} option is invalid.",
			$self->name
		) if $options->{self};
		warning(
			"\n\aEnvironment %s is not a BOSH director, so the #y{--parent} option is unnecessary.\n",
			$self->name
		) if $options->{parent} && !$Genesis::RC->get('suppress_warnings.bosh_target' => 0);
		$target = 'parent';
	} elsif ($self->use_create_env) {
		bail(
			"Environment %s is a #M{create-env} deployment, so the #y{--parent} option is invalid.",
			$self->name
		) if $options->{parent};
		warning(
			"\n\aEnvironment %s is a #M{create-env} deployment, so the #y{--self} option is unnecessary.\n",
			$self->name
		) if $options->{self} && !$Genesis::RC->get('suppress_warnings.bosh_target' => 0);
		$target = 'self';
	}

	elsif ($options->{self} || $options->{parent}) {
		if ($self->use_create_env) {
			bail(
				"Environment %s is a #M{create-env} deployment, so the #y{--self} is ".
				"unnecessary and the #y{--parent} is invalid.",
				$self->name
			);
		} elsif (!$self->is_bosh_director) {
			bail(
				"Environment %s is not a BOSH director, so the #y{--self} is invalid ".
				"and #y{--parent} is unnecessary.",
				$self->name
			) ;
		} else {
			bug(
				"Somehow, the environment %s is not a BOSH director, but is also not a ".
				"#M{create-env} deployment.  This should not be possible.",
			);
		}
	} else {
		$target = $self->is_bosh_director ? 'self' : 'parent';
	}

	if ($target eq 'self') {
		$bosh_exodus_path=$self->exodus_base;
		my $exodus_data = eval {$self->vault->get($bosh_exodus_path)};
		if ($exodus_data->{url} && $exodus_data->{admin_password}) {
			$bosh = Service::BOSH::Director->from_exodus($self->name, exodus_data => $exodus_data);
		} else {
			$bosh = Service::BOSH::Director->from_alias($self->name);
		}
	} else {
		$bosh = $self->bosh;
		$bosh_exodus_path = $self->exodus_base;
	}
	bail(
		"No BOSH connection details found.  This may be due to not having read ".
		"access to the BOSH deployment's exodus data in vault (#M{%s}).",
		$bosh_exodus_path
	) unless $bosh;

	return wantarray ? ($bosh, $target, $bosh_exodus_path) : $bosh;
}
# }}}
# credhub - get the credhub instance for the environment {{{
sub credhub {
	my $ref = $_[0]->_memoize(sub {
		require Service::Credhub;
		my ($self) = @_;
		my %env = $self->credhub_connection_env;
		my $credhub = Service::Credhub->new(
			$self->deployment_name,
			$env{GENESIS_CREDHUB_ROOT},
			$env{CREDHUB_SERVER},
			$env{CREDHUB_CLIENT},
			$env{CREDHUB_SECRET},
			$env{CREDHUB_CA_CERT}
		);
		return $credhub;
	});
	return $ref;
}
# }}}
# credhub_connection_env - returns environment variables hash for connecting to this environment's Credhub {{{
sub credhub_connection_env {
	my $self = shift;
	my ($credhub_src,$credhub_src_key) = $self->lookup(
		['genesis.credhub_env','genesis.bosh_env','params.bosh','genesis.env','params.env']
	);
	my %env=();

	my $credhub_info = {};
	$env{GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE} = "";
	if ($credhub_src_key eq 'genesis.bosh_env') {
		my ($bosh_alias,$bosh_dep_type,$bosh_exodus_vault,$bosh_exodus_mount) = $self->_parse_bosh_env($credhub_src);
		$bosh_alias //= $self->name;
		$bosh_dep_type //= 'bosh';
		$bosh_exodus_mount //= $self->exodus_mount;
		my $bosh_vault = $self->vault;
		if ($bosh_exodus_vault) {
			$bosh_vault = Service::Vault->find_single_match_or_bail($bosh_exodus_vault);
			bail(
				"Could not access vault #C{$bosh_exodus_vault} to retrieve BOSH ".
				"director login credentials"
			) unless $bosh_vault && $bosh_vault->connect_and_validate;
		}
		$env{GENESIS_CREDHUB_EXODUS_SOURCE} = "$bosh_alias/$bosh_dep_type";
		$env{GENESIS_CREDHUB_ROOT}=sprintf("/%s-%s/%s-%s", $bosh_alias, $bosh_dep_type, $self->name, $self->type);
		$credhub_info = $bosh_vault->get("$bosh_exodus_mount/$bosh_alias/$bosh_dep_type");
	} else {
		$env{GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE} =
			(($credhub_src_key || "") eq 'genesis.credhub_env') ? $credhub_src : "";

		my $credhub_path = $credhub_src;
		if ($credhub_src =~ /\/\w+$/) {
			$credhub_path  =~ s/\/([^\/]*)$/-$1/;
		} else {
			$credhub_src .= "/bosh";
			$credhub_path .= "-bosh";
		}
		$env{GENESIS_CREDHUB_EXODUS_SOURCE} = $credhub_src;
		$env{GENESIS_CREDHUB_ROOT}=sprintf("/%s/%s-%s", $credhub_path, $self->name, $self->type);
		$credhub_info = $self->exodus_lookup('.',undef,$credhub_src) if ($credhub_src);
	}

	if ($credhub_info) {
		$env{CREDHUB_SERVER} = $credhub_info->{credhub_url}||"";
		$env{CREDHUB_CLIENT} = $credhub_info->{credhub_username}||"";
		$env{CREDHUB_SECRET} = $credhub_info->{credhub_password}||"";
		$env{CREDHUB_CA_CERT} = sprintf("%s%s",$credhub_info->{ca_cert}||"",$credhub_info->{credhub_ca_cert}||"");
	}

	return %env;
}

# }}}
# connect_required_endpoints - ensure external dependencies are reachable {{{
sub connect_required_endpoints {
	my ($self, @hooks) = @_;
	my @endpoints;
	push(@endpoints, $self->kit->required_connectivity($_)) for (@hooks);
	for (uniq(@endpoints)) {
		$self->with_vault   if $_ eq 'vault';
		$self->with_bosh    if $_ eq 'bosh';
		$self->with_credhub if $_ eq 'credhub'; # TODO: write this...!
		bail("Unknown connectivity endpoint type #Y{%s} in kit #m{%s}", $_, $self->kit->id);
	}
	return $self
}

# }}}
# bosh_logs - get the logs for the environment {{{
sub bosh_logs {
	my ($self, @extra_opts ) = @_;

	if (grep {$_ =~ /^(-h|--help)$/} @extra_opts) {
		info("\nFetching help for 'bosh logs'...\n");
		$self->bosh->execute({interactive => 1}, "logs", "--help");
		exit 0;
	}

	bail(
		"Cannot use log with -f|--follow option; use %s %s bosh logs %s instead",
		$ENV{GENESIS_CALL_BIN},
		$ENV{'GENESIS_PREFIX_'.uc($ENV{GENESIS_PREFIX_TYPE})},
		join(" ", map {$_ =~ /\s+/ ? "'$_'" : $_} @extra_opts)
	)	if (grep {$_ =~ /^(-f|--follow)$/} @extra_opts);

	my %opts = ref($extra_opts[0]) eq 'HASH' ? %{shift @extra_opts} : ();

	$self->notify("fetching BOSH logs for %s/%s...", $self->name, $self->type);
	my $log_path = $Genesis::RC->get('bosh_logs_path');
	my $deployment_root = $ENV{GENESIS_DEPLOYMENT_ROOT};
	unless ($deployment_root) {
		if (-f ".genesis/config") {
			$deployment_root = Cwd::abs_path('..');
		} else {
			$deployment_root = Cwd::abs_path('.');
		}
	}
	$log_path =~ s/^<DEPLOYMENT_ROOT>\//$deployment_root\//;
	my $dep_log_path = $log_path.'/'.$self->name.'/'.$self->type;
	info("- logs will be saved to %s", humanize_path($dep_log_path));

	mkdir_or_fail($dep_log_path) unless -d $dep_log_path;

	info("- fetching logs...\n");
	pushd($log_path);
	my $bosh = $self->bosh;
	my ($out, $rc, $err) = $bosh->execute({interactive => 1}, "logs", @extra_opts);
	info("");
	if ($rc) {
		bail("Failed to fetch logs: %s", $err);
	}

	$self->notify("extracting logs...");
	my $grouped = $out =~ m/Fetching group of logs: Packing log files together/;
	my @archives = $out =~ m/Downloading resource .* to '(.*)'\.\.\./g;
	my @logs = ();
	if ($grouped) {
		for my $archive (@archives) {
			my $file_name = basename($archive) =~ s/\.tgz$//r;
			my ($extract_out, $extract_rc, $extract_err) = run({stderr => 0},
				"tar", "xzf", $archive, "-C", $dep_log_path
			);
			if ($extract_rc) {
				warning("- failed to extract packed archive %s: %s", $file_name, $extract_err);
			} else {
				info("- extracted packed archive %s", $file_name);
			}
			unlink $archive;
		}
	} else {
		# Move the singleton log into the right place with the corrected name
		basename($archives[0]) =~ m/^(.*?)[-\.](\d\d\d\d)(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)-(\d+)\.tgz$/;
		my $new_archive = sprintf("%s.%s-%s-%s-%s-%s-%s.tgz", $1, $2, $3, $4, $5, $6, $7);
		require File::Copy;
		File::Copy::move($archives[0], "$dep_log_path/$new_archive")
			or bail("Failed to move %s to %s: %s", $archives[0], "$dep_log_path/$new_archive", $!);
	}

	pushd($dep_log_path);
  my @dep_archives = glob("*.tgz");

  foreach my $archive (@dep_archives) {
    my $file_name = $archive =~ s/\.tgz$//r;
    my ($job, $vmid, $ts) = split /\./, $file_name;

		my $target_dir = "$dep_log_path/$job/$vmid/$ts";
    mkdir_or_fail($target_dir) unless -d $target_dir;

    my ($out, $rc, $err) = run("tar", "-zxf", $archive, "-C", $target_dir);
		if ($rc) {
			warning("failed to extract archive %s: %s", $file_name, $err);
		} else {
			info("- extracted archive %s", $file_name);
		}
    unlink $archive;
  }
	popd();
	popd();
	$self->notify(success => "BOSH logs fetched successfully - they can be found in #G{%s}\n", humanize_path($dep_log_path));
}
# }}}

# }}}

### Private Instance Methods {{{

# _parse_bosh_env - parse the bosh env into its constituent parts, and returns a hashref {{{
sub _parse_bosh_env {
	my ($self, $bosh_env_description) = @_;
	bail("Invalid BOSH environment description: %s", $bosh_env_description) unless $bosh_env_description;

	# Pattern: <name>[/<type>][@[<url>]/<mount>]
	my ($name, $dep_type, $vault_url, $exodus_mount) =
		($bosh_env_description) =~ m/^([^\/\@]+)(?:\/([^\@]+))?(?:@(?:(https?:\/\/[^\/]+)?(?:\/|$))?(.*))?$/;

	return wantarray ? ($name, $dep_type, $vault_url, $exodus_mount) : {
		name         => $name,
		dep_type     => $dep_type,
		vault_url    => $vault_url,
		exodus_mount => $exodus_mount,
		description  => $bosh_env_description,
	};
}

# }}}

# }}}
# logs - fetch BOSH logs for the environment {{{
sub logs {
	my ($self, @extra_opts) = @_;

	if (grep {$_ =~ /^(-h|--help)$/} @extra_opts) {
		info("\nFetching help for 'bosh logs'...\n");
		$self->bosh->execute({interactive => 1}, "logs", "--help");
		exit 0;
	}

	bail(
		"Cannot use log with -f|--follow option; use %s %s bosh logs %s instead",
		$ENV{GENESIS_CALL_BIN},
		$ENV{'GENESIS_PREFIX_'.uc($ENV{GENESIS_PREFIX_TYPE})},
		join(" ", map {$_ =~ /\s+/ ? "'$_'" : $_} @extra_opts)
	)	if (grep {$_ =~ /^(-f|--follow)$/} @extra_opts);

	my %opts = ref($extra_opts[0]) eq 'HASH' ? %{shift @extra_opts} : ();

	$self->notify("fetching BOSH logs for %s/%s...", $self->name, $self->type);
	my $log_path = $Genesis::RC->get('bosh_logs_path');
	my $deployment_root = $ENV{GENESIS_DEPLOYMENT_ROOT};
	unless ($deployment_root) {
		if (-f ".genesis/config") {
			$deployment_root = Cwd::abs_path('..');
		} else {
			$deployment_root = Cwd::abs_path('.');
		}
	}
	$log_path =~ s/^<DEPLOYMENT_ROOT>\//$deployment_root\//;
	my $dep_log_path = $log_path.'/'.$self->name.'/'.$self->type;
	info("- logs will be saved to %s", humanize_path($dep_log_path));

	mkdir_or_fail($dep_log_path) unless -d $dep_log_path;

	info("- fetching logs...\n");
	pushd($log_path);
	my $bosh = $self->bosh;
	my ($out, $rc, $err) = $bosh->execute({interactive => 1}, "logs", @extra_opts);
	info("");
	if ($rc) {
		bail("Failed to fetch logs: %s", $err);
	}

	$self->notify("extracting logs...");
	my $grouped = $out =~ m/Fetching group of logs: Packing log files together/;
	my @archives = $out =~ m/Downloading resource .* to '(.*)'\.\.\./g;
	my @logs = ();
	if ($grouped) {
		for my $archive (@archives) {
			my $file_name = basename($archive) =~ s/\.tgz$//r;
			my ($extract_out, $extract_rc, $extract_err) = run({stderr => 0},
				"tar", "xzf", $archive, "-C", $dep_log_path
			);
			if ($extract_rc) {
				warning("- failed to extract packed archive %s: %s", $file_name, $extract_err);
			} else {
				info("- extracted packed archive %s", $file_name);
			}
			unlink $archive;
		}
	} else {
		# Move the singleton log into the right place with the corrected name
		basename($archives[0]) =~ m/^(.*?)[-\.](\d\d\d\d)(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)-(\d+)\.tgz$/;
		my $new_archive = sprintf("%s.%s-%s-%s-%s-%s-%s.tgz", $1, $2, $3, $4, $5, $6, $7);
		require File::Copy;
		File::Copy::move($archives[0], "$dep_log_path/$new_archive")
			or bail("Failed to move %s to %s: %s", $archives[0], "$dep_log_path/$new_archive", $!);
	}

	pushd($dep_log_path);
	my @dep_archives = glob("*.tgz");

	foreach my $archive (@dep_archives) {
		my $file_name = $archive =~ s/\.tgz$//r;
		my ($job, $vmid, $ts) = split /\./, $file_name;

		my $target_dir = "$dep_log_path/$job/$vmid/$ts";
		mkdir_or_fail($target_dir) unless -d $target_dir;

		my ($out, $rc, $err) = run("tar", "-zxf", $archive, "-C", $target_dir);
		if ($rc) {
			warning("failed to extract archive %s: %s", $file_name, $err);
		} else {
			info("- extracted archive %s", $file_name);
		}
		unlink $archive;
	}
	popd();
}

# }}}

1;

=head1 NAME

Genesis::Env::BOSH

=head1 DESCRIPTION

This module provides BOSH integration functionality for Genesis environments.
It handles connections to BOSH directors, authentication, and operations.

=head1 METHODS

=head2 with_bosh()

Ensures the BOSH director is available and authenticated.

=head2 bosh_env()

Returns the BOSH environment configuration for this environment.

=head2 bosh_alias()

Returns the alias of the BOSH director used to deploy this environment.

=head2 bosh()

Returns the Service::BOSH::Director (or ::CreateEnvProxy) instance associated
with this environment.

=head2 get_target_bosh($options)

Determines the correct BOSH director to target for this environment.

=head2 credhub()

Returns the Credhub instance for the environment.

=head2 credhub_connection_env()

Returns environment variables hash for connecting to this environment's Credhub.

=head2 connect_required_endpoints(@hooks)

Ensures external dependencies (vault, bosh, credhub) are reachable.

=head2 bosh_logs(@extra_opts)

Fetches BOSH logs for the environment (deprecated, use logs instead).

=head2 logs(@extra_opts)

Fetches and extracts BOSH logs for the environment.

=cut