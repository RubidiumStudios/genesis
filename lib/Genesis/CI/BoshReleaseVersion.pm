package Genesis::CI::BoshReleaseVersion;

use v5.20;
use warnings;

use Genesis::CI::BoshReleaseReference;

=head1 NAME

Genesis::CI::BoshReleaseVersion - All references to a specific BOSH release version

=head1 DESCRIPTION

Represents all references to a specific version of a BOSH release across a kit.
The same version may be referenced multiple times with different characteristics
(source vs compiled, different files, etc). This class handles prioritization
and provides a unified interface.

=head1 SYNOPSIS

  my $version = Genesis::CI::BoshReleaseVersion->new('1.19.45');
  
  $version->add_reference($ref1);  # source variant
  $version->add_reference($ref2);  # compiled variant
  
  my $selected = $version->get_selected_reference();  # prioritized choice
  say "Using " . $selected->get_display_type() . " variant";
  
  if ($version->has_multiple_variants()) {
    say "Found both source and compiled variants";
  }

=cut

# Constructor
sub new {
	my ($class, $version) = @_;
	
	return bless {
		version => $version,
		references => [],
		_selected_reference => undef,  # cached result
	}, $class;
}

# Public accessors
sub version { $_[0]->{version} }

# Add a reference to this version
sub add_reference {
	my ($self, $ref) = @_;
	
	# Validate that reference is for this version
	if ($ref->version() ne $self->{version}) {
		die "Reference version " . $ref->version() . " does not match " . $self->{version};
	}
	
	# Check for duplicates
	for my $existing (@{$self->{references}}) {
		return if $existing->matches_reference($ref);
	}
	
	push @{$self->{references}}, $ref;
	
	# Clear cached selection since we added a new reference
	$self->{_selected_reference} = undef;
	
	return $self;
}

# Get all references
sub get_references {
	my ($self) = @_;
	return @{$self->{references}};
}

# Get the prioritized reference using selection rules
sub get_selected_reference {
	my ($self) = @_;
	
	# Return cached result if available
	return $self->{_selected_reference} if $self->{_selected_reference};
	
	# Apply prioritization rules
	$self->{_selected_reference} = $self->_select_best_reference();
	
	return $self->{_selected_reference};
}

# Check if this version has multiple variants
sub has_multiple_variants {
	my ($self) = @_;
	
	return scalar(@{$self->{references}}) > 1;
}

# Check if this version has both source and compiled variants
sub has_source_and_compiled_variants {
	my ($self) = @_;
	
	my $has_source = 0;
	my $has_compiled = 0;
	
	for my $ref (@{$self->{references}}) {
		$has_source = 1 if $ref->is_source();
		$has_compiled = 1 if $ref->is_compiled();
	}
	
	return $has_source && $has_compiled;
}

# Get source variant references
sub get_source_references {
	my ($self) = @_;
	return grep { $_->is_source() } @{$self->{references}};
}

# Get compiled variant references  
sub get_compiled_references {
	my ($self) = @_;
	return grep { $_->is_compiled() } @{$self->{references}};
}

# Get repository URL from selected reference
sub get_repository_url {
	my ($self) = @_;
	
	my $selected = $self->get_selected_reference();
	return $selected ? $selected->get_repository_url() : undef;
}

# Get source URL if available, undef if only compiled references exist
sub get_source_url {
	my ($self) = @_;
	
	# Look for source references first
	my @source_refs = $self->get_source_references();
	return $source_refs[0]->url() if @source_refs;
	
	# No source references available
	return undef;
}

# Private method to select the best reference using prioritization rules
sub _select_best_reference {
	my ($self) = @_;
	
	my @refs = @{$self->{references}};
	return undef unless @refs;
	return $refs[0] if @refs == 1;
	
	# Prioritization rules:
	# 1. Prefer source over compiled
	# 2. Prefer overlay/ files over bosh-deployment/
	# 3. Prefer more specific paths (fewer wildcards/patterns)
	
	my @sorted = sort {
		# Rule 1: Source beats compiled
		my $a_compiled = $a->is_compiled() ? 1 : 0;
		my $b_compiled = $b->is_compiled() ? 1 : 0;
		return $a_compiled <=> $b_compiled if $a_compiled != $b_compiled;
		
		# Rule 2: overlay/ beats bosh-deployment/
		my $a_overlay = $a->source_file() =~ m{^overlay/} ? 1 : 0;
		my $b_overlay = $b->source_file() =~ m{^overlay/} ? 1 : 0;
		return $b_overlay <=> $a_overlay if $a_overlay != $b_overlay;
		
		# Rule 3: Shorter paths (more specific) beat longer paths
		return length($a->source_file()) <=> length($b->source_file());
	} @refs;
	
	return $sorted[0];
}

1;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu