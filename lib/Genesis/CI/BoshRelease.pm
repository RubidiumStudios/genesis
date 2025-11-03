package Genesis::CI::BoshRelease;

use v5.20;
use warnings;

use Genesis qw(by_semver);
use Genesis::CI::BoshReleaseVersion;

=head1 NAME

Genesis::CI::BoshRelease - All versions of a named BOSH release

=head1 DESCRIPTION

Represents all versions of a specific BOSH release (e.g., "backup-and-restore-sdk")
found in a kit. Manages the collection of versions and provides methods for
querying and comparison.

=head1 SYNOPSIS

  my $release = Genesis::CI::BoshRelease->new('backup-and-restore-sdk');
  
  $release->add_reference($ref1);  # Adds to appropriate version
  $release->add_reference($ref2);
  
  my $latest = $release->get_latest_version();
  my @all_versions = $release->get_all_versions();
  
  if ($release->has_multiple_variants()) {
    say "Release has both source and compiled variants";
  }

=cut

# Constructor
sub new {
	my ($class, $name) = @_;
	
	return bless {
		name => $name,
		versions => {},      # version string => BoshReleaseVersion
		_latest_version => undef,  # cached result
	}, $class;
}

# Public accessors
sub name { $_[0]->{name} }

# Add a reference, creating version if needed
sub add_reference {
	my ($self, $ref) = @_;
	
	# Validate that reference is for this release
	if ($ref->name() ne $self->{name}) {
		die "Reference name " . $ref->name() . " does not match " . $self->{name};
	}
	
	my $version_str = $ref->version();
	
	# Create version object if it doesn't exist
	if (!exists $self->{versions}{$version_str}) {
		$self->{versions}{$version_str} = Genesis::CI::BoshReleaseVersion->new($version_str);
	}
	
	# Add reference to the version
	$self->{versions}{$version_str}->add_reference($ref);
	
	# Clear cached latest version since we may have added a new one
	$self->{_latest_version} = undef;
	
	return $self;
}

# Get a specific version
sub get_version {
	my ($self, $version_str) = @_;
	return $self->{versions}{$version_str};
}

# Get source URL for a specific version
sub get_source_url {
	my ($self, $version_str) = @_;
	
	my $version = $self->get_version($version_str);
	return undef unless $version;
	
	return $version->get_source_url();
}

# Get all version objects
sub get_all_versions {
	my ($self) = @_;
	return values %{$self->{versions}};
}

# Get all version strings sorted by semver
sub get_version_strings {
	my ($self, $descending) = @_;
	
	my @versions = keys %{$self->{versions}};
	
	if ($descending) {
		return reverse sort by_semver @versions;
	} else {
		return sort by_semver @versions;
	}
}

# Get the latest (highest semver) version
sub get_latest_version {
	my ($self) = @_;
	
	# Return cached result if available
	return $self->{_latest_version} if $self->{_latest_version};
	
	my @version_strings = $self->get_version_strings(1);  # descending
	return undef unless @version_strings;
	
	$self->{_latest_version} = $self->{versions}{$version_strings[0]};
	return $self->{_latest_version};
}

# Get the latest version string
sub get_latest_version_string {
	my ($self) = @_;
	
	my $latest = $self->get_latest_version();
	return $latest ? $latest->version() : undef;
}

# Check if this release has multiple variants (same version, different characteristics)
sub has_multiple_variants {
	my ($self) = @_;
	
	for my $version (values %{$self->{versions}}) {
		return 1 if $version->has_multiple_variants();
	}
	
	return 0;
}

# Check if this release has both source and compiled variants
sub has_source_and_compiled_variants {
	my ($self) = @_;
	
	for my $version (values %{$self->{versions}}) {
		return 1 if $version->has_source_and_compiled_variants();
	}
	
	return 0;
}

# Get summary for display purposes
sub get_version_summary {
	my ($self) = @_;
	
	my @version_strings = $self->get_version_strings(1);  # latest first
	return join(', ', @version_strings);
}

# Get detailed variant information for reporting
sub get_variant_info {
	my ($self) = @_;
	
	my @variant_info;
	
	for my $version (values %{$self->{versions}}) {
		next unless $version->has_source_and_compiled_variants();
		
		my @source_files = map { $_->get_display_source() } $version->get_source_references();
		my @compiled_files = map { $_->get_display_source() } $version->get_compiled_references();
		
		push @variant_info, {
			version => $version->version(),
			source_count => scalar($version->get_source_references()),
			compiled_count => scalar($version->get_compiled_references()),
			source_files => \@source_files,
			compiled_files => \@compiled_files
		};
	}
	
	return @variant_info;
}

# Get count of versions
sub version_count {
	my ($self) = @_;
	return scalar(keys %{$self->{versions}});
}

# Check if release has specific version
sub has_version {
	my ($self, $version_str) = @_;
	return exists $self->{versions}{$version_str};
}

1;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu