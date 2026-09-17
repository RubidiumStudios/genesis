package Genesis::CI::ProviderCompiler;
use strict;
use warnings;

use Genesis;
use Genesis::CI::ProviderRegistry;
use JSON::PP;
use Getopt::Long qw/GetOptionsFromArray/;

### Constructor {{{

# new - build a compiler for one provider {{{
#
# Under D108 a compiler holds the provider it emits for rather than a
# copy of that provider's settings, so DEFAULT_TEAM and check_prereqs
# have one home each and a change on the provider is visible here with
# nothing rebuilt.  A caller reaches this through
# $provider->compiler(ast => $ast) rather than calling it directly.
#
# The concrete used to define its own new and drop everything but ast,
# top, and provider_opts, which would have thrown the provider away on
# the way in.  It inherits this one now.
sub new {
	my ($class, %opts) = @_;

	bug("Cannot instantiate Genesis::CI::ProviderCompiler directly; ".
		"use a subclass instead")
		if $class eq __PACKAGE__;

	return bless({
		provider      => $opts{provider},
		ast           => $opts{ast},
		top           => $opts{top},
		provider_opts => $opts{provider_opts} || {},
	}, $class);
}

# }}}
# }}}
### Abstract Methods {{{
#
# Subclasses MUST override these methods.

# platform_name - return human-readable platform name {{{
sub platform_name {
	my ($self) = @_;
	bug("Subclass '%s' must implement platform_name()", ref($self));
}

# }}}
# provider_type - return canonical type string, e.g. 'concourse' {{{
sub provider_type {
	my ($self) = @_;
	bug("Subclass '%s' must implement provider_type()", ref($self));
}

# }}}
# generate_from_ast - generate platform-specific output from AST {{{
sub generate_from_ast {
	my ($self, $ast) = @_;
	bug("Subclass '%s' must implement generate_from_ast()", ref($self));
}

# }}}
# output_files - describe what files this provider generates {{{
sub output_files {
	my ($self) = @_;
	bug("Subclass '%s' must implement output_files()", ref($self));
}

# }}}
# }}}
### Prerequisite Checking {{{

# check_prereqs - returns 1 if toolchain is present, 0 + error() if not {{{
sub check_prereqs {
	return 1;
}

# }}}
# }}}
### Provider Options Contract {{{
# These methods define the provider options system, modelled after
# Genesis::Kit::Provider.  Subclasses override them to expose their
# platform-specific flags, help text, and config-section schemas.

# cli_opts - Getopt::Long option specs for deploy-time command-line flags {{{
#
# Returns a list of Getopt::Long spec strings, e.g.:
#   qw( ci-target=s  ci-team=s  ci-pause  ci-expose )
#
# All CI-provider opts are prefixed with 'ci-' to avoid collisions with
# top-level genesis option names (--target, --dry-run, etc.).
#
# Subclasses override to declare their provider-specific options.
# Base implementation returns empty list (no provider-specific opts).
sub cli_opts {
	return qw//;
}

# }}}
# cli_opts_help - formatted help text for cli_opts() {{{
#
# Returns a multi-line string (heredoc) documenting each option.
# Format mirrors Genesis::Kit::Provider::Github::opts_help():
#
#   --ci-target <value>  (required)
#       The fly target to deploy to.
#
#   --ci-team <value>  (optional, default: "main")
#       The Concourse team name.
#
# %config may include:
#   valid_types  - arrayref of provider type strings to show help for
#
# Subclasses override to document their specific options.
sub cli_opts_help {
	my ($class, %config) = @_;
	return '';
}

# }}}
# provider_options_schema - the CLI class's declaration {{{
#
# One declaration per provider under D105, and it lives beside the check
# that enforces it.  The compiler reads it from there so that the two
# sides cannot answer differently.
#
# The shape is unchanged, a hashref mirroring Top::_repo_config_schema():
#
#   {
#     target => {type => 'string', required => 1, description => '...'},
#     team   => {type => 'string', default => 'main', description => '...'},
#     ...
#   }
sub provider_options_schema {
	my ($self) = @_;
	require Genesis::CI::Provider;
	return Genesis::CI::Provider->provider_class($self->provider_type)
		->provider_options_schema;
}

# }}}
# capabilities - what this provider can do, as six booleans {{{
#
# D101's declaration, and the companion to provider_options_schema.  A
# capability says what the provider is able to do; a configuration key is
# the operator's choice inside that ability, and a key whose capability is
# false is refused at load naming both.  The six names are the abilities
# rather than any provider's spelling of them:
#
#   deployment_locks       serialise jobs against a named BOSH deployment's
#                          lock pool, with D22's reader-writer semantics
#   cross_pipeline_events  signal at a distance, so a job in one pipeline
#                          causes a run in another
#   optional_git_triggers  emit a branch input that does not fire on a git
#                          change
#   scheduled_jobs         run a job on a schedule
#   per_commit_runs        run once per input version rather than only on
#                          the newest
#   multi_file_output      emit more than one file
#
# Mandatory for the same reason the fragment is: a provider whose
# abilities are unknown cannot have its keys gated.
#
# The declaration itself lives on the matching class under
# Genesis::CI::Provider, beside the fragment, and this reads it from
# there through the same route, so that one class answers for both halves
# of a provider and the two sides cannot answer differently.
sub capabilities {
	my ($self) = @_;
	require Genesis::CI::Provider;
	return Genesis::CI::Provider->provider_class($self->provider_type)
		->capabilities;
}

# }}}
# provider_options_defaults - default values for provider options {{{
#
# Returns a flat hashref of key => default_value.  Keys match those in
# provider_options_schema().  Values here are NOT included in the config()
# output — only explicitly-set non-default values are saved.
sub provider_options_defaults {
	return {};
}

# }}}
# provider_config - return stored provider options (non-defaults only) {{{
#
# Returns a hashref suitable for round-tripping through the ci.provider:
# config section — i.e. the type key plus any explicitly-set values that
# differ from provider_options_defaults().
sub provider_config {
	my ($self) = @_;
	my $defaults = $self->provider_options_defaults();
	my $opts     = $self->{provider_opts} || {};
	my %out = ( type => $self->provider_type() );
	for my $k (keys %$opts) {
		next unless defined $opts->{$k};
		next if exists $defaults->{$k}
		     && defined $defaults->{$k}
		     && "$defaults->{$k}" eq "$opts->{$k}";
		$out{$k} = $opts->{$k};
	}
	return \%out;
}

# }}}
# provider_option - get a single provider option, applying defaults {{{
sub provider_option {
	my ($self, $key) = @_;
	my $opts     = $self->{provider_opts} || {};
	my $defaults = $self->provider_options_defaults();
	return exists $opts->{$key}     ? $opts->{$key}
	     : exists $defaults->{$key} ? $defaults->{$key}
	     : undef;
}

# }}}
# describe_provider - structured hash describing this provider instance {{{
#
# Returns a hash suitable for human-readable display, analogous to
# Genesis::Kit::Provider::Github::status().
#
#   type    => 'concourse'
#   label   => 'Concourse'       # human platform name
#   extras  => [qw(Target Team Pipeline)]   # keys to show in order
#   Target  => 'my-target'
#   Team    => 'main'
#   Pipeline => 'cf'
#   status  => 'ok'              # or error message
#
# Subclasses override to add platform-specific fields.
sub describe_provider {
	my ($self) = @_;
	return (
		type   => $self->provider_type(),
		label  => $self->platform_name(),
		extras => [],
		status => 'ok',
	);
}

# }}}
# }}}
### Class Methods — Provider Options Parsing {{{

# parse_cli_opts - two-pass CLI option parsing (mirrors Kit::Provider::parse_opts) {{{
#
# Usage:
#   Genesis::CI::ProviderCompiler->parse_cli_opts(
#       \@ARGV,           # args array (modified in place)
#       \%opts,           # options hash (populated in place)
#       $provider_type,   # optional: already-known provider type
#   );
#
# Pass 1: parse --ci-provider <type> (if not already known)
# Pass 2: load provider class, get cli_opts(), parse provider-specific flags
#
# Returns 1. Remaining unparsed args are put back into $args.
sub parse_cli_opts {
	my ($class, $args, $opts, $provider_type) = @_;

	Getopt::Long::Configure(
		qw(pass_through permute no_auto_abbrev no_ignore_case bundling)
	);

	# Collect args up to '--'
	my $opt_args = [];
	while (scalar(@$args) && $args->[0] ne '--') {
		push @$opt_args, shift @$args;
	}

	# Pass 1: extract --ci-provider if not already known
	unless ($provider_type) {
		GetOptionsFromArray($opt_args, $opts, 'ci-provider=s');
		$provider_type = $opts->{'ci-provider'} // $opts->{platform};
	}

	# Pass 2: load provider and parse provider-specific flags.  A type with
	# no compiler class, which manual is, contributes no flags.
	my $info = $provider_type
		? Genesis::CI::ProviderRegistry->provider_info($provider_type)
		: undef;
	if ($info && $info->{file}) {
		eval { require $info->{file} }  ## no critic
			or bail("Failed to load CI provider '%s': %s", $provider_type, $@);

		my @extra_opts = $info->{class}->cli_opts();
		GetOptionsFromArray($opt_args, $opts, @extra_opts) if @extra_opts;
	}

	# Return unparsed args to caller
	while (scalar(@$opt_args)) { unshift @$args, pop @$opt_args }

	return 1;
}

# }}}
# cli_key_to_config_key - convert a ci-* CLI key to its config/schema key {{{
#
# The convention is: strip the 'ci-' prefix, convert hyphens to underscores.
# Examples:
#   ci-target        => target
#   ci-team          => team
#   ci-pipeline-name => pipeline_name
#   ci-pause         => pause
#   ci-expose        => expose
#
# Non-ci-prefixed keys are returned unchanged (already in config form).
sub cli_key_to_config_key {
	my ($class, $key) = @_;
	$key =~ s/^ci-//;
	$key =~ s/-/_/g;
	return $key;
}

# }}}
# normalize_provider_opts - convert a hash of CLI-keyed opts to config keys {{{
sub normalize_provider_opts {
	my ($class, $opts) = @_;
	my %out;
	for my $k (keys %{ $opts || {} }) {
		$out{ $class->cli_key_to_config_key($k) } = $opts->{$k};
	}
	return \%out;
}

# }}}
# cli_opt_keys - return parsed option key names for a given provider type {{{
#
# Strips Getopt::Long type suffixes (=s, !, +, etc.) leaving bare key names.
# Used by the commands layer to copy matching options from get_options without
# hardcoding provider-specific names.
sub cli_opt_keys {
	my ($class, $provider_type) = @_;
	my $info = Genesis::CI::ProviderRegistry->provider_info($provider_type)
		or return ();
	# A type with no compiler class, which manual is, has no flags to name.
	return () unless $info->{file};
	eval { require $info->{file} }  ## no critic
		or bail("Failed to load CI provider '%s': %s", $provider_type, $@);
	return map { (split /[=!+:]/, $_)[0] } $info->{class}->cli_opts();
}

# }}}
# all_cli_opts_help - assembled help text for all known providers {{{
#
# Prints shared CI flags, then delegates to each provider's cli_opts_help().
# Mirrors Genesis::Kit::Provider::opts_help() in structure.
sub all_cli_opts_help {
	my ($class, %config) = @_;

	# Every type is named where the types are enumerated, and only the ones
	# with a compiler class are asked for help text, because manual has none.
	$config{valid_types} ||= [Genesis::CI::ProviderRegistry->known_providers];

	my $provider_help = join('',
		map  { $_->{class}->cli_opts_help(%config) }
		grep { $_->{file} && eval { require $_->{file}; 1 } }  ## no critic
		map  { Genesis::CI::ProviderRegistry->provider_info($_) }
		Genesis::CI::ProviderRegistry->known_providers
	);

	return <<EOF;
CI PROVIDER OPTIONS

  --ci-provider <type>  (optional, defaults to "manual")
      The CI provider to use for pipeline generation and deployment.
      Available types: ${\ join(', ', Genesis::CI::ProviderRegistry->known_providers) }

$provider_help
EOF
}

# }}}
# }}}
### Shared Helper Methods {{{

# ast - get stored AST {{{
sub ast {
	return $_[0]->{ast};
}

# }}}
# top - get stored Genesis::Top object {{{
sub top {
	return $_[0]->{top};
}

# }}}
# provider - the provider this compiler emits for {{{
#
# The object rather than a copy of it, which is the whole of D108's
# composition.  A copy passes every assertion about a value at build
# time and drifts the moment the provider changes.
sub provider {
	return $_[0]->{provider};
}

# }}}
# dump_yaml - serialize data structure to YAML string {{{
sub dump_yaml {
	my ($self, $data) = @_;

	# Use JSON::PP for a reliable serialization, then convert to YAML-like format
	# This avoids depending on YAML::PP which may not be available
	return _to_yaml($data, 0);
}

# }}}
# git_uri - build git URI from source_control config {{{
sub git_uri {
	my ($self, $source_control) = @_;
	$source_control ||= ($self->{ast} ? $self->{ast}->integrations->{source_control} : {});

	my $provider = $source_control->{provider} || '';
	my $repo     = $source_control->{repository} || '';

	if ($provider eq 'github') {
		return sprintf("git\@github.com:%s.git", $repo);
	} elsif ($provider eq 'gitlab') {
		return sprintf("git\@gitlab.com:%s.git", $repo);
	} elsif ($source_control->{uri}) {
		return $source_control->{uri};
	} else {
		return $repo;
	}
}

# }}}
# secret_ref - format a secret reference for this platform {{{
sub secret_ref {
	my ($self, $ref) = @_;
	return undef unless defined $ref;

	# Unwrap secret_ref hash
	if (ref($ref) eq 'HASH' && exists $ref->{secret_ref}) {
		$ref = $ref->{secret_ref};
	}

	# Default Concourse format; override in subclass for other platforms
	return "(($ref))";
}

# }}}
# topological_sort - standard topological sort on workflow graph {{{
sub topological_sort {
	my ($self, $graph) = @_;

	my @sorted;
	my %visited;
	my %temp_mark;

	my $visit;
	$visit = sub {
		my ($node) = @_;
		return if $visited{$node};
		bail("Cycle detected in workflow graph at node '%s'", $node)
			if $temp_mark{$node};

		$temp_mark{$node} = 1;

		for my $edge (@{$graph->{edges} || []}) {
			if ($edge->{from} eq $node) {
				$visit->($edge->{to});
			}
		}

		delete $temp_mark{$node};
		$visited{$node} = 1;
		unshift @sorted, $node;
	};

	for my $node (sort keys %{$graph->{nodes} || {}}) {
		$visit->($node) unless $visited{$node};
	}

	return @sorted;
}

# }}}
# matches_pattern - check if a target name matches a glob pattern {{{
sub matches_pattern {
	my ($self, $name, $pattern) = @_;

	my $regex = join('', map {
		$_ eq '*' ? '.*' : $_ eq '?' ? '.' : quotemeta($_)
	} split(/([*?])/, $pattern, -1));

	return $name =~ /^$regex$/;
}

# }}}
# }}}
### Internal Helpers {{{

# _to_yaml - simple YAML serializer (no external dependency) {{{
sub _to_yaml {
	my ($data, $indent) = @_;
	$indent //= 0;
	my $prefix = '  ' x $indent;

	if (!defined $data) {
		return "~";
	} elsif (ref($data) eq 'HASH') {
		my @lines;
		for my $key (sort keys %$data) {
			my $val = $data->{$key};
			if (!defined $val) {
				push @lines, "${prefix}${key}: ~";
			} elsif (!ref($val)) {
				push @lines, "${prefix}${key}: " . _yaml_scalar($val);
			} elsif (ref($val) eq 'ARRAY' && !@$val) {
				push @lines, "${prefix}${key}: []";
			} elsif (ref($val) eq 'HASH' && !%$val) {
				push @lines, "${prefix}${key}: {}";
			} elsif (ref($val) eq 'ARRAY') {
				push @lines, "${prefix}${key}:";
				push @lines, _to_yaml_array($val, $indent + 1);
			} elsif (ref($val) eq 'HASH') {
				push @lines, "${prefix}${key}:";
				push @lines, _to_yaml($val, $indent + 1);
			} else {
				push @lines, "${prefix}${key}: " . _yaml_scalar("$val");
			}
		}
		return join("\n", @lines);
	} elsif (ref($data) eq 'ARRAY') {
		return _to_yaml_array($data, $indent);
	} else {
		return "${prefix}" . _yaml_scalar($data);
	}
}

# }}}
# _to_yaml_array - serialize array to YAML {{{
sub _to_yaml_array {
	my ($data, $indent) = @_;
	my $prefix = '  ' x $indent;
	my @lines;

	for my $item (@$data) {
		if (!defined $item) {
			push @lines, "${prefix}- ~";
		} elsif (!ref($item)) {
			push @lines, "${prefix}- " . _yaml_scalar($item);
		} elsif (ref($item) eq 'HASH') {
			my @keys = sort keys %$item;
			if (@keys) {
				my $first = shift @keys;
				my $val = $item->{$first};
				if (!ref($val)) {
					push @lines, "${prefix}- ${first}: " . _yaml_scalar($val);
				} else {
					push @lines, "${prefix}- ${first}:";
					push @lines, _to_yaml($val, $indent + 2);
				}
				for my $key (@keys) {
					$val = $item->{$key};
					if (!ref($val)) {
						push @lines, "${prefix}  ${key}: " . _yaml_scalar($val);
					} else {
						push @lines, "${prefix}  ${key}:";
						push @lines, _to_yaml($val, $indent + 2);
					}
				}
			} else {
				push @lines, "${prefix}- {}";
			}
		} elsif (ref($item) eq 'ARRAY') {
			push @lines, "${prefix}-";
			push @lines, _to_yaml_array($item, $indent + 1);
		}
	}

	return join("\n", @lines);
}

# }}}
# _yaml_scalar - format a scalar value for YAML output {{{
sub _yaml_scalar {
	my ($val) = @_;

	# Booleans
	if (ref($val) eq 'JSON::PP::Boolean') {
		return $val ? 'true' : 'false';
	}

	# Numbers
	if ($val =~ /^-?\d+(\.\d+)?$/ && $val !~ /^0\d/) {
		return $val;
	}

	# Simple strings that don't need quoting
	if ($val =~ /^[a-zA-Z0-9_.\/-]+$/ && $val !~ /^(true|false|null|yes|no|on|off)$/i) {
		return $val;
	}

	# Multi-line strings
	if ($val =~ /\n/) {
		my @lines = split /\n/, $val;
		return "|\n" . join("\n", map { "  $_" } @lines);
	}

	# Strings that need quoting
	$val =~ s/\\/\\\\/g;
	$val =~ s/"/\\"/g;
	return "\"$val\"";
}

# }}}
# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
