package Genesis::CI::KitVersion;

use v5.20;
use warnings;

use Genesis qw(run load_yaml slurp workdir lines info warning mkfile_or_fail pretty_duration);
use Genesis::CI::BoshRelease;
use Genesis::CI::BoshReleaseReference;
use Genesis::CI::UpstreamConfiguration;

=head1 NAME

Genesis::CI::KitVersion - Complete set of BOSH releases for one kit version

=head1 DESCRIPTION

Represents all BOSH releases found in a specific kit version. Handles parsing
of kit files (both spruce merge files and patch files) and provides methods
for filtering, comparison, and reporting.

=head1 SYNOPSIS

  # Unified constructor - automatically detects target type
  my $kit1 = Genesis::CI::KitVersion->new('/path/to/kit');        # Local path
  my $kit2 = Genesis::CI::KitVersion->new('bosh/4.0.1');         # Remote version (or cached)
  my $kit3 = Genesis::CI::KitVersion->new('/path/to/kit.tar.gz'); # Tarball

  # Or use factory methods (convenience wrappers)
  my $kit = Genesis::CI::KitVersion->from_path('/path/to/kit');
  my $kit = Genesis::CI::KitVersion->from_remote_version('bosh', '4.0.1');
  my $kit = Genesis::CI::KitVersion->from_kit_object($genesis_kit);

  $kit->load_releases();  # Parse all kit files

  my $release = $kit->get_release('backup-and-restore-sdk');
  my @all_releases = $kit->get_all_releases();

  $kit->apply_filter(['backup-and-restore-sdk', 'os-conf']);
  my $summary = $kit->get_release_summary();

  say "Kit type: " . $kit->kit_type();  # 'dev', 'compiled', 'local'

=cut
# Initialize Genesis Config (needed for remote kit access)
unless ($Genesis::RC) {
	require Genesis::Config;
	$Genesis::RC //= Genesis::Config->new($ENV{HOME}."/.genesis/config");
	Genesis::validate_global_config($Genesis::RC);
}


# Constructor
sub new {
	my ($class, $target) = @_;

	die "No target provided to KitVersion constructor" unless defined $target;

	my $orig_target = $target;  # Keep original for metadata
	my ($kit_type, $local_path, $kit_object, $source);

	if (ref($target) && ref($target) =~ m/^Genesis::Kit::/) {
		# If target is already a Genesis::Kit object, use it directly
		$kit_object = $target;
		$local_path = undef;
		$kit_type = $kit_object->is_dev ? 'dev' : 'compiled';
		$source = 'existing-kit-object';

	} else {

		# If target is a semver string, get from local cache or remote
		if ($target =~ m{^[^/]+/v?\d+\.\d+\.\d+}) {
			my ($kit_name, $version) = split('/', $target, 2);
			$version =~ s/^v//;  # Remove v prefix if present

			if( my $cached_kit = $class->_find_cached_kit($kit_name, $version)) {
				# Check for cached kit first
				$source = 'cached';
				$target = $cached_kit;  # Use cached tarball
			} else {
				# Download from remote to temp dir
				$source = 'remote';
				$target = $class->_download_kit($kit_name, $version);
			}
			$kit_type = 'compiled';
		}

		# If target is a path, check if its a tarball
		if ($target =~ /\.t(ar\.)?gz$/ && -f $target) {
			$local_path = $target;
			$source //= 'local-tarfile';
			$kit_type //= 'compiled';

		# else check if its a directory
		} elsif (-d $target) {
			# Check if its a dev kit (inside genesis repo) or full kit repo
			if (-f "$target/../.genesis/config") {
				$source = 'repo-dev';
				$kit_type = 'dev';
			} elsif (-f "$target/kit.yml") {
				$source = 'local-kit-repo';
				$kit_type = 'dev';
			} else {
				die "Path '$target' does not appear to be a valid kit directory";
			}
			$local_path = $target;
		} else {
			die "Invalid target '$target' - must be version string, tarball path, or directory path";
		}

		# Make a new Genesis::Kit object from $local_path
		$kit_object = $class->_create_kit_object($local_path, $kit_type);
	}

	# Build Genesis::CI::KitVersion object with metadata and kit object
	return bless {
		kit_id => $kit_object->id,
		kit_path => $kit_object->path,
		kit_type => $kit_type,
		kit_object => $kit_object,
		kit_origin => $source,  # 'dev', 'local-tarfile', 'cached', 'remote', 'existing-kit-object', etc
		kit_source => ref($orig_target) =~ m/^Genesis::Kit::/ ? 'existing-kit-object' : $orig_target,
		releases => {},           # name => BoshRelease
		upstream_config => undef, # Will be loaded if needed
		_loaded => 0,            # Track if releases have been loaded
	}, $class;
}

# Convenience factory methods (now just wrappers around new())
sub from_path {
	my ($class, $path) = @_;
	return $class->new($path);
}

# Class method to build from a remote kit version
sub from_remote_version {
	my ($class, $kit_name, $version) = @_;
	return $class->new("$kit_name/$version");
}

# Class method to build from an existing Genesis::Kit object
sub from_kit_object {
	my ($class, $kit) = @_;
	return $class->new($kit->path);
}

# Public accessors
sub kit_id { $_[0]->{kit_id} }
sub kit_source { $_[0]->{kit_source} }
sub kit_path { $_[0]->{kit_path} }
sub kit_type { $_[0]->{kit_type} }
sub kit_origin { $_[0]->{kit_origin} } # 'dev', 'local-tarfile', 'cached', 'remote', etc
sub kit { $_[0]->{kit_object} }

# Kit type helpers
sub is_dev_kit { $_[0]->{kit_origin} eq 'repo-dev' }
sub is_compiled_kit { $_[0]->{kit_type} eq 'compiled' }
sub is_local_kit { $_[0]->{kit_origin} eq 'local-kit-repo' }
sub is_remote_kit { $_[0]->{kit_origin} eq 'remote' || $_[0]->{kit_origin} eq 'cached' }

# Load all releases from kit files
sub load_releases {
	my ($self) = @_;

	return if $self->{_loaded};  # Don't load twice

	$self->_load_spruce_files();
	$self->_load_patch_files();

	$self->{_loaded} = 1;
	return $self;
}

# Add a release reference
sub add_release_reference {
	my ($self, $name, $version, %ref_args) = @_;

	# Create BoshReleaseReference
	my $ref = Genesis::CI::BoshReleaseReference->new(
		name => $name,
		version => $version,
		%ref_args
	);

	# Create release object if it doesn't exist
	if (!exists $self->{releases}{$name}) {
		$self->{releases}{$name} = Genesis::CI::BoshRelease->new($name);
	}

	# Add reference to the release
	$self->{releases}{$name}->add_reference($ref);

	return $self;
}

# Get a specific release
sub get_release {
	my ($self, $name) = @_;
	return $self->{releases}{$name};
}

# Get all releases
sub get_all_releases {
	my ($self) = @_;
	return values %{$self->{releases}};
}

# Get release names
sub get_release_names {
	my ($self) = @_;
	return keys %{$self->{releases}};
}

# Apply filter to limit releases
sub apply_filter {
	my ($self, $filter_patterns) = @_;

	return $self unless $filter_patterns && @$filter_patterns;

	# Convert patterns to regex and filter releases
	my @keep_names;

	for my $pattern (@$filter_patterns) {
		# Simple pattern matching - could be enhanced
		if ($pattern =~ m{^([^/]+)(?:/|$)}) {
			my $release_name = $1;
			push @keep_names, $release_name if exists $self->{releases}{$release_name};
		}
	}

	# Keep only matching releases
	my %filtered_releases = map { $_ => $self->{releases}{$_} } @keep_names;
	$self->{releases} = \%filtered_releases;

	return $self;
}

# Get release summary for display
sub get_release_summary {
	my ($self) = @_;

	my %summary = (
		total_releases => scalar(keys %{$self->{releases}}),
		releases_with_variants => 0,
		releases_with_source_and_compiled => 0,
		total_versions => 0
	);

	for my $release (values %{$self->{releases}}) {
		$summary{total_versions} += $release->version_count();
		$summary{releases_with_variants}++ if $release->has_multiple_variants();
		$summary{releases_with_source_and_compiled}++ if $release->has_source_and_compiled_variants();
	}

	return \%summary;
}

# Get releases that have multiple variants
sub get_releases_with_variants {
	my ($self) = @_;

	return grep { $_->has_source_and_compiled_variants() } values %{$self->{releases}};
}

# Check if kit has any duplicate versions (for reporting)
sub has_duplicate_versions {
	my ($self) = @_;

	for my $release (values %{$self->{releases}}) {
		return 1 if $release->version_count() > 1;
	}

	return 0;
}

# Get upstream configuration (lazy loaded)
sub upstream_config {
	my ($self) = @_;
	
	return $self->{upstream_config} //= Genesis::CI::UpstreamConfiguration->new(
		kit => $self->{kit_object}
	);
}

# Get source repository URL for a release with fallback validation
sub get_source_repository_url {
	my ($self, $release_name, $release_version, $fallback_upstream_config) = @_;
	
	return $self->upstream_config()->get_repository_url($release_name, $release_version, $fallback_upstream_config);
}

# Get source URL for a given release version
sub get_source_url {
	my ($self, $release_name, $version) = @_;
	
	my $release = $self->get_release($release_name);
	return undef unless $release;
	
	return $release->get_source_url($version);
}

# Create a comparison with another kit version
sub compare_with {
	my ($self, $other_kit) = @_;

	require Genesis::CI::KitVersionComparison;
	return Genesis::CI::KitVersionComparison->new($self, $other_kit);
}

### Private Class Methods ###

sub _find_cached_kit {
	my ($class, $kit_name, $version) = @_;

	my $kits_path = $Genesis::RC->get('kits_path');
	return unless $kits_path && -d $kits_path;

	# Look for kit-name-version.tgz or kit-name-version.tar.gz
	for my $ext ('tgz', 'tar.gz') {
		my $cached_file = "$kits_path/$kit_name-$version.$ext";
		return $cached_file if -f $cached_file;
	}

	return;
}

sub _download_kit {
	my ($class, $kit_name, $version) = @_;

	require Genesis::Top;

	# Create meaningful temp directory for downloaded kit
	my $temp_dir = workdir("download-$kit_name-$version");

	# Use Genesis kit provider to fetch the kit
	my $top = Genesis::Top->new('.');
	my $kit_provider = $top->kit_provider;

	my ($_name, $_version, $file) = $kit_provider->fetch_kit_version(
		$kit_name,
		$version,
		$temp_dir,
		1  # force download
	) or die "Failed to download Genesis Kit $kit_name/$version";

	return $file;
}


sub _create_kit_object {
	my ($class, $local_path, $kit_type) = @_;

	if ($kit_type eq 'dev') { # This includes 'local kit repos'
		require Genesis::Kit::Dev;
		return Genesis::Kit::Dev->new($local_path);
	} elsif ($kit_type eq 'compiled') {
		require Genesis::Kit::Compiled;
		return Genesis::Kit::Compiled->new(archive => $local_path);
	}
	die "Unknown kit type '$kit_type' for path '$local_path'";
}

### Private Instance Methods ###

# Private method to load releases from spruce merge files
sub _load_spruce_files {
	my ($self) = @_;

	my $kit_path = $self->{kit_path};

	# Find all YAML files that contain releases (excluding .git and spec directories)
	my @spruce_files = grep {
		$_ !~ m{/(.git|spec)/} && /\.yml$/
	} lines(run('grep', '-rl', '^releases', $kit_path));

	for my $file (@spruce_files) {
		$self->_process_spruce_file($file);
	}
}

# Private method to load releases from patch files
sub _load_patch_files {
	my ($self) = @_;

	my $kit_path = $self->{kit_path};

	# Find all YAML files that contain release patches
	my @patch_files = grep {
		$_ !~ m{/.git/} && /\.yml$/
	} lines(run('grep', '-rl', 'path:\s\+/releases', $kit_path));

	for my $file (@patch_files) {
		$self->_process_patch_file($file);
	}
}

# Private method to process a spruce merge file
sub _process_spruce_file {
	my ($self, $file) = @_;

	my ($out, $rc, $err) = run(
		'spruce', 'merge', '--skip-eval', '-m', '--go-patch', '--cherry-pick', 'releases', $file
	);

	if ($rc == 0 && $out =~ /\(\( concat/) {
		# Need to spruce merge the releases block
		$out = run('spruce', 'merge', $out);
	}

	my $yaml = load_yaml($out, $rc, $err);
	my $releases = $yaml->{releases} || [];

	my $source_file = $file =~ s{^$self->{kit_path}/}{}r;

	for my $release (@$releases) {
		next unless $release->{name} && $release->{version};

		$self->add_release_reference(
			$release->{name},
			$release->{version},
			source_file => $source_file,
			url => $release->{url},
			sha1 => $release->{sha1},
			context => { type => 'spruce' },
			metadata => $release
		);
	}
}

# Private method to process a patch file
sub _process_patch_file {
	my ($self, $file) = @_;

	my $patch_data = slurp($file);
	my $source_file = $file =~ s{^$self->{kit_path}/}{}r;

	for my $block (split(/---/, $patch_data)) {
		$block =~ s{\A\s+}{}; # remove leading whitespace
		next unless $block =~ m{^ *- }; # skip non patch blocks

		my $yaml_content = "data:\n$block";
		my $yaml = load_yaml($yaml_content);
		my $patches = $yaml->{data} || [];

		for my $patch (@$patches) {
			next unless $patch->{path} && $patch->{path} =~ m{^/releases\??/} && $patch->{type} eq 'replace';

			if (ref($patch->{value}) eq 'HASH' && $patch->{value}{name} && $patch->{value}{version}) {
				my $release = $patch->{value};

				$self->add_release_reference(
					$release->{name},
					$release->{version},
					source_file => $source_file,
					url => $release->{url},
					sha1 => $release->{sha1},
					context => { type => 'patch', path => $patch->{path} },
					metadata => $release
				);
			}
		}
	}
}

1;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
