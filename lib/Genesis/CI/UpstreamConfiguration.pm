package Genesis::CI::UpstreamConfiguration;

use v5.20;
use warnings;

use Genesis qw(load_yaml_file bail curl);
use Service::Github;

=head1 NAME

Genesis::CI::UpstreamConfiguration - Repository mapping and URL resolution for CI

=head1 DESCRIPTION

Manages upstream repository configuration for CI operations, including mapping
compiled release URLs back to their source repositories and handling GitHub
API integration for release metadata and job spec fetching.

=head1 SYNOPSIS

  my $config = Genesis::CI::UpstreamConfiguration->new(
    kit_path => '/path/to/kit',
    github_token => $token  # optional
  );

  $config->load_configuration();

  my $repo_url = $config->get_repository_url('backup-and-restore-sdk');
  my $default_branch = $config->get_default_branch('cloudfoundry/backup-and-restore-sdk-release');

  my @job_specs = $config->fetch_job_specs($release_ref);

=cut

# Constructor
sub new {
	my ($class, %args) = @_;

	bail(
		"Kit is required to initialize UpstreamConfiguration"
	) unless $args{kit};

	my $kit = $args{kit};
	my $config_data = $class->_resolve_ci_configuration($kit);

	return bless {
		kit => $kit,
		config_source => $config_data->{source},
		settings => $config_data->{settings} || {},
		upstream_repos => $config_data->{upstream_repos} || {},
		repo_cache => {},
		branch_cache => {},
		reachability_cache => {},  # Cache for repository reachability checks
	}, $class;
}

# Public accessors
sub kit_path { shift->{kit}->path(@_) }

# Get repository URL for a release name with proper precedence
sub get_repository_url {
	my ($self, $release_name, $release_version, $fallback_upstream_config) = @_;

	# Check cache first
	my $cache_key = "${release_name}:${release_version}";
	return $self->{repo_cache}{$cache_key} if exists $self->{repo_cache}{$cache_key};

	my $repo_url = $self->_resolve_repository_url_with_precedence(
		$release_name, $release_version, $fallback_upstream_config
	);

	# Cache the result
	$self->{repo_cache}{$cache_key} = $repo_url;
	return $repo_url;
}

# Get default branch for a repository
sub get_default_branch {
	my ($self, $repo_url) = @_;

	# Extract owner/repo from URL
	my ($owner, $repo) = $self->_parse_github_url($repo_url);
	return 'main' unless $owner && $repo;  # fallback

	my $cache_key = "$owner/$repo";

	# Check cache first
	return $self->{branch_cache}{$cache_key} if exists $self->{branch_cache}{$cache_key};

	# Try to detect via GitHub API if token available
	if ($self->{github_token}) {
		my $branch = $self->_fetch_default_branch_from_api($owner, $repo);
		if ($branch) {
			$self->{branch_cache}{$cache_key} = $branch;
			return $branch;
		}
	}

	# Fallback to common defaults
	my $fallback = $self->_guess_default_branch($owner, $repo);
	$self->{branch_cache}{$cache_key} = $fallback;
	return $fallback;
}

# Fetch job specs for a release reference
sub fetch_job_specs {
	my ($self, $release_ref) = @_;

	my $repo_url = $self->get_repository_url($release_ref->name());
	return [] unless $repo_url;

	my $branch = $self->get_default_branch($repo_url);
	my $version = $release_ref->version();

	# Try version tag first, then branch
	my @candidates = ("v$version", $version, $branch);

	for my $ref (@candidates) {
		my $jobs_data = $self->_fetch_jobs_from_github($repo_url, $ref);
		return $jobs_data if $jobs_data && @$jobs_data;
	}

	return [];
}

# Check if URL is a compiled release
sub is_compiled_url {
	my ($self, $url) = @_;

	return 1 if $url =~ m{^https?://s3(-.*)?.amazonaws\.com};
	return 1 if $url =~ m{^https?://storage\.googleapis\.com};
	return 1 if $url =~ m{compiled-release-tarballs};

	return 0;
}

# Map compiled URL back to source repository if possible
sub resolve_source_repository {
	my ($self, $compiled_url) = @_;

	# For S3 URLs, try to extract release name and map via upstream config
	if ($compiled_url =~ m{/([^/]+)-(\d+(?:\.\d+)*(?:\+\w+)?)-[^-]+-\d+-[a-f0-9]+-\d+\.tgz$}) {
		my $release_name = $1;
		return $self->get_repository_url($release_name);
	}

	# Additional pattern matching for other compiled URL formats
	if ($compiled_url =~ m{/releases/download/[^/]+/([^/-]+)-}) {
		my $release_name = $1;
		return $self->get_repository_url($release_name);
	}

	return undef;
}

# Private method to resolve CI configuration from multiple sources
sub _resolve_ci_configuration {
	my ($class, $kit) = @_;
	
	# Try local CI directory first
	if (my $config = $class->_try_local_ci_config($kit)) {
		return { source => 'local', %$config };
	}
	
	# Try fetching from provider for official releases
	# Check if this is a compiled kit with a version pattern
	if (ref($kit) =~ /Genesis::Kit::Compiled/ && $kit->id =~ /^[^\/]+\/\d+\.\d+\.\d+$/) {
		if (my $config = $class->_try_provider_ci_config($kit)) {
			return { source => 'provider', %$config };
		}
	}
	
	# Fall back to empty configuration - rely on precedence logic for URL resolution
	return { 
		source => 'no-config', 
		settings => {},
		upstream_repos => {}
	};
}

# Try to load CI configuration from local kit directory
sub _try_local_ci_config {
	my ($class, $kit) = @_;
	
	my $settings_file = $kit->path('ci/settings.yml');
	my $upstream_file = $kit->path('ci/upstreamrepo.yml');
	
	return unless -f $settings_file || -f $upstream_file;
	
	my $settings = {};
	my $upstream_repos = {};
	
	if (-f $settings_file) {
		eval {
			$settings = load_yaml_file($settings_file);
		};
		warn "Warning: Could not load ci/settings.yml: $@" if $@;
	}
	
	if (-f $upstream_file) {
		eval {
			$upstream_repos = load_yaml_file($upstream_file);
		};
		warn "Warning: Could not load ci/upstreamrepo.yml: $@" if $@;
	}
	
	# Extract upstream repository mappings from settings if available
	if ($settings->{meta} && $settings->{meta}{upstream} && $settings->{meta}{upstream}{bosh_releases}) {
		for my $release (@{$settings->{meta}{upstream}{bosh_releases}}) {
			next unless $release->{name} && $release->{repository};
			my $repo_url = $release->{repository} =~ /^https?:\/\// 
				? $release->{repository}
				: "https://github.com/$release->{repository}";
			$upstream_repos->{$release->{name}} = $repo_url;
		}
	}
	
	return {
		settings => $settings,
		upstream_repos => $upstream_repos
	};
}

# Try to fetch CI configuration from kit provider
sub _try_provider_ci_config {
	my ($class, $kit) = @_;
	
	# TODO: Implement provider-based CI config fetching
	# This would involve:
	# 1. Getting the kit's provider
	# 2. Fetching the tagged version of the kit
	# 3. Extracting CI configuration from that version
	# 4. Cleaning up temporary files
	
	return undef; # Not implemented yet
}

# Resolve repository URL following proper precedence order
sub _resolve_repository_url_with_precedence {
	my ($self, $release_name, $release_version, $fallback_upstream_config) = @_;
	
	# 1. Check for cached spec file for this release/version
	if (my $url = $self->_check_spec_cache_for_repository($release_name, $release_version)) {
		return $url;
	}
	
	# 2. Check my CI directory if I have one
	if (my $url = $self->_get_repository_url_from_config($release_name)) {
		return $url;
	}
	
	# 3. Check other kit's CI directory if it has one
	if ($fallback_upstream_config) {
		if (my $url = $fallback_upstream_config->_get_repository_url_from_config($release_name)) {
			return $url;
		}
	}
	
	# 4. Try source download URL common translations
	if (my $url = $self->_translate_from_source_download_url($release_name, $release_version)) {
		return $url;
	}
	
	# 5. Download my tagged release if I'm a versioned compiled release
	if (my $url = $self->_fetch_from_tagged_release($release_name)) {
		return $url;
	}
	
	# Final fallback - construct standard GitHub URL
	return "https://github.com/cloudfoundry/$release_name-release";
}

# Get repository URL from this configuration
sub _get_repository_url_from_config {
	my ($self, $release_name) = @_;

	# Check upstream repo mapping
	if ($self->{upstream_repos} && $self->{upstream_repos}{$release_name}) {
		return $self->{upstream_repos}{$release_name};
	}

	return undef; # No mapping found in this config
}

# Validate that a repository URL is reachable
sub _validate_repository_reachable {
	my ($self, $repo_url) = @_;
	
	# Check cache first
	return $self->{reachability_cache}{$repo_url} 
		if exists $self->{reachability_cache}{$repo_url};
	
	# Quick HEAD request to check reachability
	my ($code, $msg) = curl("HEAD", $repo_url, undef, undef, 5); # 5 second timeout
	my $reachable = ($code == 200 || $code == 301 || $code == 302);
	
	# Cache result
	$self->{reachability_cache}{$repo_url} = $reachable;
	
	return $reachable;
}

# Check spec cache directory for existing job spec files that indicate repository
sub _check_spec_cache_for_repository {
	my ($self, $release_name, $release_version) = @_;
	
	# Get spec cache directory from Genesis config
	require Genesis;
	my $spec_cache_dir = $Genesis::RC->get('spec_cache_dir') // Genesis::workdir('job-specs-cache');
	return undef unless -d $spec_cache_dir;
	
	# Look for cached job spec files that contain repository URL
	my $cache_pattern = "${spec_cache_dir}/*--*--${release_name}-${release_version}.json";
	my @cache_files = glob($cache_pattern);
	
	for my $cache_file (@cache_files) {
		# Extract owner/repo from cache filename: owner--repo--release-version.json
		if (basename($cache_file) =~ /^([^-]+)--([^-]+)--\Q$release_name\E-\Q$release_version\E\.json$/) {
			my ($owner, $repo) = ($1, $2);
			return "https://github.com/$owner/$repo";
		}
	}
	
	return undef;
}

# Translate from source download URL to repository URL
sub _translate_from_source_download_url {
	my ($self, $release_name, $release_version) = @_;
	
	# Skip this precedence step for now - would need kit version integration
	# to access the source URLs from release references
	return undef;
}

# Fetch repository URL from tagged release (for versioned compiled kits)
sub _fetch_from_tagged_release {
	my ($self, $release_name) = @_;
	
	# Only try this for compiled kits with version tags
	my $kit = $self->{kit};
	return undef unless ref($kit) =~ /Genesis::Kit::Compiled/;
	return undef unless $kit->id =~ /^([^\/]+)\/(\d+\.\d+\.\d+)$/;
	
	my ($kit_name, $version) = ($1, $2);
	
	# TODO: Implement fetching CI config from tagged release
	# This would involve:
	# 1. Use kit provider to fetch the tagged source
	# 2. Extract ci/settings.yml from the source
	# 3. Parse upstream repository mappings
	# 4. Return the mapping for the requested release
	
	return undef; # Not implemented yet
}

# Private method to load ci/settings.yml
sub _load_settings {
	my ($self) = @_;

	my $settings_file = "$self->{kit_path}/ci/settings.yml";
	return unless -f $settings_file;

	eval {
		$self->{settings} = load_yaml(slurp($settings_file));
	};

	if ($@) {
		warn "Warning: Could not load ci/settings.yml: $@";
		$self->{settings} = {};
	}
}

# Private method to load ci/upstreamrepo.yml
sub _load_upstream_repos {
	my ($self) = @_;

	my $upstream_file = "$self->{kit_path}/ci/upstreamrepo.yml";
	return unless -f $upstream_file;

	eval {
		$self->{upstream_repos} = load_yaml(slurp($upstream_file));
	};

	if ($@) {
		warn "Warning: Could not load ci/upstreamrepo.yml: $@";
		$self->{upstream_repos} = {};
	}
}

# Private method to parse GitHub URL into owner/repo
sub _parse_github_url {
	my ($self, $url) = @_;

	if ($url =~ m{^https?://github\.com/([^/]+)/([^/]+?)(?:\.git|/|$)}) {
		return ($1, $2);
	}

	return (undef, undef);
}

# Private method to fetch default branch via GitHub API
sub _fetch_default_branch_from_api {
	my ($self, $owner, $repo) = @_;

	return undef unless $self->{github_token};

	# Use Service::Github for consistent API URL construction
	my $github = Service::Github->new(domain => 'github.com');
	my $api_url = $github->base_url . "/repos/$owner/$repo";

	my ($code, $msg, $data) = curl("GET", $api_url, undef, undef, 0, "Bearer $self->{github_token}");
	return undef if $code != 200;

	eval {
		my $repo_data = load_yaml($data);
		return $repo_data->{default_branch} if $repo_data && $repo_data->{default_branch};
	};

	return undef;
}

# Private method to guess default branch based on common patterns
sub _guess_default_branch {
	my ($self, $owner, $repo) = @_;

	# CF repos often use 'develop'
	return 'develop' if $owner eq 'cloudfoundry';

	# Most newer repos use 'main'
	return 'main';
}

# Private method to fetch jobs from GitHub repository
sub _fetch_jobs_from_github {
	my ($self, $repo_url, $ref) = @_;

	my ($owner, $repo) = $self->_parse_github_url($repo_url);
	return undef unless $owner && $repo;

	# Use Service::Github for consistent API URL construction
	my $github = Service::Github->new(domain => 'github.com');
	my $api_url = $github->base_url . "/repos/$owner/$repo/contents/jobs";
	$api_url .= "?ref=$ref" if $ref ne 'main';

	my $creds = $self->{github_token} ? "Bearer $self->{github_token}" : undef;
	my ($code, $msg, $data) = curl("GET", $api_url, undef, undef, 0, $creds);
	return undef if $code != 200;

	my $jobs_data;
	eval {
		$jobs_data = load_yaml($data);
	};
	return undef if $@ || !$jobs_data;

	# Filter for job directories and fetch spec files
	my @job_specs;
	for my $item (@$jobs_data) {
		next unless $item->{type} eq 'dir';

		my $spec_data = $self->_fetch_job_spec($owner, $repo, $ref, $item->{name});
		push @job_specs, $spec_data if $spec_data;
	}

	return \@job_specs;
}

# Private method to fetch individual job spec
sub _fetch_job_spec {
	my ($self, $owner, $repo, $ref, $job_name) = @_;

	# Use Service::Github for consistent API URL construction
	my $github = Service::Github->new(domain => 'github.com');
	my $spec_url = $github->base_url . "/repos/$owner/$repo/contents/jobs/$job_name/spec";
	$spec_url .= "?ref=$ref" if $ref ne 'main';

	my $creds = $self->{github_token} ? "Bearer $self->{github_token}" : undef;
	my ($code, $msg, $data) = curl("GET", $spec_url, undef, undef, 0, $creds);
	return undef if $code != 200;

	my $spec_info;
	eval {
		$spec_info = load_yaml($data);
	};
	return undef if $@ || !$spec_info || $spec_info->{type} ne 'file';

	# Decode base64 content
	require MIME::Base64;
	my $spec_content = MIME::Base64::decode_base64($spec_info->{content});

	my $spec_data;
	eval {
		$spec_data = load_yaml($spec_content);
	};
	return undef if $@ || !$spec_data;

	return {
		job => $job_name,
		spec => $spec_data
	};
}

1;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
