package Genesis::Env::Deployment;
# Documentation available in Genesis/Env/Deployment.pod

use strict;
use warnings;
use 5.20.0;

use Genesis qw/
	bail debug bug
	unflatten flatten struct_lookup uniq compare_arrays
	absolute_path mkfile_or_fail slurp
	EXODUS_TIME_FORMAT EXODUS_TIME_FORMAT_SHORT
/;
use Genesis::Term qw/wrap/;

use Archive::Tar;
use IO::Compress::Gzip qw/gzip $GzipError/;
use IO::Uncompress::Gunzip qw/gunzip $GunzipError/;
use JSON::PP qw/decode_json/;
use File::Basename qw/basename/;
use MIME::Base64 qw/encode_base64 decode_base64/;
use Time::Piece;

## Class Constants
use constant {
	action_succeeded => 'success',
	action_failed => 'failed',
	action_pending => 'pending',
	action_post_failed => 'post-failed',
};

### Class Methods
# new - create a new Genesis::Env::Deployment object based on the provided data {{{
sub new {
	my ($class, $env, %data) = @_;

	# Unflatten the data if it contains dot notation
	%data = unflatten(\%data) if grep {$_ =~ /\./} keys %data;

	# Lets do some sanitizing before we validate the data for older dev versions
	if (my $state = delete($data{state}) && !defined($data{action})) {
		$data{action} = $state eq 'deployed' ? 'deploy' : 'terminate';
		$data{result} = action_succeeded;
		$data{genesis_version} //= 'unknown';
		$data{kit} //= {
			id => 'unknown',
			name => 'unknown',
			version => 'unknown',
			is_dev => 0,
			features => [],
		};
		$data{user} //= {
			shell => 'unknown',
			repo => 'unknown',
			vault => 'unknown',
		};
		$data{manifest} //= {
			type => 'unknown',
			sha2 => 'unknown',
		};
	}

	# Get the timestamp from the data if provided.
	my $timestamp = delete($data{timestamp});  # TODO: Should we default to current time?

	# Validate the input data has all the required fields
	my @missing = grep { !exists $data{$_} } qw(
		action result started completed genesis_version reason
		kit user manifest
	);
	# Kit and user are hashrefs with their own required fields
	push @missing, map { "kit.$_" } grep {ref($data{kit}) eq 'HASH' && !exists $data{kit}{$_}} qw(
		id name version is_dev features
	);
	push @missing, map { "user.$_" } grep {ref($data{user}) eq 'HASH' && !exists $data{user}{$_}} qw(
		shell
	);
	push @missing, map { "manifest.$_" } grep {ref($data{manifest}) eq 'HASH' && !exists $data{manifest}{$_}} qw(
		type sha2
	);

	bug(
		"Missing required fields for $timestamp deployment audit: " . join(', ', @missing)
	) if @missing;

	# Validate the action and result fields
	my @valid_actions = qw(deploy terminate);
	my @valid_results = (
		action_succeeded, action_failed, action_pending, action_post_failed
	);
	bug(
		"Invalid action '%s' for deployment audit - must be one of: %s",
		$data{action}, join(', ', @valid_actions)
	) unless grep { $_ eq $data{action} } @valid_actions;

	bug(
		"Invalid result '%s' for deployment audit - must be one of: %s",
		$data{result},
		join(', ', @valid_results)
	) unless grep { $_ eq $data{result} } @valid_results;

	# TDB: Should we automate the inclusion of derivable missing fields?

	my $artifact_defn = undef;
	if (my $artifacts = delete($data{artifacts})) {
		if (ref($artifacts) eq 'HASH') {
			$artifact_defn = {
				format => 'local-file-hash',
				data => $artifacts,
			}
		} elsif (ref($artifacts) eq '' && _is_base64_gzipped($artifacts)) {
			$artifact_defn = {
				format => 'b64-gzipped',
				data => $artifacts,
			}
		} else {
			# TODO: Support uncompressed file contents are subfields under
			#       `artifacts.`, possibly sequenced due to file size exceeding vaults
			#       max field size (1MB)
			bug("Invalid artifacts format - must be a hashref or base64 gzipped string");
		}
	}

	# Convert the timestamps into Time::Piece objects
	$data{started} = Time::Piece->strptime($data{started},EXODUS_TIME_FORMAT)
		if $data{started} && ref($data{started}) ne 'Time::Piece';
	$data{completed} = Time::Piece->strptime($data{completed},EXODUS_TIME_FORMAT)
		if $data{completed} && ref($data{completed}) ne 'Time::Piece';

	unless (defined($timestamp)) {
		my $ts = $data{completed} // $data{started} // Time::Piece->new;
		$timestamp = $ts->strftime(EXODUS_TIME_FORMAT_SHORT) if ref($ts) eq 'Time::Piece';
	}

	return bless {
		env => $env,
		timestamp => $timestamp,
		data => {%data},
		artifacts => $artifact_defn
	}, $class;
}

# }}}

### Instance Methods

sub action {
	return $_[0]->{data}{action};
}

sub result {
	return $_[0]->{data}{result};
}

sub started {
	return $_[0]->{data}{started};
}

sub completed {
	return $_[0]->{data}{completed};
}

sub duration {
	my ($self) = @_;
	return $self->{data}{completed} - $self->{data}{started};
}

sub reason {
	return $_[0]->{data}{reason} // 'unknown';
}

# lookup - Explicit method to access internal data fields {{{
sub lookup {
	my $self = shift;
	return scalar struct_lookup($self->{data}, @_);
}

# }}}
# timestamp - Return the timestamp for this deployment {{{
sub timestamp {
	return $_[0]->{timestamp};
}

# }}}
# env - Accessor for the environment {{{
sub env {
	return $_[0]->{env};
}

# }}}
# committed - true if the deployment has been committed to exodus {{{
sub committed {
	my $self = shift;
	return $self->env->vault->has(
		'deployments/' . $self->timestamp()
	);
}

# }}}
# commit - Save the deployment audit to the environment {{{
sub commit {
	my $self = shift;

	bail(
		"Cannot commit a deployment that already exists!"
	) if $self->committed();

	# Get the deployment data
	my $data = $self->{data};

	# Process the artifacts
	my $artifacts = $self->{artifacts};
	my $deployment_time = $self->timestamp();
	my $artifact_file = undef;
	if ($artifacts) {
		$artifact_file = $self->env->workpath("artifacts-$deployment_time.tgz.b64");
		if ($artifacts->{format} eq 'b64-gzipped') {
			# We need to store this value as a temporary file so that we can use the key@file
			# notation to store the gzipped data in the vault
			mkfile_or_fail($artifact_file, $artifacts->{data});
		} elsif ($artifacts->{format} eq 'local-file-hash') {
			$self->_build_artifacts_file(
				$artifact_file,
				%{$artifacts->{data}}
			);
		}
	}

	# Create the deployment audit
	my $deployment_data = flatten({
		$self->{data}->%*,
		timestamp => $self->timestamp(),
	});

	# Convert the timestamps into EXODUS_TIME_FORMAT strings if they are Time::Piece objects
	$deployment_data->{started} = $deployment_data->{started}->strftime(EXODUS_TIME_FORMAT)
		if ref($deployment_data->{started}) eq 'Time::Piece';
	$deployment_data->{completed} = $deployment_data->{completed}->strftime(EXODUS_TIME_FORMAT)
		if ref($deployment_data->{completed}) eq 'Time::Piece';

	# Build a vault command set to store the deployment audit
	my @cmds = (
		'set',
		$self->env->exodus_base . '/deployments/' . $self->timestamp(),
		'__flattened__=1',
		map {
			"$_=$deployment_data->{$_}"
		} keys %$deployment_data
	);
	push @cmds, "artifacts@$artifact_file" if $artifact_file && -f $artifact_file;

	my ($out, $rc, $err) = $self->env->vault->authenticate->query(
		{ redact => 1 },
		@cmds
	);
	bail(
		"Failed to set deployment audit data in exodus: %s\n%s",
		$out, $err
	) if ($rc);
	return 1;
}

# }}}

# REFATOR:  Deployments prior to being committed have a different set of keys
# for the artifacts.  While committed deployments have artifacts known by their base
# filename, uncommitted deployments have artifacts known by their type:
#  log, manifest, unpruned, vars, state, store, and secrets
#
# Ideally we need to track both the type and the name of the artifact, so we can ask
# for the artifact by either name or type.  We could do this by using a name of
# type/filename in the tarball, but that's not backwards compatible.  Alternatively,
# we could have a _map file in the tarball that maps the filename to the type, which
# also isn't backwards compatible.
#
# One backwards compatible solution is to glean the type from the filename:
# log -> /-output\.log$/,
# secrets -> /secrets\.json$/,
# vars -> /\.vars$/,
# state -> /-state\.(json|yml)$/,
# store -> /-store\.(json|yml)$/,
# unpruned -> /-unpruned\.yml$/,
# manifest -> /<$env->name>.yml$/
#
# These values are based on the deployment_cache_path_lookup() method in
# Genesis::Env. The problem with this is that it imposes a fragility based on
# the the current implementation of the deployment_cache_path_lookup() method.

# available_artifacts - Return the list of artifact files for this deployment {{{
sub available_artifacts {
	my ($self) = @_;
	
	# Return undef if no artifacts
	return undef unless $self->{artifacts};

	if ($self->{artifacts}{format} eq 'local-file-hash') {
		# If the artifact is a local file hash, return its keys
		my @artifacts = keys %{$self->{artifacts}{data}};
		# Add 'secrets.json' if 'secrets' is available
		push @artifacts, 'secrets.json' if (grep {$_ eq 'secrets'} @artifacts);
		return sort @artifacts;

	} elsif ($self->{artifacts}{format} eq 'b64-gzipped') {
		# If the artifact is a gzipped base64 string, extract file list from tarball
		my $artifact_tarball = $self->_get_artifact_tarball();
		my @filelist = $artifact_tarball->list_files();
		
		# If secrets.json is available, add both secrets.json and secrets to the list
		my @artifacts = @filelist;
		push @artifacts, 'secrets' if grep {$_ eq 'secrets.json'} @filelist;
		return sort @artifacts;
	} 
	
	bug("Unknown artifact format: " . ($self->{artifacts}{format} || 'undefined'));
}
# }}}

# get_artifact - Get the artifact data for a specific artifact {{{
sub get_artifact {
	my ($self, $artifact) = @_;

	bail("Artifact name is required") unless $artifact;
	my $artifact_hash = $self->get_artifacts($artifact);
	bail(
		"artifact '$artifact' not found in deployment"
	) unless ref($artifact_hash) eq 'HASH' && exists $artifact_hash->{$artifact};
	return $artifact_hash->{$artifact};
}
# }}}

# get_artifacts - Get the artifacts contents for one or more artifacts (default is all) {{{
sub get_artifacts {
	my ($self, @artifacts) = @_;
	
	# Make sure we have artifacts
	return {} unless $self->{artifacts};
	
	# If 'secrets' is requested, we need to handle it specially
	my $secrets_requested = grep {$_ eq 'secrets'} @artifacts;
	my $secrets_json_requested = grep {$_ eq 'secrets.json'} @artifacts;
	my $contents = $self->_get_artifact_hash(@artifacts);
	
	# If secrets.json exists and secrets was requested, add it under the 'secrets' key
	if (exists($contents->{'secrets.json'})) {
		my $secrets_json = $contents->{'secrets.json'};
		
		# If 'secrets' was explicitly requested, decode JSON and add as 'secrets'
		if ($secrets_requested) {
			$contents->{secrets} = $secrets_json ? decode_json($secrets_json) : {};
			delete $contents->{'secrets.json'} unless ($secrets_json_requested)
		}
	}
	
	return $contents;
}
# }}}

# extract_artifacts_to - Extract the artifacts from the deployment to the given path {{{
sub extract_artifacts_to {
	my ($self, $path, @artifacts) = @_;
	
	# If path is not absolute, make it relative to the directory the user called genesis from
	my $target_path = absolute_path($path, $ENV{GENESIS_CALLER_DIR});
	bail(
		"Path #B{%s} is not a directory", $path
	) unless -d $target_path;

	# No artifacts to extract
	if (!$self->{artifacts}) {
		debug("No artifacts available for deployment %s", $self->timestamp);
		return 0;
	}

	# Get all artifacts
	bail(
		"Cannot extract secrets to a file - use 'secrets.json' instead"
	) if grep {$_ eq 'secrets'} @artifacts;
	my $artifacts_hash = $self->_get_artifact_hash(@artifacts);
	
	# Write each artifact to the specified path
	my $count = 0;
	for my $artifact (keys %$artifacts_hash) {
			# Artifact names cannot contain paths as they are committed with the basename of the file
		bail(
			"Invalid artifact name '%s' - artifact names cannot contain path separators", 
			$artifact
		) if $artifact =~ m{/};
		
		# Write the artifact to the file
		my $output_path = "$target_path/$artifact";
		mkfile_or_fail($output_path, 0644, $artifacts_hash->{$artifact});
		$count++;
	}
	
	return $count; # Return the number of artifacts extracted
}

# }}}

### Private Instance Methods

# _get_artifact_hash - Internal helper to get all artifacts as a hash {{{
sub _get_artifact_hash {
	my ($self, @artifacts) = @_;
	
	my %artifacts_hash = ();
	
	# First convert all 'secrets' requests to 'secrets.json' for internal processing
	my $requested_secrets = grep {$_ eq 'secrets'} @artifacts;
	my $requested_secrets_json = grep {$_ eq 'secrets.json'} @artifacts;
	@artifacts = uniq map {$_ eq 'secrets' ? 'secrets.json' : $_} @artifacts;
	
	my @available_artifacts = grep {$_ ne 'secrets'} $self->available_artifacts();
	my ($invalid_artifacts) = compare_arrays(\@artifacts, \@available_artifacts);
	bail(
		"Invalid artifacts requested: %s",
		join(', ', map {
			($_ eq 'secrets.json' && $requested_secrets)
				? $requested_secrets_json
					? qw/secrets secrets.json/
					: qw/secrets/
				: $_
		} @$invalid_artifacts)
	) if @$invalid_artifacts;
	
	@artifacts = @available_artifacts if !@artifacts;
	
	if ($self->{artifacts}{format} eq 'local-file-hash') {
		# Handle local file hash format

		# Process all non-secrets artifacts
		foreach my $artifact (grep {$_ ne 'secrets.json'} @artifacts) {
			my $file = $self->{artifacts}{data}{$artifact};
			bail("Artifact '$artifact' file not found") unless $file && -f $file;
			$artifacts_hash{$artifact} = slurp($file);
		}
		
		# Handle secrets separately if needed
		if ($requested_secrets || $requested_secrets_json) {
			if (exists $self->{artifacts}{data}{secrets}) {
				if (! @{$self->{artifacts}{data}{secrets}||[]}) {
					$artifacts_hash{'secrets.json'} = '{}';
				} else {
					my $secrets = $self->env->vault->query({redact => 1},
						'export', 'secrets',
						$self->{artifacts}{data}{secrets}
					);
					$artifacts_hash{'secrets.json'} = $secrets;
				}
			} else {
				bail("Artifact 'secrets.json' not found in deployment");
			}
		}
	}
	elsif ($self->{artifacts}{format} eq 'b64-gzipped') {
		# Handle gzipped base64 format
		my $artifact_tarball = $self->_get_artifact_tarball();
		
		# Load each artifact
		foreach my $file (@artifacts) {
			my $content = $artifact_tarball->get_content($file);
			bail("Failed to extract artifact '$file' from archive") unless defined($content);
			$artifacts_hash{$file} = $content;
		}
	}
	return \%artifacts_hash;
}

# }}}
# _build_artifacts_file - Build a tarball of deployment artifacts {{{
sub _build_artifacts_file {
	my ($self, $artifact_file, %artifacts) = @_;

	my $tar = Archive::Tar->new;

	# Secrets aren't a file, but a collection of vault paths, so we need to
	# handle them separately
	my $secrets = delete($artifacts{secrets});

	# Add in all the artifacts
	# TODO: Support directories or list of files so dev kits, or even the whole deployment repo can be included
	for my $artifact (keys %artifacts) {
		next unless $artifacts{$artifact} && -f $artifacts{$artifact};
		# Use the basename so when it is extracted, it matches the original file name
		$tar->add_data(basename($artifacts{$artifact}), slurp($artifacts{$artifact}));
	}

	# Add in all secrets used by the manifest
	if (defined $secrets && ref($secrets) eq 'ARRAY') {
		my @paths = uniq map {$_ =~ s/:.*//r} (@$secrets); # can't export individual keys
		my $content = @paths
			? $self->env->vault->query({redact => 1}, 'export', @paths)
			: '{}';
		$tar->add_data('secrets.json', $content);
	}

	# Compress and base64 encode the artifacts into a tarball
	my $compressed_data;
	open(my $data_fh, '>', \$compressed_data);
	$tar->write(IO::Compress::Gzip->new($data_fh, Level => 9, Append => 0, AutoClose => 1))
		or bail("Failed to compress manifest artifacts");

	my $encoded_artifacts = encode_base64($compressed_data);
	mkfile_or_fail($artifact_file, $encoded_artifacts);

	return 1;
}

# }}}

# _get_artifact_tarball - Get the artifact tarball for this deployment {{{
sub _get_artifact_tarball {
	my ($self) = @_;

	return $self->{__tarball} if $self->{__tarball};

	bug(
		"Cannot get artifact tarball for deployment without compressed artifacts"
	) unless $self->{artifacts} && $self->{artifacts}{format} eq 'b64-gzipped';

	my $artifacts_data = $self->{artifacts}{data};
	my $tar = Archive::Tar->new;
	my $compressed_data = decode_base64($artifacts_data);
	$tar->read(IO::Uncompress::Gunzip->new(\$compressed_data))
		or bail("Failed to decompress manifest artifacts");

	return $self->{__tarball} = $tar;
}

# }}}

# _is_base64_gzipped - Determines if a string is base64-encoded gzipped data {{{
sub _is_base64_gzipped {
	my ($base64_data) = @_;
	
	# Ensure we have data and it looks like base64
	return 0 unless $base64_data && length($base64_data) >= 12;

	# Check if the string is base64-encoded
	my $snippet = substr($base64_data, 0, 12);
	return 0 unless $snippet =~ /^[A-Za-z0-9+\/=]+$/;

	# Decode the first few characters and check for gzip magic number
	my $decoded = decode_base64($snippet);
	return $decoded =~ /^\x1F\x8B/;
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
