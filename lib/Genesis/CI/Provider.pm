package Genesis::CI::Provider;
use strict;
use warnings;

use Genesis;
use Getopt::Long qw/GetOptionsFromArray/;

### Class Methods {{{

# provider_class - load and return the CLI class for a provider type {{{
#
# A type becomes a class in Genesis::CI::ProviderRegistry, which owns the
# lookup and which both families consult, so this is a delegation and
# holds no list of its own.  It stays here while the callers outside this
# file move onto the registry.
sub provider_class {
	my ($class, $type) = @_;

	require Genesis::CI::ProviderRegistry;
	return Genesis::CI::ProviderRegistry->provider_class($type);
}

# }}}
# new - builder for creating new instance of derived class based on config {{{
#
# It builds and nothing more.  The rules for a provider's block are asked
# of the class, against the configuration the block sits in, so a check
# here would be asking an object assembled out of that block what the
# block says, one step further from what the operator wrote and one phase
# away from every other configuration refusal.
sub new {
	my ($class, %config) = @_;
	bug("%s->new is calling %s->new illegally", $class, __PACKAGE__)
		if $class ne __PACKAGE__;

	my $type = $config{type} || 'manual';
	require Genesis::CI::ProviderRegistry;
	return Genesis::CI::ProviderRegistry->provider_class($type)->new(%config);
}

# }}}
# init - builder for creating new instance based on CLI options {{{
sub init {
	my ($class, %opts) = @_;
	bug("%s->init is calling %s->init illegally", $class, __PACKAGE__)
		if $class ne __PACKAGE__;

	my $type = $opts{'ci-provider'} || 'manual';
	require Genesis::CI::ProviderRegistry;
	return Genesis::CI::ProviderRegistry->provider_class($type)->init(%opts);
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
	require Genesis::CI::ProviderRegistry;
	my @extra_opts = Genesis::CI::ProviderRegistry
		->provider_class($type || 'manual')->opts();

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

	require Genesis::CI::ProviderRegistry;
	my @types = Genesis::CI::ProviderRegistry->known_providers();

	$config{type_default_msg} ||= '(optional, defaults to "manual")';
	$config{valid_types}      ||= [@types];

	# The types and their help text both come from the registry, so this
	# text cannot name a provider the schema's enum does not hold.
	my $type_list     = join(', ', @types);
	my $provider_help = join('',
		map {Genesis::CI::ProviderRegistry->provider_class($_)->opts_help(%config)}
			@types
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
# This is mandatory, because its readers are pipeline-describe's resolved
# values, the per-key defaults, the help text, and the post-MVP wizard,
# and none of those is validation.  Without it the per-provider key table
# goes back to being hand-listed beside the classes, and a hand-listed
# table is what the declaration is here to prevent.
#
# It sits here rather than on the compiler base because the default
# validate_config validates against it, and a default cannot reach a
# declaration in another hierarchy.
sub provider_options_schema {
	my ($self) = @_;
	bug("Subclass '%s' must implement provider_options_schema()", ref($self) || $self);
}

# }}}
# capabilities - what this provider can do, as six booleans (abstract) {{{
#
# The six capability names, declared beside the fragment so that one class
# answers for both halves of a provider.  They are mandatory for the same
# reason the fragment is, because a provider whose abilities are unknown
# cannot have its keys gated, and the gate that stood aside for it
# accepted a key the provider can never honour.
sub capabilities {
	my ($self) = @_;
	bug("Subclass '%s' must implement capabilities()", ref($self) || $self);
}

# }}}
# The six capability names, held in one place so that the declaration
# above and the contract check below cannot drift.  The gate map beneath
# them still spells the names it gates as literals, so a seventh
# capability has to be added there by hand, and nothing here will say so
# if it is not.
#
# Sorted here rather than at the comparison, because the check below asks
# whether two sorted lists are the same text and a name written in the
# obvious place rather than in alphabetical order would otherwise fail
# every provider in the tree.
my @_capabilities = sort qw/
	cross_pipeline_events deployment_locks multi_file_output
	optional_git_triggers per_commit_runs scheduled_jobs
/;

# declared_capabilities - one provider class's declaration, checked {{{
#
# The contract behind capabilities(), asked once at configuration load
# where the gates read it, rather than trusted afresh at every gate.  A
# declaration that answers anything but exactly the six names is a bug in
# the provider class, and the two ways to get it wrong both go unnoticed
# otherwise.  A misspelled name reads as false and refuses the key it
# gates as though somebody had meant it to, and a name left out loses its
# ability with nothing said at all, since three of the six gate no key.
#
# It sits here, beside the declaration it checks, rather than on the
# compiler base.  A capability is what a provider can do, which is
# neither about emitting anything nor about which providers exist, and
# leaving the check on the compiler side left Genesis::Top reaching into
# the compiler family to ask a provider what it is able to do.
sub declared_capabilities {
	my ($class, $provider) = @_;

	my $caps = $provider->capabilities;
	bug("CI provider '%s' must answer capabilities() with a hash reference",
		$provider) unless ref($caps) eq 'HASH';

	my @declared = sort keys %$caps;
	bug("CI provider '%s' declares the capabilities %s, and the six are %s",
		$provider, join(', ', @declared), join(', ', @_capabilities))
		unless join("\0", @declared) eq join("\0", @_capabilities);

	return $caps;
}

# }}}
# capability_gates - which configuration key each capability gates {{{
#
# Two of the six gate nothing configurable, since deployment_locks and
# cross_pipeline_events are structural and their absence is a "no such
# capability" outcome rather than a refused key.
#
# multi_file_output gates nothing here either.  The key it gated,
# output_layout, is declared by the provider that can use it and by nobody
# else, so a provider that cannot offers no such key and the refusal is
# the ordinary undeclared-key refusal.
sub capability_gates {
	return {
		optional_git_triggers => 'genesis.pipeline.manual',
		scheduled_jobs        => 'genesis.pipeline.redeploy_cron',
		per_commit_runs       => 'pipeline.provider.group_commits',
	};
}

# }}}
# validate_config - the provider's rules for its own block {{{
#
# The provider owns validating the block an operator wrote for it,
# outright, and it decides how: by declaration, which is what this default
# does, or programmatically, which is what an override adds.  The
# framework used to split the two and ask every provider to sort its own
# rules into its categories, and then checked half of them before the
# provider was called at all.
#
# The default validates the block against this provider's own
# provider_options_schema, so a provider with no cross-field rule writes
# no validation whatsoever and still gets the generic pass, its type
# checks, its defaults, and the error text every other block gets.
# Because the default reads the same fragment the declaration is, the two
# cannot drift apart in the ordinary case, which the older split could not
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
# section_enabled - whether the section the block sits in is switched on {{{
#
# A provider's own rules run only where the section its block sits in is
# enabled, and this is where a provider asks.  The provider walk once sat
# behind the pipeline gate and never had to ask, and now the rules are
# reached from the configuration walk instead, which runs whether or not
# anybody has turned a pipeline on.  An operator writes a provider block a
# key at a time, so a repository with a pipeline nobody has enabled must
# not be refused for a key that pipeline would need.
#
# The section is the block's own parent, which is all a provider knows
# about where it sits, and a block with no parent is taken to be running,
# since there is no section to ask about.
sub section_enabled {
	my ($class, $config, $path) = @_;

	my ($section) = ($path // '') =~ m{^(.*)\.[^.]+$};
	return 1 unless defined $section && length $section;
	return $config->get("$section.enabled") ? 1 : 0;
}

# }}}
# }}}
### Instance Methods {{{

# label - human-readable name for this provider {{{
sub label {
	$_[0]->{label} // 'CI Provider';
}

# }}}
# type - the registered type this provider was built under {{{
#
# Set where the type is known rather than worked out later.  The only
# other place a type could be read from is config, which answers a hash,
# and Perl randomises a hash's order once per process, so indexing into
# that list gives the right answer for manual and a coin toss for
# everything else.
sub type {
	return $_[0]->{type};
}

# }}}
# compiler - the compiler that emits this provider's artefact {{{
#
# The provider's side of the composition.  A provider hands its compiler
# out and the compiler holds the provider, which is what gives
# DEFAULT_TEAM and check_prereqs one home each rather than two.
#
# A provider with no artefact to emit answers with nothing, which is
# what manual does honestly and what github-actions does until its
# compiler lands.  That is better than an abstract method left
# unimplemented, because a caller can ask any provider this question and
# read the answer rather than trapping a bug().
#
# A caller that needs a compiler rather than merely asking whether there
# is one passes required, and the registry refuses with the message
# b98d60f1 kept: emitting a pipeline and validating a block are
# different questions, and a provider may answer the second while having
# nothing to answer the first with.
sub compiler {
	my ($self, %opts) = @_;

	require Genesis::CI::ProviderRegistry;
	my $type = $self->type;
	my $info = Genesis::CI::ProviderRegistry->provider_info($type);
	return undef unless $opts{required} || ($info && $info->{class});

	my $class = Genesis::CI::ProviderRegistry->compiler_class($type);
	return $class->new(
		provider      => $self,
		ast           => $opts{ast},
		top           => $opts{top},
		provider_opts => $opts{provider_opts} || {},
	);
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
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
