package Genesis::CI::Provider;
use strict;
use warnings;

use Genesis;
use Getopt::Long qw/GetOptionsFromArray/;

### Class Methods {{{

# provider_class - load and return the CLI class for a provider type {{{
#
# The one place a type becomes a class on this side, reading the registry
# in Genesis::CI::Compiler::PipelineProvider so the valid list is the same
# list the schema's enum is built from.
sub provider_class {
	my ($class, $type) = @_;

	require Genesis::CI::Compiler::PipelineProvider;
	my $info = Genesis::CI::Compiler::PipelineProvider->provider_info($type);
	bail(
		"Unknown CI provider type '%s'. Valid types: %s", $type // '<undefined>',
		join(', ', Genesis::CI::Compiler::PipelineProvider->known_providers())
	) unless $info;

	eval { require $info->{cli_file} }  ## no critic
		or bail("Failed to load CI provider '%s': %s", $type, $@);

	return $info->{cli_class};
}

# }}}
# new - builder for creating new instance of derived class based on config {{{
sub new {
	my ($class, %config) = @_;
	bug("%s->new is calling %s->new illegally", $class, __PACKAGE__)
		if $class ne __PACKAGE__;

	my $type = $config{type} || 'manual';
	my $obj  = $class->provider_class($type)->new(%config);

	my @errors = $obj->validate_config;
	bail(
		"Invalid CI provider configuration for type '%s':\n%s",
		$type, join("\n", map { "  - $_" } @errors)
	) if @errors;

	return $obj;
}

# }}}
# init - builder for creating new instance based on CLI options {{{
sub init {
	my ($class, %opts) = @_;
	bug("%s->init is calling %s->init illegally", $class, __PACKAGE__)
		if $class ne __PACKAGE__;

	my $type = $opts{'ci-provider'} || 'manual';
	return $class->provider_class($type)->init(%opts);
}

# }}}
# parse_opts - two-pass extraction: first --ci-provider, then provider-specific flags {{{
sub parse_opts {
	my ($class, $args, $ci_opts) = @_;
	Getopt::Long::Configure(qw(pass_through permute no_auto_abbrev no_ignore_case bundling));

	# Stop at '--'
	my $opt_args = [];
	while (scalar(@$args) && $args->[0] ne '--') {
		push @$opt_args, shift @$args;
	}

	# First pass: extract --ci-provider
	GetOptionsFromArray($opt_args, $ci_opts, qw/ci-provider=s/);
	my $type = $ci_opts->{'ci-provider'};

	# Second pass: extract provider-specific flags, through the same
	# registry lookup, so this reads no third list of valid types.
	my @extra_opts = $class->provider_class($type || 'manual')->opts();

	GetOptionsFromArray($opt_args, $ci_opts, @extra_opts) if @extra_opts;

	# Return non-option args to $args
	while (scalar(@$opt_args)) { unshift @$args, pop @$opt_args }

	return 1;
}

# }}}
# opts_slot - key name for this handler's parsed options in $COMMAND_OPTIONS {{{
sub opts_slot { 'ci_provider' }

# }}}
# opts - base class has no options of its own {{{
sub opts {
	qw//;
}

# }}}
# opts_help - aggregate usage docs from all providers {{{
sub opts_help {
	my ($class, %config) = @_;
	bug("%s->opts_help is calling %s->opts_help illegally", $class, __PACKAGE__)
		if $class ne __PACKAGE__;

	require Genesis::CI::Compiler::PipelineProvider;
	my @types = Genesis::CI::Compiler::PipelineProvider->known_providers();

	$config{type_default_msg} ||= '(optional, defaults to "manual")';
	$config{valid_types}      ||= [@types];

	# The types and their help text both come from the registry, so this
	# text cannot name a provider the schema's enum does not hold.
	my $type_list     = join(', ', @types);
	my $provider_help = join('',
		map {$class->provider_class($_)->opts_help(%config)} @types
	);

	<<EOF;
CI PROVIDERS

Genesis can configure a CI/CD pipeline for your deployment repository.
Each provider type requires its own set of options.

  General CI Provider Options:

    --ci-provider <type> $config{type_default_msg}
        The type of CI provider to configure.  Valid types:
        $type_list.

$provider_help
EOF
}

# }}}
# }}}
### Instance Methods {{{

# label - human-readable name for this provider {{{
sub label {
	$_[0]->{label} // 'CI Provider';
}

# }}}
# config - returns hash for .genesis/config ci.provider section (abstract) {{{
sub config {
	my ($self) = @_;
	bug("Abstract Method: %s class must define 'config'", ref($self));
}

# }}}
# check_prereqs - returns 1 if toolchain is present, 0 + error() if not {{{
sub check_prereqs {
	return 1;
}

# }}}
# validate_config - check stored config fields; returns list of error strings {{{
#
# Called by Provider->new after the subclass object is constructed, and by
# Genesis::Top::_validate_provider_config at configuration load, which is
# where D86 puts the programmatic half of the provider contract.
# Subclasses override this to assert that all required fields are present and
# well-formed.  Returning an empty list means the config is valid.
#
# It states the rules a declaration cannot, which is a rule like "target or
# url but not neither", or a key required only when another is set, and it
# leaves everything a schema can already say to the schema.  No network
# calls are made here: every command loads the configuration, so a check
# that dialled the provider would make every command wait on that provider
# being up.
sub validate_config {
	return ();
}

# }}}
# interactive_wizard - prompt the user for provider config interactively (abstract) {{{
sub interactive_wizard {
	my ($self, $top) = @_;
	bug("Abstract Method: %s class must define 'interactive_wizard'", ref($self));
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Provider - CI provider factory and base class

=head1 DESCRIPTION

Genesis::CI::Provider is the factory and abstract base class for CI provider
configuration management.  It follows the same pattern as Genesis::Kit::Provider.

Concrete subclasses: Concourse, GithubActions, Manual.

=head1 SYNOPSIS

  # Parse CLI opts (two-pass: --ci-provider first, then provider-specific)
  my %ci_opts;
  Genesis::CI::Provider->parse_opts(\@ARGV, \%ci_opts);

  # Build provider object from CLI opts
  my $provider = Genesis::CI::Provider->init(%ci_opts);

  # Get config hash for .genesis/config ci.provider section
  my %cfg = $provider->config();

  # Reconstruct from stored config
  my $provider = Genesis::CI::Provider->new(type => 'concourse', target => 'prod');

=head1 SEE ALSO

Genesis::Kit::Provider, Genesis::CI::Compiler

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
