package Genesis::CI::BoshReleaseReference;

use v5.20;
use warnings;

use Genesis qw(slurp load_yaml);

=head1 NAME

Genesis::CI::BoshReleaseReference - A single file reference to a BOSH release version

=head1 DESCRIPTION

Represents a single reference to a specific BOSH release version found in a kit file.
The same release version may be referenced from multiple files with different 
characteristics (source vs compiled, different URLs, etc).

=head1 SYNOPSIS

  my $ref = Genesis::CI::BoshReleaseReference->new(
    name => 'backup-and-restore-sdk',
    version => '1.19.45',
    source_file => 'bosh-deployment/bbr.yml',
    url => 'https://s3.amazonaws.com/...',
    sha1 => 'bb612e5665424be805e390e02cd4cc948a009447',
    context => { type => 'patch', line => 7 }
  );
  
  say $ref->is_compiled() ? 'compiled' : 'source';
  say $ref->get_display_source();

=cut

# Constructor
sub new {
	my ($class, %args) = @_;
	
	my $self = bless {
		name => $args{name},
		version => $args{version}, 
		source_file => $args{source_file},
		url => $args{url},
		sha1 => $args{sha1},
		context => $args{context} || {},
		metadata => $args{metadata} || {}
	}, $class;
	
	# Auto-determine if this is a compiled release
	$self->{_is_compiled} = $self->_determine_if_compiled($self->{url});
	
	return $self;
}

# Public accessors
sub name { $_[0]->{name} }
sub version { $_[0]->{version} }
sub source_file { $_[0]->{source_file} }
sub url { $_[0]->{url} }
sub sha1 { $_[0]->{sha1} }
sub context { $_[0]->{context} }
sub metadata { $_[0]->{metadata} }

# Compiled vs source detection
sub is_compiled { $_[0]->{_is_compiled} }
sub is_source { !$_[0]->{_is_compiled} }

# Display helpers
sub get_display_source {
	my ($self) = @_;
	return $self->{source_file};
}

sub get_display_type {
	my ($self) = @_;
	return $self->is_compiled() ? 'compiled' : 'source';
}

# Get the repository URL for job spec fetching
sub get_repository_url {
	my ($self) = @_;
	
	# For source releases, try to extract GitHub URL from bosh.io URLs
	if ($self->is_source() && $self->{url} =~ m{^https?://bosh\.io/d/(.+)\?v=}) {
		return "https://$1";
	}
	
	# For compiled releases, URL mapping will be handled by UpstreamConfiguration
	return $self->{url};
}

# Check if this reference matches another (for deduplication)
sub matches_reference {
	my ($self, $other) = @_;
	
	return $self->{name} eq $other->{name} &&
	       $self->{version} eq $other->{version} &&
	       $self->{url} eq $other->{url} &&
	       $self->{source_file} eq $other->{source_file};
}

# Private method to determine if URL indicates compiled release
sub _determine_if_compiled {
	my ($self, $url) = @_;
	
	return 1 if $url =~ m{^https?://s3(-.*)?.amazonaws\.com};
	return 1 if $url =~ m{^https?://storage\.googleapis\.com};
	return 1 if $url =~ m{compiled-release-tarballs};
	
	return 0;
}

1;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu