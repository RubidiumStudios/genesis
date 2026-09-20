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
# A compiler holds the provider it emits for rather than a copy of that
# provider's settings, so DEFAULT_TEAM and check_prereqs have one home each
# and a change on the provider is visible here with nothing rebuilt.  A caller
# reaches this through $provider->compiler(ast => $ast) rather than calling it
# directly.
#
# The concrete used to define its own new and drop everything but ast,
# top, and provider_opts, which would have thrown the provider away on
# the way in.  It inherits this one now.
sub new {
	my ($class, %opts) = @_;

	bug("Cannot instantiate Genesis::CI::ProviderCompiler directly; ".
		"use a subclass instead")
		if $class eq __PACKAGE__;

	# The concrete's deleted constructor carried this refusal, and it is
	# worth keeping: a compiler blessed over an undefined AST fails much
	# later and says far less about why, so the route that always has one
	# is named here.
	bug("A compiler needs the AST it emits from; ".
		"build it with \$provider->compiler(ast => \$ast)")
		unless $opts{ast};

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
### Prerequisite Checking is the provider's {{{
#
# Nothing here answers for a toolchain any more.  This class carried a default
# that said yes to everything, and the Concourse compiler overrode it with a
# check weaker than the provider's, so the question goes to the provider now
# and the answer comes back from one place.
#
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
# where provider_options_schema and capabilities went {{{
#
# Both were forwarders on this class, and each resolved the CLI class
# through the registry all over again so that a compiler could answer
# for a provider's own declaration.  A compiler that holds its provider
# asks that provider instead:
#
#   $self->provider->provider_options_schema
#   $self->provider->capabilities
#
# which is one hop rather than a class resolution, and which cannot
# answer differently from the class that declared it.
# }}}
# provider_options_defaults - default values for provider options {{{
#
# Returns a flat hashref of key => default_value.  Keys match those the
# held provider declares.  Values here are NOT included in the config()
# output, since only explicitly-set non-default values are saved.
#
# An instance method rather than a class method, because the declaration
# is read off the provider this compiler holds and a class has no
# provider to ask.  The base declares nothing of its own, as it did.
sub provider_options_defaults {
	return {};
}

# }}}
# provider_config - return stored provider options (non-defaults only) {{{
#
# Returns a hashref suitable for round-tripping through the ci.provider:
# config section, which is the type key plus any explicitly-set values
# that differ from provider_options_defaults().
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
#
# The stored value wins where there is one, and definedness is what says
# so.  A key an operator wrote with no value after it is the operator
# declining to choose rather than choosing nothing, so a bare "team:"
# still resolves to what the fragment declares.  Read on presence
# instead, the key was there and the value was undef, and the default
# below was never reached.
sub provider_option {
	my ($self, $key) = @_;
	my $opts     = $self->{provider_opts} || {};
	my $defaults = $self->provider_options_defaults();
	return defined $opts->{$key}    ? $opts->{$key}
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
### Class Methods for Provider Options Parsing {{{

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
# The object rather than a copy of it, which is the whole of the composition.
# A copy passes every assertion about a value at build time and drifts the
# moment the provider changes.
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
#
# The declaration falls back to the AST's own only for a caller that
# holds one, because the pipeline descriptor asks this class for the
# spelling rather than asking an instance of it, and a class name has no
# AST to fall back to.
sub git_uri {
	my ($self, $source_control) = @_;
	$source_control ||= (ref($self) && $self->{ast})
		? $self->{ast}->integrations->{source_control}
		: {};

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

# _is_yaml_leaf - a value the scalar writer can take {{{
#
# A plain scalar or a boolean.  A boolean is a blessed reference, so a
# plain-scalar test alone answers false for one and the value falls
# through to a branch that either stringifies it into 1 or 0 or drops it
# without a word.  Every position that writes a value asks this rather
# than asking for a reference of its own, so the three cannot drift
# apart about what a leaf is.
sub _is_yaml_leaf {
	my ($val) = @_;
	return !ref($val) || ref($val) eq 'JSON::PP::Boolean';
}

# }}}
# _yaml_key - a hash key in its YAML spelling {{{
#
# The rules a value takes, less the block form, because a key cannot be
# written over several lines.  A key used to be written exactly as it
# stood whatever it held, so one carrying a colon, a comment marker, or
# a word a reader takes for a boolean produced a document that came back
# as something else or would not parse at all.
sub _yaml_key {
	my ($name) = @_;
	return _yaml_quoted($name) if $name =~ /\n/;
	return _yaml_scalar($name, 0);
}

# }}}
# _yaml_quoted - a string in the double-quoted form {{{
#
# A newline is written as its escape rather than left where it stands,
# because a quoted string spread over several lines has them folded into
# spaces when it is read back.
sub _yaml_quoted {
	my ($val) = @_;
	$val =~ s/\\/\\\\/g;
	$val =~ s/"/\\"/g;
	$val =~ s/\n/\\n/g;
	return "\"$val\"";
}

# }}}
# _yaml_pair - write one key and its value under a list item {{{
#
# The lead is what the key sits behind, which is the dash for a list
# item's first key and plain spaces for the rest of them, and the indent
# is the level the value's own lines take.  An empty list or hash is
# written on the key's own line, because a key followed by nothing reads
# back as null rather than as the empty thing it was.
sub _yaml_pair {
	my ($lead, $name, $val, $indent) = @_;
	my $key = _yaml_key($name);

	return "${lead}${key}: ~"  if !defined $val;
	return "${lead}${key}: " . _yaml_scalar($val, $indent)
		if _is_yaml_leaf($val);
	return "${lead}${key}: []" if ref($val) eq 'ARRAY' && !@$val;
	return "${lead}${key}: {}" if ref($val) eq 'HASH'  && !%$val;

	return ("${lead}${key}:", _to_yaml($val, $indent));
}

# }}}
# _to_yaml - simple YAML serializer (no external dependency) {{{
sub _to_yaml {
	my ($data, $indent) = @_;
	$indent //= 0;
	my $prefix = '  ' x $indent;

	if (!defined $data) {
		return "~";
	} elsif (ref($data) eq 'HASH') {
		my @lines;
		for my $name (sort keys %$data) {
			my $val = $data->{$name};
			my $key = _yaml_key($name);
			if (!defined $val) {
				push @lines, "${prefix}${key}: ~";
			} elsif (_is_yaml_leaf($val)) {
				push @lines, "${prefix}${key}: " . _yaml_scalar($val, $indent + 1);
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
				push @lines, "${prefix}${key}: " . _yaml_scalar("$val", $indent + 1);
			}
		}
		return join("\n", @lines);
	} elsif (ref($data) eq 'ARRAY') {
		return _to_yaml_array($data, $indent);
	} else {
		return "${prefix}" . _yaml_scalar($data, $indent + 1);
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
		} elsif (_is_yaml_leaf($item)) {
			push @lines, "${prefix}- " . _yaml_scalar($item, $indent + 1);
		} elsif (ref($item) eq 'HASH') {
			my @keys = sort keys %$item;
			if (@keys) {
				# The first key wears the dash and the rest stand under it,
				# which is the only thing that separates them, so both take
				# the same writer.
				my $first = shift @keys;
				push @lines, _yaml_pair(
					"${prefix}- ", $first, $item->{$first}, $indent + 2);
				push @lines, _yaml_pair(
					"${prefix}  ", $_, $item->{$_}, $indent + 2) for @keys;
			} else {
				push @lines, "${prefix}- {}";
			}
		} elsif (ref($item) eq 'ARRAY') {
			push @lines, "${prefix}-";
			push @lines, _to_yaml_array($item, $indent + 1);
		} else {
			# Anything else is written as the string it prints as, rather
			# than passed over, so that a value this writer does not know
			# reaches the document and can be seen there.
			push @lines, "${prefix}- " . _yaml_scalar("$item", $indent + 1);
		}
	}

	return join("\n", @lines);
}

# }}}
# _yaml_scalar - format a scalar value for YAML output {{{
#
# The indent is the level the value's own lines sit at, which is one step
# in from the key or the dash that opens it.  Only a block scalar needs
# it, and it needs it absolutely, because a body written a fixed two
# spaces in produces a document no reader accepts anywhere below the top
# level.  A caller that names nothing gets the step a top-level value
# takes.
sub _yaml_scalar {
	my ($val, $indent) = @_;
	$indent //= 1;

	# Booleans
	if (ref($val) eq 'JSON::PP::Boolean') {
		return $val ? 'true' : 'false';
	}

	# Numbers.  One written with a leading zero is left to the quoted form
	# below, because a reader takes 0755 for an octal number and answers
	# 493 to anyone who asks for it back.
	if ($val =~ /^-?\d+(\.\d+)?$/ && $val !~ /^-?0\d/) {
		return $val;
	}

	# Simple strings that don't need quoting
	if ($val =~ /^[a-zA-Z0-9_.\/-]+$/
		&& $val !~ /^(true|false|null|yes|no|on|off)$/i
		&& $val !~ /^-?0\d/) {
		return $val;
	}

	# Multi-line strings.  The body stands at the indent the caller named,
	# and a value ending in one newline takes the clipping form while one
	# ending in none takes the stripping form, so that reading the document
	# back answers the string that was written.  A value opening on
	# whitespace or ending in more than one newline needs an indicator this
	# writer does not spell, and takes the quoted form instead.
	if ($val =~ /\n/ && $val =~ /^[^ \t\n]/ && $val !~ /\n\n\z/) {
		my $body  = $val;
		my $chomp = ($body =~ s/\n\z//) ? '' : '-';
		my $pad   = '  ' x $indent;
		return "|$chomp\n" . join("\n",
			map {length($_) ? "$pad$_" : ''} split(/\n/, $body, -1));
	}

	# Strings that need quoting
	return _yaml_quoted($val);
}

# }}}
# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
