package Genesis::CI::KitVersionComparison;

use v5.20;
use warnings;

use Genesis qw(info warning pretty_duration);
use Genesis::Term qw(csprintf);
use Genesis::CI::UpstreamConfiguration;
use Time::HiRes qw(gettimeofday);

=head1 NAME

Genesis::CI::KitVersionComparison - Comparison results and operations between two kit versions

=head1 DESCRIPTION

Represents the comparison between two KitVersion objects. Holds the comparison
results and provides methods for job spec fetching, reporting, and analysis.
This separates comparison logic from the individual kit objects.

=head1 SYNOPSIS

  my $comparison = Genesis::CI::KitVersionComparison->new($new_kit, $old_kit);

  # Access comparison results
  my @added = $comparison->get_added_releases();
  my @changed = $comparison->get_changed_releases();

  # Fetch job specs for changed releases
  $comparison->fetch_job_specs();

  # Generate reports
  $comparison->report_summary();
  $comparison->report_job_spec_changes();

=cut

# Constructor
sub new {
	my ($class, $new_kit, $old_kit) = @_;

	die "New kit is required" unless $new_kit;
	die "Old kit is required" unless $old_kit;

	my $self = bless {
		new_kit => $new_kit,
		old_kit => $old_kit,
		results => undef,      # Will hold comparison results
		job_specs => undef,    # Will hold fetched job specs
		_compared => 0,        # Track if comparison has been done
	}, $class;

	# Perform comparison immediately
	$self->_perform_comparison();

	return $self;
}

# Public accessors
sub new_kit { $_[0]->{new_kit} }
sub old_kit { $_[0]->{old_kit} }
sub results { $_[0]->{results} }
sub job_specs { $_[0]->{job_specs} }

# Get releases by category
sub get_added_releases {
	my ($self) = @_;
	return keys %{$self->{results}{added}};
}

sub get_removed_releases {
	my ($self) = @_;
	return keys %{$self->{results}{removed}};
}

sub get_changed_releases {
	my ($self) = @_;
	return keys %{$self->{results}{changed}};
}

sub get_unchanged_releases {
	my ($self) = @_;
	return keys %{$self->{results}{unchanged}};
}

# Get releases that need job spec comparison
sub get_releases_needing_job_specs {
	my ($self) = @_;

	my @releases_needing_specs;

	for my $name (keys %{$self->{results}{changed}}) {
		my $change_info = $self->{results}{changed}{$name};

		push @releases_needing_specs, {
			name => $name,
			old_version => $change_info->{old_latest},
			new_version => $change_info->{new_latest},
			old_release_obj => $change_info->{old_release_obj},
			new_release_obj => $change_info->{new_release_obj}
		};
	}

	return @releases_needing_specs;
}

# Fetch job specs for changed releases
sub fetch_job_specs {
	my ($self) = @_;

	my @releases_needing_specs = $self->get_releases_needing_job_specs();
	return {} unless @releases_needing_specs; # No changes, no specs needed

	# Get spec cache directory from Genesis config
	require Genesis;
	my $spec_cache_dir = $Genesis::RC->get('spec_cache_dir') // Genesis::workdir('job-specs-cache');
	Genesis::mkdir_or_fail($spec_cache_dir) unless -d $spec_cache_dir;

	# Use kit-specific upstream configurations with cross-kit fallback
	my %spec_files;

	for my $release_info (@releases_needing_specs) {
		my $name = $release_info->{name};
		my $old_version = $release_info->{old_version};
		my $new_version = $release_info->{new_version};

		info("Fetching job specs for #M{%s}: #R{v%s} → #G{v%s}", $name, $old_version, $new_version);

		# Each kit resolves its own repository URL with cross-kit fallback
		my $new_repo_url = $self->{new_kit}->get_source_repository_url($name, $new_version, $self->{old_kit}->upstream_config);
		my $old_repo_url = $self->{old_kit}->get_source_repository_url($name, $old_version, $self->{new_kit}->upstream_config);

		# Use newer kit's URL as primary, old kit's as fallback
		my $repo_url = $new_repo_url || $old_repo_url;
		unless ($repo_url) {
			warning("Cannot determine repository URL for release #C{%s} - skipping job spec comparison", $name);
			next;
		}

		# Note if repositories differ (indicates repo migration)
		if ($new_repo_url && $old_repo_url && $new_repo_url ne $old_repo_url) {
			warning("Repository URL changed for #C{%s}: #y{%s} → #g{%s}", $name, $old_repo_url, $new_repo_url);
		}

		# Fetch job specs for both versions
		$spec_files{$name} = {};

		# Fetch old version specs using old kit's repository URL
		my $old_specs = $self->_fetch_version_job_specs($name, $old_version, $old_repo_url || $repo_url, $spec_cache_dir, $self->{old_kit}->upstream_config);
		$spec_files{$name}{$old_version} = {
			jobs => $old_specs || {},
			errors => $old_specs ? [] : ["Failed to fetch job specs for $name v$old_version"]
		};

		# Fetch new version specs using new kit's repository URL
		my $new_specs = $self->_fetch_version_job_specs($name, $new_version, $new_repo_url || $repo_url, $spec_cache_dir, $self->{new_kit}->upstream_config);
		$spec_files{$name}{$new_version} = {
			jobs => $new_specs || {},
			errors => $new_specs ? [] : ["Failed to fetch job specs for $name v$new_version"]
		};
	}

	$self->{job_specs} = \%spec_files;
	return \%spec_files;
}

# Check if comparison has job spec changes to report
sub has_job_spec_changes {
	my ($self) = @_;
	return $self->{job_specs} && keys %{$self->{job_specs}};
}

# Generate summary statistics
sub get_summary {
	my ($self) = @_;

	return {
		added_count => scalar($self->get_added_releases()),
		removed_count => scalar($self->get_removed_releases()),
		changed_count => scalar($self->get_changed_releases()),
		unchanged_count => scalar($self->get_unchanged_releases()),
		job_specs_fetched => $self->has_job_spec_changes(),
		total_releases => scalar($self->get_added_releases()) +
		                 scalar($self->get_removed_releases()) +
		                 scalar($self->get_changed_releases()) +
		                 scalar($self->get_unchanged_releases())
	};
}

# Report comparison summary
sub report_summary {
	my ($self) = @_;
	
	my $summary = $self->get_summary();
	
	print csprintf("\n#Yu{=== COMPARISON RESULTS ===}\n");
	print csprintf("Comparing #M{%s} vs #M{%s}\n\n", $self->{new_kit}->kit_id, $self->{old_kit}->kit_id);
	
	if ($summary->{total_releases} == 0) {
		print csprintf("#y{No releases found in either kit}\n");
		return;
	}
	
	# Summary statistics
	print csprintf("Summary: #G{%d total}, #g{%d added}, #R{%d removed}, #Y{%d changed}, #c{%d unchanged}\n\n",
		$summary->{total_releases}, $summary->{added_count}, $summary->{removed_count},
		$summary->{changed_count}, $summary->{unchanged_count}
	);
	
	$self->_report_added_releases();
	$self->_report_removed_releases();
	$self->_report_changed_releases();
	$self->_report_unchanged_releases();
}

# Report job spec comparison results
sub report_job_spec_changes {
	my ($self) = @_;
	
	unless ($self->has_job_spec_changes()) {
		print csprintf("#g{No job spec changes to report}\n");
		return;
	}
	
	print csprintf("\n#Yu{=== JOB SPEC FETCH RESULTS ===}\n");
	
	my $spec_files = $self->{job_specs};
	for my $name (sort keys %$spec_files) {
		print csprintf("\n#M{$name}:\n");
		
		my $release_specs = $spec_files->{$name};
		for my $version (sort keys %$release_specs) {
			my $version_info = $release_specs->{$version};
			my @jobs = keys %{$version_info->{jobs} || {}};
			my @errors = @{$version_info->{errors} || []};
			
			if (@errors) {
				print csprintf("  #R{v$version}: FAILED - " . join(', ', @errors) . "\n");
			} elsif (@jobs) {
				print csprintf("  #G{v$version}: " . scalar(@jobs) . " job specs - " . join(', ', map {"#c{$_}"} sort @jobs) . "\n");
			} else {
				print csprintf("  #Y{v$version}: No job specs found\n");
			}
		}
	}
}

# Generate a complete report including summary and job specs
sub report_complete {
	my ($self) = @_;
	
	$self->report_summary();
	
	# Only report job specs if there are changes that need them
	my @releases_needing_specs = $self->get_releases_needing_job_specs();
	if (@releases_needing_specs) {
		print csprintf("\n#Mu{Releases Needing Job Spec Comparison:}\n");
		for my $release (@releases_needing_specs) {
			print csprintf("  - #m{" . $release->{name} . "}: #R{v" . $release->{old_version} . "} → #G{v" . $release->{new_version} . "}\n");
		}
		
		if ($self->has_job_spec_changes()) {
			$self->report_job_spec_changes();
		} else {
			print csprintf("\n#y{Job specs not yet fetched - call fetch_job_specs() first}\n");
		}
	} else {
		print csprintf("\n#g{No releases need job spec comparison (no version changes)}\n");
	}
}

# Private reporting helper methods
sub _report_added_releases {
	my ($self) = @_;
	
	my @added = $self->get_added_releases();
	return unless @added;
	
	print csprintf("#Gu{Added Releases:}\n");
	for my $name (sort @added) {
		my $info = $self->{results}{added}{$name};
		print csprintf("  - #c{$name}: #G{" . $info->{latest_version} . "}\n");
	}
	print "\n";
}

sub _report_removed_releases {
	my ($self) = @_;
	
	my @removed = $self->get_removed_releases();
	return unless @removed;
	
	print csprintf("#Ru{Removed Releases:}\n");
	for my $name (sort @removed) {
		my $info = $self->{results}{removed}{$name};
		print csprintf("  - #c{$name}: #R{" . $info->{latest_version} . "}\n");
	}
	print "\n";
}

sub _report_changed_releases {
	my ($self) = @_;
	
	my @changed = $self->get_changed_releases();
	return unless @changed;
	
	print csprintf("#yu{Changed Releases:}\n");
	for my $name (sort @changed) {
		my $info = $self->{results}{changed}{$name};
		print csprintf("  - #c{$name}: #R{" . $info->{old_latest} . "} → #G{" . $info->{new_latest} . "}\n");
		
		# Show additional version changes if multiple versions involved
		my @added_versions = @{$info->{added} || []};
		my @removed_versions = @{$info->{removed} || []};
		
		if (@added_versions > 1 || @removed_versions > 1) {
			if (@added_versions > 1) {
				print csprintf("    Added versions: " . join(', ', sort @added_versions) . "\n");
			}
			if (@removed_versions > 1) {
				print csprintf("    Removed versions: " . join(', ', sort @removed_versions) . "\n");
			}
		}
	}
	print "\n";
}

sub _report_unchanged_releases {
	my ($self) = @_;
	
	my @unchanged = $self->get_unchanged_releases();
	return unless @unchanged;
	
	print csprintf("#Gu{Unchanged Releases:} #y{(" . scalar(@unchanged) . " releases)}\n");
	
	# Show first few unchanged releases to avoid cluttering output
	my $show_count = 5;
	for my $name ((sort @unchanged)[0..min($show_count-1, $#unchanged)]) {
		my $info = $self->{results}{unchanged}{$name};
		print csprintf("  - #c{$name}: #g{" . $info->{latest_version} . "}\n");
	}
	
	if (@unchanged > $show_count) {
		print csprintf("  ... and #y{" . (@unchanged - $show_count) . "} more unchanged releases\n");
	}
	print "\n";
}

# Helper function for min
sub min {
	return $_[0] < $_[1] ? $_[0] : $_[1];
}

# Private method to perform the actual comparison
sub _perform_comparison {
	my ($self) = @_;

	return if $self->{_compared};

	# Ensure both kits are loaded
	$self->{new_kit}->load_releases() unless $self->{new_kit}{_loaded};
	$self->{old_kit}->load_releases() unless $self->{old_kit}{_loaded};

	my @new_release_names = $self->{new_kit}->get_release_names();
	my @old_release_names = $self->{old_kit}->get_release_names();

	# Use Genesis's compare_arrays function
	require Genesis;
	my ($added_names, $common_names, $removed_names) = Genesis::compare_arrays(\@new_release_names, \@old_release_names);

	my %results = (
		added => {},      # release_name => { versions => [...] }
		removed => {},    # release_name => { versions => [...] }
		changed => {},    # release_name => { old_latest => "1.0", new_latest => "1.1", ... }
		unchanged => {},  # release_name => { common_versions => [...] }
	);

	# Process added releases
	for my $name (@$added_names) {
		my $release = $self->{new_kit}->get_release($name);
		$results{added}{$name} = {
			versions => [$release->get_version_strings(1)], # descending
			latest_version => $release->get_latest_version_string(),
			release_obj => $release
		};
	}

	# Process removed releases
	for my $name (@$removed_names) {
		my $release = $self->{old_kit}->get_release($name);
		$results{removed}{$name} = {
			versions => [$release->get_version_strings(1)], # descending
			latest_version => $release->get_latest_version_string(),
			release_obj => $release
		};
	}

	# Process common releases - check for version changes
	for my $name (@$common_names) {
		my $new_release = $self->{new_kit}->get_release($name);
		my $old_release = $self->{old_kit}->get_release($name);

		my @new_versions = $new_release->get_version_strings(1); # descending
		my @old_versions = $old_release->get_version_strings(1); # descending

		my ($versions_added, $versions_common, $versions_removed) =
			Genesis::compare_arrays(\@new_versions, \@old_versions);

		# Check if latest versions are different (this determines changed vs unchanged)
		my $old_latest = $old_release->get_latest_version_string();
		my $new_latest = $new_release->get_latest_version_string();

		if ($old_latest ne $new_latest) {
			# Latest versions differ - this is a meaningful change
			$results{changed}{$name} = {
				old_latest => $old_latest,
				new_latest => $new_latest,
				added => $versions_added,
				removed => $versions_removed,
				common => $versions_common,
				old_release_obj => $old_release,
				new_release_obj => $new_release
			};
		} else {
			# Latest versions are the same - treat as unchanged
			$results{unchanged}{$name} = {
				common_versions => $versions_common,
				latest_version => $new_latest,
				old_release_obj => $old_release,
				new_release_obj => $new_release
			};
		}
	}

	$self->{results} = \%results;
	$self->{_compared} = 1;
}

# Private method to fetch job specs for a specific version
sub _fetch_version_job_specs {
	my ($self, $name, $version, $repo_url, $cache_dir, $upstream_config) = @_;

	# Parse GitHub URL
	my ($owner, $repo) = $repo_url =~ m{^https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$};
	unless ($owner && $repo) {
		warning("Invalid GitHub URL for release #C{%s}: %s", $name, $repo_url);
		return {};
	}

	# Check cache first
	my $cache_key = "$owner--$repo--$name-$version";
	my $cached_specs = $self->_load_cached_job_specs($cache_dir, $cache_key);
	return $cached_specs if $cached_specs;

	info({pending => 1}, "  - fetching job specs for #M{%s/v%s} from #c{%s/%s}...", $name, $version, $owner, $repo);
	my $start_time = gettimeofday;

	# Try to fetch specs via GitHub API
	my $job_specs = $upstream_config->fetch_job_specs(
		Genesis::CI::BoshReleaseReference->new(
			name => $name,
			version => $version,
			url => $repo_url
		)
	);

	if ($job_specs && @$job_specs) {
		info(" #G{done}".pretty_duration(gettimeofday-$start_time, 0.5, 2));

		# Convert to hash format and cache
		my %specs_hash = map { $_->{job} => $_->{spec} } @$job_specs;
		$self->_cache_job_specs($cache_dir, $cache_key, \%specs_hash);
		return \%specs_hash;
	} else {
		info(" #R{failed}".pretty_duration(gettimeofday-$start_time, 0.5, 2));
		return {};
	}
}

# Load cached job specs if available
sub _load_cached_job_specs {
	my ($self, $cache_dir, $cache_key) = @_;

	my $cache_file = "$cache_dir/$cache_key.json";
	return unless -f $cache_file;

	require JSON;
	require Genesis;
	my $json_text = Genesis::slurp($cache_file);
	return unless $json_text;

	eval {
		my $data = JSON::decode_json($json_text);
		return $data if ref($data) eq 'HASH';
	};

	# If cache file is corrupted, remove it
	unlink $cache_file if $@;
	return;
}

# Cache job specs for future use
sub _cache_job_specs {
	my ($self, $cache_dir, $cache_key, $specs) = @_;

	require JSON;
	require Genesis;
	my $cache_file = "$cache_dir/$cache_key.json";

	eval {
		my $json_text = JSON::encode_json($specs);
		Genesis::mkfile_or_fail($cache_file, 0644, $json_text);
	};

	warning("Failed to cache job specs: %s", $@) if $@;
}

1;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
