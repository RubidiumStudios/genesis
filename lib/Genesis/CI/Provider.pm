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
#
# It builds and nothing more.  Under D105 the rules for a provider's block
# are asked of the class, against the configuration the block sits in, so
# a check here would be asking an object assembled out of that block what
# the block says, one step further from what the operator wrote and one
# phase away from every other configuration refusal.
sub new {
	my ($class, %config) = @_;
	bug("%s->new is calling %s->new illegally", $class, __PACKAGE__)
		if $class ne __PACKAGE__;

	my $type = $config{type} || 'manual';
	return $class->provider_class($type)->new(%config);
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
# provider_options_schema - the keys this provider reads (abstract) {{{
#
# Under D86 this is mandatory and under D105 it stays mandatory, because
# its readers are pipeline-describe's resolved values, the per-key
# defaults, the help text, and the post-MVP wizard, and none of those is
# validation.  Without it the per-provider key table goes back to being
# hand-listed beside the classes, which is what D86 exists to prevent.
#
# It sits here rather than on the compiler base because D105's default
# validate_config validates against it, and a default cannot reach a
# declaration in another hierarchy.
sub provider_options_schema {
	my ($self) = @_;
	bug("Subclass '%s' must implement provider_options_schema()", ref($self) || $self);
}

# }}}
# capabilities - what this provider can do, as six booleans (abstract) {{{
#
# D101's six names, declared beside the fragment under D105 so that one
# class answers for both halves of a provider.  Mandatory for the same
# reason the fragment is: a provider whose abilities are unknown cannot
# have its keys gated, and the gate that stood aside for it accepted a
# key the provider can never honour.
sub capabilities {
	my ($self) = @_;
	bug("Subclass '%s' must implement capabilities()", ref($self) || $self);
}

# }}}
# validate_config - the provider's rules for its own block {{{
#
# Under D105 the provider owns validating the block an operator wrote for
# it, outright, and it decides how: by declaration, which is what this
# default does, or programmatically, which is what an override adds.  D86
# split the two and asked every provider to sort its own rules into the
# framework's categories, and then checked half of them before the
# provider was called at all.
#
# The default validates the block against this provider's own
# provider_options_schema, so a provider with no cross-field rule writes
# no validation whatsoever and still gets the generic pass, its type
# checks, its defaults, and the error text every other block gets.
# Because the default reads the same fragment the declaration is, the two
# cannot drift apart in the ordinary case, which is what D86 could not
# promise.
#
# A provider with a rule a declaration cannot state overrides this and
# calls SUPER first, because the declaration is the floor rather than a
# subset of what the provider wants checked.
#
# The discriminator names the key the parent declared to choose this
# class, which no fragment declares, so it is handed through as the one
# key this pass leaves alone.  No network call is made from here: every
# command loads the configuration, and a check that dialled the provider
# would make every command wait on that provider being up.
sub validate_config {
	my ($class, $config, $path, $discriminator) = @_;

	return $config->validate_subtree(
		$path, $class->provider_options_schema,
		ignore => [$discriminator // 'type']
	);
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

A provider class declares the keys it reads, through
C<provider_options_schema>, declares what it is able to do, through
C<capabilities>, and validates the block an operator wrote for it, through
C<validate_config>. The three live together so that the check always has
the declaration it is checking against, and so that one class answers for
the whole of a provider.

C<capabilities> answers with the six booleans
L<Genesis::CI::Compiler::PipelineProvider> names, and every provider has to
answer, including the ones Genesis cannot yet compile a pipeline for. A
provider that can do none of them says so rather than staying silent,
because a key gated on an ability nobody declared would otherwise be
accepted and then dropped. The compiler-side class reads this declaration
from here rather than keeping one of its own.

Validating that block is the provider's own job and not the framework's,
and the base does it by validating the block against the keys that
provider declared, so an ordinary provider writes no validation at all
and still gets its types checked, its defaults filled, and its unknown
keys refused by name. A provider overrides C<validate_config> only for a
rule a declaration cannot state, such as one key being required when
another is absent, and an override calls C<SUPER> first, because the
declaration is the floor rather than a subset of what is wanted checked.

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
