package Genesis::CI::ProviderRegistry;
use strict;
use warnings;

use Genesis;
use Genesis::Exit qw/CONFIG/;

### The registry {{{
#
# The one registry, under D28 and D108.  It sits in neither family
# because both consult it: the provider side asks it which class answers
# for a type, and the compiler side asks it which class emits for one.
# Before D108 the map lived in a compiler module and the provider family
# reached into that module to find itself, so the provider family
# depended on the compiler family, which is backwards.
#
# Under D28 the schema's enum, every class lookup, and every "valid
# types" message read this map, so a provider cannot be spelled one way
# in the schema and another in the code, which is the drift H26 names.
# The manual provider has no compiling class, because under D43
# pipeline-apply sets no pipeline for it, and the github-actions
# provider has none yet either: the type validates and resolves on the
# CLI side, and its compiling class arrives with the provider itself.
#
# An entry says the classes and nothing else.  Every package under lib
# now derives its own path, so a path written beside a class would be a
# second spelling of the same fact, and the two could disagree.  The
# concourse entry carried both because Genesis::CI::Concourse sat at a
# path its package did not derive, which D108's rename put right.

my %_providers = (
	'concourse' => {
		class     => 'Genesis::CI::ProviderCompiler::Concourse',
		cli_class => 'Genesis::CI::Provider::Concourse',
	},
	'github-actions' => {
		cli_class => 'Genesis::CI::Provider::GithubActions',
	},
	'manual' => {
		cli_class => 'Genesis::CI::Provider::Manual',
	},
);

# known_providers - every registered provider type, sorted {{{
sub known_providers {
	return sort keys %_providers;
}

# }}}
# provider_info - one registry entry, or undef {{{
#
# The entry's class and file name the compiling class, which the manual
# and github-actions providers do not have, and cli_class and cli_file
# name the class the CLI builds, which every type has.  Each path is
# always worked out from the class beside it rather than read from the
# entry, so a caller that wants a path to require still gets one and no
# entry can name a path its class does not derive.  A stored path is
# never honoured in preference, because register_provider refuses one
# that disagrees and a path that agrees says nothing new.
#
# A shallow copy rather than the registry's own hash reference, because
# a caller that writes into what it was given would otherwise rewrite
# the registry for the rest of the process, and a later lookup of the
# same type would answer whatever the writer put there.
sub provider_info {
	my ($class, $type) = @_;
	return undef unless defined $type && exists $_providers{$type};

	my %info = %{$_providers{$type}};
	$info{file}     = _path_of($info{class})     if $info{class};
	$info{cli_file} = _path_of($info{cli_class}) if $info{cli_class};
	return \%info;
}

# }}}
# automated_providers - the types that are not manual {{{
#
# The list a required-under-an-automated-provider check reads, so no
# caller writes "not manual" by hand.
sub automated_providers {
	return grep {$_ ne 'manual'} known_providers();
}

# }}}
# register_provider - add a registry entry at run time {{{
#
# For tests that stand a provider class up and for a future out-of-tree
# provider.  The registry is otherwise fixed at compile time.
#
# Four guards.  A missing name would register the entry under the empty
# string, where nothing could look it up.  A name already registered is
# refused rather than replaced, since replacing the real concourse entry
# would leave the enum saying one thing and the lookup doing another.  An
# entry with no cli_class is refused because every type has a CLI class
# and a resolver that finds none behaves like manual instead of saying
# so.  And a path that disagrees with the class beside it is refused
# rather than honoured, because that disagreement is the mismatch D108's
# rename removed from lib and there is no reason to let one back in.
sub register_provider {
	my ($class, $type, $info) = @_;

	bug("A CI provider must be registered under a name")
		unless defined $type && length $type;
	bug("CI provider '%s' is already registered", $type)
		if exists $_providers{$type};
	bug("CI provider '%s' must be registered with a cli_class", $type)
		unless ref($info) eq 'HASH' && $info->{cli_class};

	for my $pair ([qw/file class/], [qw/cli_file cli_class/]) {
		my ($path_key, $class_key) = @$pair;
		next unless $info->{$path_key} && $info->{$class_key};
		bug("CI provider '%s' registers a %s of '%s', which does not match ".
			"its %s '%s'", $type, $path_key, $info->{$path_key},
			$class_key, $info->{$class_key})
			unless $info->{$path_key} eq _path_of($info->{$class_key});
	}

	$_providers{$type} = $info;
	return 1;
}

# }}}
# }}}
### Resolution {{{

# provider_class - the CLI class for a type, loaded {{{
#
# The provider family's own lookup, which used to live on
# Genesis::CI::Provider and read a compiler module to answer.
sub provider_class {
	my ($class, $type) = @_;

	my $info = $class->provider_info($type) or _unknown($type);
	eval {require $info->{cli_file}}  ## no critic
		or bail("Failed to load CI provider '%s': %s", $type, $@);
	return $info->{cli_class};
}

# }}}
# compiler_class - the compiling class for a type, loaded {{{
#
# The refusal below is the one b98d60f1 deliberately kept in
# Genesis::CI, and it outlives the file it was written in.  Emitting a
# pipeline and validating a block are different questions, and a
# provider may legitimately answer the second while having nothing to
# answer the first with.  It exits CONFIG because a repository whose
# configured provider Genesis cannot compile for is a repository the
# operator can put right.
sub compiler_class {
	my ($class, $type) = @_;

	my $info = $class->provider_info($type) or _unknown($type);
	bail({exitcode => CONFIG},
		"Genesis knows the '%s' provider but has no compiler for it yet, so ".
		"there is no pipeline to compile until that provider lands.", $type)
		unless $info->{class};

	eval {require $info->{file}}  ## no critic
		or bail("Failed to load CI provider '%s': %s", $type, $@);
	return $info->{class};
}

# }}}
# }}}
### Internal Helpers {{{

# _path_of - the file path a package name derives {{{
#
# The one place that turns a class into something require can take, so
# an entry names its classes and the registry works the rest out.
sub _path_of {
	my ($package) = @_;
	(my $path = $package) =~ s{::}{/}g;
	return "$path.pm";
}

# }}}
# _unknown - the refusal for a type the registry does not hold {{{
sub _unknown {
	my ($type) = @_;
	bail({exitcode => CONFIG},
		"Unknown CI provider type '%s'. Valid types: %s", $type // '<undefined>',
		join(', ', known_providers()));
}

# }}}
# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
