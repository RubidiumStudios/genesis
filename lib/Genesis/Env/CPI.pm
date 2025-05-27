package Genesis::Env::CPI;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::UI;
use Time::HiRes qw/gettimeofday/;

### Instance Methods {{{

# BOSH config stuff - Generic

sub bosh_config_name {
	return $_[0]->name.'.'.$_[0]->type;
}

# BOSH config stuff - CPI

# The CPI config is defined in the environment under the bosh-configs.cpi key.
# The contents of this key are defined as a hash, with the following keys:
#  - enabled: true/false
#  - based-on: 'parent' | <arbitrary name> # TBD: not sure if needed, or how to implement
#  - <arbitrary name>: <cpi config> - whatever the CPI needs to be configured

# Note: If using OCFP, the CPI is always enabled, but can be disabled by setting
# the 'enabled' key to false in the OCFP configuration.

# The current intent is to just apply this to the BOSH director deployments, but
# it could be extended to other deployments in the future (ie we don't know it
# _won't_ work for other deployments).

sub cpi_enabled {
	my $self = shift;
	return $self->cpi_config->{enabled}//$self->is_ocfp
}

sub cpi_config {
	my $self = shift;
	return $self->lookup('bosh-configs.cpi', {});
}

sub cpi_name {
	# REFACTOR: We need a way to determine the name of the cpi for the
	# environment.  In most cases, it will be whatever the director
	# is using, but in some cases, it may be different.  For example,
	# another BOSH deployment will use its own cpi name, and provide
	# its own cpi config.  This is already implmenented, but other cases
	# might need to be considered in the future:
	#
	# A currently unsupported reason for selecting a different cpi name is to
	# support multicloud deployments, where the cpi name is used to determine
	# which cloud is being targeted.
	my $self = shift;
	return undef unless $self->cpi_enabled;
	if ($self->has_hook('cpi-config')) {
		# TODO: Should the kit specify if it wants its own cpi name?
		return join('.', $self->name, $self->iaas, $self->type);
	}
	# Return the base cpi name of the director (now provided by exodus)
	#my $bosh_env = $self->bosh_env;
	#return join('.', $bosh_env->{name}, $self->iaas, $bosh_env->{dep_type}//'bosh')
	return $self->director_exodus_lookup('default_cpi_config', undef);
}

sub cpi_credhub_base {
	# This is the location that the cpi credhub secrets will be uploaded to when
	# the environment is not uploading a director default CPI config.
	my $self = shift;
	my $base = $self->lookup('bosh-configs.cpi.credhub_base');
	return $base // ($self->credhub->base."genesis-entombed/");
}

# Bosh Config stuff - TODO: sort later
# bosh_config_names - returns a hash of bosh config names proved by the environment {{{
sub bosh_config_names {
	my $self = shift;
	# environments need to be given a name based on the environment name and type
	my $configs = {};
	my $prefix = $self->name . '/' . $self->type;
	my @config_types = $self->kit->provided_configs;
	for my $config_type (@config_types) {
		my ($type, $purpose) = split(/:/,$config_type,2); # Support multiple files per type
		push @{$configs->{$type}}, $prefix.($purpose ? ":$purpose" : '');
	}
	return $configs;
}

# }}}

# }}}

### Private Instance Methods {{{

sub _check_cpi_config {
	# Check that the cpi config is available and unchanged on the director.
	# Returns a hash:
	#  state => 'ok' | 'changed' | 'missing'
	#  fatal => 1 | 0
	#  fix_data => {
	#    cpi_config => <yaml config string>,
	#    name => <name of the config>,
	#    director => <bosh director>
	#  }
	#  msg => <message to display>
	my ($self) = @_;

	return {
		state => 'ok', msg => "using create-env, no CPI config needed."
	} if $self->use_create_env; # No cpi check needed

	my $cpi_name = $self->cpi_name;
	my $director = $self->bosh;

	# FIXME: Need to deal with the "default" config that doesn't show up in the
	# list of configs.  This is the default config that the director uses if
	# it doesn't explicitly have a cpi config.
	# FIXME: inform user that we're checking the cpi config on the director
	my $current_config = $director->get_config('cpi', $cpi_name);
	my $has_hook = $self->has_hook('cpi-config');
	unless ($current_config) {
		return $has_hook ? {
			state => 'missing',
			msg   => sprintf("missing CPI config"),
			fix_data => { name => $cpi_name, director => $director },
		} : {
			state => 'missing',
			fatal => 1,
			msg   => sprintf("missing CPI config - kit does not provide a cpi-config hook"),
		};
	}

	return {
		state => 'ok',
		msg   => sprintf("CPI config #m{%s} is provided by the BOSH director #M{%s}.", $cpi_name, $director->alias),
	} unless $has_hook;

	# Check if the config is up-to-date
	my $cpi_config = $self->run_hook(
		'cpi-config',
		credhub_prefix => $self->cpi_credhub_base
	);
	info("[[  - >>CPI config synthesized.");

	my ($diff,$is_diff) = spruce_diff(
		{content => $current_config,        label => 'current'},
		{content => $cpi_config->{content}, label => 'new'}
	);

	if ($is_diff) {
		info(
			"[[  - >>required CPI config #m{%s} is different from the one currently on the BOSH director:\n\n%s",
			$cpi_name, $diff
		);
		return {
			state    => 'changed',
			fix_data => {
				cpi_config => $cpi_config,
				name       => $cpi_name,
				director   => $director,
			},
			msg      => sprintf("CPI config #m{%s} is different from the one currently on the BOSH director.", $cpi_name),
		};
	} else {
		info("[[  - >>current CPI config #m{%s} is up-to-date.", $cpi_name);
	}

	# Check if any entombed secrets are empty or missing
	my @secrets = sort keys %{$cpi_config->{credhub_secrets}};

	my @empty = grep {
		($cpi_config->{credhub_secrets}{$_}//'') eq ''
	} @secrets;

	if (@empty) {
		my $credhub_base = $self->credhub->base;
		info(
			"[[  - >>%d missing secret values:\n%s",
			scalar(@empty),
			join("\n", map {sprintf("[[  %s>>#R{%s}",bullet(''), $_ =~ s#.*--(.*)--.*#$1#r)} @empty)
		);
		return {
			state    => 'error',
			fatal    => 1,
			msg      => sprintf(
				"CPI config #m{%s} references secrets that have no value!%s",
				$cpi_name,
				$self->is_ocfp ? "\n\n#yi{This may be due to missing value in the OCFP config.}" : ''
			),
		};
	}

	my @missing_secrets = grep {
		!$self->credhub->has($_)
	} @secrets;

	if (@missing_secrets) {
		my $credhub_base = $self->credhub->base;
		info(
			"[[  - >>missing %d entombed secrets under #c{%s}:\n%s",
			scalar(@missing_secrets), $self->credhub->base,
			join("\n", map {sprintf("[[  %s>>#R{%s}",bullet(''), $_ =~ s#$credhub_base##r)} @missing_secrets)
		);
		return {
			state    => 'missing secrets',
			fix_data => {
				cpi_config => $cpi_config,
				name       => $cpi_name,
				director   => $director,
			},
			msg      => sprintf("CPI config #m{%s} is missing %d entombed secrets.", $cpi_name, scalar(@missing_secrets)),
		};
	}	

	return {
		state => 'ok',
		msg  => sprintf("CPI config is up-to-date"),
	};
}

# }}}
# _fix_cpi_config - fix the cpi config on the director {{{
sub _fix_cpi_config {
	my ($self, $state, $fix_data, %opts) = @_;

	# If no fix_data is provided, generate it using the cpi-config hook
	unless ($fix_data) {
		bail("Cannot fix CPI config without a valid cpi-config hook")
			unless $self->has_hook('cpi-config');
		$fix_data = {};
	}

	my $cpi_config = $fix_data->{cpi_config} // scalar($self->run_hook(
			'cpi-config',
			credhub_prefix => $self->cpi_credhub_base
		));
	my $cpi_name   = $fix_data->{name} // $self->cpi_name;
	my $director   = $fix_data->{director} // $self->bosh;
	my $indent     = $opts{indent} // "  - ";
	my $noprompt   = $opts{noprompt} // $ENV{BOSH_NON_INTERACTIVE} // 0;

	if ($state eq 'ok') {
		info("[[  - >>#G{CPI config is already up-to-date}");
		return {
			result => 'ok',
			msg    => sprintf("CPI config is up-to-date"),
		};
	}

	# Upload the CPI config to the BOSH director
	my $start = gettimeofday();
	if ($state ne 'missing secrets') {
		if (in_controlling_terminal && !$noprompt) {
			prompt_for_boolean(
				"Upload the new CPI config to the BOSH director ('no' will cancel ".$Genesis::Commands::COMMAND.")? [y|n]",
				1
			) or bail "Aborted by user!";
		}

		info({pending => 1}, # ??? $noprompt},
			"[[%s>>uploading CPI config #m{%s} to BOSH director #M{%s}...",
			$indent, $cpi_name, $director->alias
		);
		my ($out, $rc, $err) = $director->upload_config(
			$cpi_config->{content}, 'cpi', $cpi_name, !$noprompt
		);
		if ($rc) {
			info("#R{failed}".pretty_duration(gettimeofday() - $start));
			return {
				result => 'error',
				msg    => sprintf(
					"failed to upload CPI config: %s",
					$err ? $err : $out
				),
			}
		}
		info("#G{done}".pretty_duration(gettimeofday() - $start));
	}

	# Generate any missing CredHub secrets
	if ($cpi_config->{credhub_secrets} && ref($cpi_config->{credhub_secrets}) eq 'HASH') {
		my $count = scalar keys %{$cpi_config->{credhub_secrets}};
		info(
			"[[%s>>generating %d missing CredHub secrets used by CPI config #m{%s}...",
			$indent, $count, $cpi_name
		) if $count;
		my $credhub = $self->credhub;
		my %existing_secrets = eval {map {$_, 1} $credhub->paths($self->cpi_credhub_base)};
		my $idx = 0;
		my $width = length($count);
		my $prefix = $indent =~ s/./ /gr;

		my $failed = 0;
		for my $secret (sort keys %{$cpi_config->{credhub_secrets}}) {
			my ($name,$sha1) = $secret =~ m{/[^/]+--([^/]+)--([^/]+)$};
			info({pending => 1},
				"[[%s[%*s] >>#m{%s} #Ki{(sha: %s)}...",
				$prefix, $width, ++$idx, $name, $sha1
			);

			# Only upload the secret if it doesn't exist
			if ($existing_secrets{$secret} || $credhub->has($secret)) {
				info("#B{exists}");
				next;
			}

			my $value = $cpi_config->{credhub_secrets}{$secret};
			if (!defined($value)) {
				info("#R{invalid value}");
				$failed = 1;
				next;
			}

			my ($out, $err) = $credhub->set($secret, $value);
			if ($err) {
				info("#R{failed}");
				$failed = 1;
			} else {
				info("created");
			}
		}

		if ($failed) {
			info("[[  - >>#R{failed to create some secrets}");
			return {
				result => 'error',
				msg    => sprintf("failed to create some secrets"),
			};
		}
	}

	return {
		result => 'ok',
		msg    => sprintf("successfully uploaded CPI config"),
	};
}

# }}}

# }}}

1;

=head1 NAME

Genesis::Env::CPI

=head1 DESCRIPTION

This module handles BOSH CPI (Cloud Provider Interface) configuration
management for Genesis environments.

=head1 METHODS

=head2 bosh_config_name()

Returns the BOSH config name for this environment.

=head2 cpi_enabled()

Determines if CPI config is enabled for this environment.

=head2 cpi_config()

Returns the CPI configuration from the environment.

=head2 cpi_name()

Determines the name of the CPI config for the environment.

=head2 cpi_credhub_base()

Returns the Credhub base path for CPI secrets.

=head2 bosh_config_names()

Returns a hash of BOSH config names provided by the environment.

=cut