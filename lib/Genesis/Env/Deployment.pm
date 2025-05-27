package Genesis::Env::Deployment;
# Documentation available in Genesis/Env/Deployment.pod

use strict;
use warnings;
use 5.20.0;

use Genesis qw/
	bail debug bug
	unflatten flatten struct_lookup uniq compare_arrays
	absolute_path mkfile_or_fail slurp in_array
	EXODUS_TIME_FORMAT EXODUS_TIME_FORMAT_SHORT
/;
use Genesis::Term qw/wrap/;

use Archive::Tar;
use IO::Compress::Gzip qw/gzip $GzipError/;
use IO::Uncompress::Gunzip qw/gunzip $GunzipError/;
use JSON::PP qw/decode_json encode_json/;
use File::Basename qw/basename/;
use MIME::Base64 qw/encode_base64 decode_base64/;
use Time::Piece;

## Class Constants
use constant {
	action_succeeded   => 'success',
	action_failed      => 'failed',
	action_pending     => 'pending',
	action_post_failed => 'post-failed',
	action_assumed     => 'assumed',

	artifact_map_file  => '_artifact_map.json',
};

### Class Methods
# new - create a new Genesis::Env::Deployment object based on the provided data {{{
sub is_a_successful_result {
	my ($result) = @_;
	return in_array($result, action_succeeded, action_post_failed);
}
sub is_a_failed_result {
	my ($result) = @_;
	return in_array($result, action_failed);
}

sub new {
	my ($class, $env, %data) = @_;

	# Validate that env is a Genesis::Env object
	bug("Expected Genesis::Env object, got %s", ref($env) || 'undefined')
		unless ref($env) && $env->isa('Genesis::Env');

	# Unflatten the data if it contains dot notation
	%data = unflatten(\%data) if grep {$_ =~ /\./} keys %data;

	# Lets do some sanitizing before we validate the data for older dev versions
	if (my $state = delete($data{state})) {
		$data{action} = $state eq 'deployed' ? 'deploy' : 'terminate' unless defined($data{action});
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
			repo  => 'unknown',
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
	) if $data{action} eq 'deploy';
	push @missing, map { "user.$_" } grep {ref($data{user}) eq 'HASH' && !exists $data{user}{$_}} qw(
		shell
	);
	push @missing, map { "manifest.$_" } grep {ref($data{manifest}) eq 'HASH' && !exists $data{manifest}{$_}} qw(
		type sha2
	) if $data{action} eq 'deploy';

	# TODO: Should we validate against unknown fields, or just allow them?

	bug(
		"Missing required fields for $timestamp deployment audit: " . join(', ', @missing)
	) if @missing;

	# Validate the action and result fields
	my @valid_actions = qw(deploy terminate);
	my @valid_results = (
		action_succeeded, action_failed, action_pending, action_post_failed, action_assumed
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

sub succeeded {
	return is_a_successful_result($_[0]->{data}{result});
}

sub started {
	my ($self,$strf_format) = @_;
	return $self->{data}{started} unless $strf_format;
	return $self->{data}{started}->strftime($strf_format)
		if ref($self->{data}{started}) eq 'Time::Piece';
	bail(
		"Cannot format started timestamp '%s' - not a Time::Piece object",
		$self->{data}{started}
	)
}

sub completed {
	my ($self,$strf_format) = @_;
	return $self->{data}{completed} unless $strf_format;
	return $self->{data}{completed}->strftime($strf_format)
		if ref($self->{data}{completed}) eq 'Time::Piece';
	bail(
		"Cannot format completed timestamp '%s' - not a Time::Piece object",
		$self->{data}{completed}
	)
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
		sequence => $self->env->deployments->next_sequence_number(),
		timestamp => $self->_get_ts_string($self->{data}{completed}),
	});

	# Convert the timestamps into EXODUS_TIME_FORMAT strings if they are Time::Piece objects
	$deployment_data->{started} = $deployment_data->{started}->strftime(EXODUS_TIME_FORMAT)
		if ref($deployment_data->{started}) eq 'Time::Piece';
	$deployment_data->{completed} = $deployment_data->{completed}->strftime(EXODUS_TIME_FORMAT)
		if ref($deployment_data->{completed}) eq 'Time::Piece';

	# Build a vault command set to store the deployment audit
	my @cmds = (
		'set',
		$self->env->exodus_base . '/deployments/' . $deployment_data->{timestamp},
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
	$self->env->deployments->reset; # FIXME: This should be more surgical.
	return ($out, $rc, $err) if wantarray;
	bail(
		"Failed to set deployment audit data in exodus: %s\n%s",
		$out, $err
	) if ($rc);
	return 1;
}

# }}}

# artifact_types - Return the list of artifact types for this deployment {{{
sub artifact_types {
	my ($self) = @_;
	my $artifact_map = $self->_artifact_map();
	return sort keys %$artifact_map;
}

# }}}
# artifact_filenames - Return the list of artifact filenames for this deployment {{{
sub artifact_filenames {
	my ($self) = @_;
	# Return the list of artifact filenames for this deployment
	my $artifact_map = $self->_artifact_map();
	return sort values %$artifact_map;
}

# }}}

# artifact - return the contents of a specific artifact by type or filename {{{
sub artifact {
	my ($self, $artifact) = @_;

	bail("Artifact name is required") unless $artifact;
	my $artifact_hash = $self->artifacts($artifact);

	bail(
		"artifact '$artifact' not found in deployment"
	) unless ref($artifact_hash) eq 'HASH' && exists $artifact_hash->{$artifact};
	return $artifact_hash->{$artifact};
}
# }}}

# artifacts - Get the artifacts contents for one or more artifacts (default is all) {{{
sub artifacts {
	my ($self, @artifacts) = @_;
	
	# Make sure we have artifacts
	return {} unless $self->{artifacts};
	
	my $contents = $self->_get_artifact_hash(@artifacts);
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
		return {};
	}

	# Get all artifacts
	bail(
		"Cannot extract secrets to a file - use 'secrets.json' instead"
	) if grep {$_ eq 'secrets'} @artifacts;
	my $artifacts_hash = $self->_get_artifact_hash(@artifacts);
	
	# Write each artifact to the specified path
	my %artifact_files = ();
	for my $artifact (keys %$artifacts_hash) {
		my $fileref = $self->_get_artifact_filename($artifact);
			# Artifact names cannot contain paths as they are committed with the basename of the file
		bail(
			"Invalid artifact filename '#B{%s}'%s - artifact names cannot contain path separators", 
			$fileref,
			$artifact eq $fileref ? '' : " for artifact #M{$artifact}"
		) if $fileref =~ m{/};
		
		# Write the artifact to the file
		my $output_path = "$target_path/$fileref";
		mkfile_or_fail($output_path, 0644, $artifacts_hash->{$artifact});
		debug("Extracted artifact '%s' to %s", $artifact, $output_path);
		$artifact_files{$artifact} = $output_path;
	}
	
	return \%artifact_files;
}

# }}}

### Private Instance Methods

# _get_artifact_hash - Internal helper to get all artifacts as a hash {{{
sub _get_artifact_hash {
	my ($self, @artifacts) = @_;
	
	my %results = ();

	if (!@artifacts) {
		# If no artifacts are specified, return all available artifacts
		@artifacts = $self->artifact_types();
	} else {
		# Validate the requested artifacts
		my @invalid_artifacts;
		for my $ref (@artifacts) {
			next if $self->_is_artifact_type($ref);
			next if $self->_is_artifact_filename($ref);
			push @invalid_artifacts, $ref;
		}
		bail(
			"Invalid artifacts requested: %s",
			join(', ', @invalid_artifacts)
		) if @invalid_artifacts;
	}
	
	my $artifacts_map = $self->_artifact_map();
	if ($self->{artifacts}{format} eq 'local-file-hash') {
		# Handle local file hash format - this uses type as the key, but it doesn't
		# have a secrets.json file, but rather a secrets key that contains the vault paths
		my $requested_secrets = grep {$_ eq 'secrets'} @artifacts;
		my $requested_secrets_json = grep {$_ eq 'secrets.json'} @artifacts;

		# Process all non-secrets artifacts
		foreach my $artifact (grep {$_ !~ /^secrets(\.json)?$/} @artifacts) {

			my $key = $self->_get_artifact_type($artifact);
			my $fileref = $artifacts_map->{$key} // $artifact;
			my $file = $self->{artifacts}{data}{$key};
			bail("artifact '$artifact' file not found") unless $file && -f $file;
			$results{$artifact} = slurp($file);
		}
		
		# Handle secrets separately if needed
		if ($requested_secrets || $requested_secrets_json) {
			# Already validated that secrets is a valid artifact type

			my $contents;
			if (@{$self->{artifacts}{data}{secrets}||[]}) {
				$contents = $self->env->vault->query({redact => 1},
					'export', 'secrets',
					$self->{artifacts}{data}{secrets}->@*
				);
			} else {
				$contents = '{}';
			}
			$results{'secrets'} = $contents if $requested_secrets;
			$results{'secrets.json'} = $contents if $requested_secrets_json;
		}

	}	elsif ($self->{artifacts}{format} eq 'b64-gzipped') {
		# Handle gzipped base64 format - this uses the filename as the key
		my $artifact_tarball = $self->_get_artifact_tarball();
		
		# Load each artifact
		foreach my $ref (@artifacts) {
			my $fileref = $artifacts_map->{$ref} // $ref;
			my $content = $artifact_tarball->get_content($fileref);
			bail("Failed to extract artifact '$ref' from archive") unless defined($content);
			$results{$ref} = $content;
		}
	}
	return \%results;
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

	# Add in the artifact map
	my $artifact_map = $self->_artifact_map();
	$tar->add_data(artifact_map_file, encode_json($artifact_map))
		if $artifact_map && keys %$artifact_map;

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

# _artifact_map - return the artifact map for this deployment {{{
sub _artifact_map {
	my ($self) = @_;

	return undef unless $self->{artifacts};
	return $self->{artifacts}{map} if $self->{artifacts}{map};

	my %artifact_map = ();
	if ($self->{artifacts}{format} eq 'local-file-hash') {
		# If the artifacts are a local file hash, let's build a map from the hash
		%artifact_map = map {
			$_ => basename($self->{artifacts}{data}{$_})
		} grep {$_ ne 'secrets'} keys %{$self->{artifacts}{data}};
		if (exists $self->{artifacts}{data}{secrets}) {
			# Add 'secrets.json' if 'secrets' is available
			$artifact_map{secrets} = 'secrets.json'; # FIXME: Shouldn't be hardcoded
		}
	} elsif ($self->{artifacts}{format} eq 'b64-gzipped') {
		# If the artifacts are gzipped base64, we need to extract the artifact map from the tarball
		my $artifact_tarball = $self->_get_artifact_tarball();
		if ($artifact_tarball->contains_file(artifact_map_file)) {
			my $artifact_map_content = $artifact_tarball->get_content(artifact_map_file);
			# RISK: This will fail if the artifact map is not valid JSON
			return $self->{artifacts}{map} = decode_json($artifact_map_content)
				if $artifact_map_content;
		}
		# Tarball does not contain an artifact map, so we need to build it
		my $env_name = $self->env->name;
		my $artifact_regex_map = {
			log       => qr/^${env_name}-output\.log$/,
			secrets   => qr/^secrets\.json$/,
			vars      => qr/^${env_name}\.vars$/,
			state     => qr/^${env_name}-state\.(json|yml)$/,
			store     => qr/^${env_name}-store\.(json|yml)$/,
			unpruned  => qr/^${env_name}-unpruned\.yml$/,
			manifest  => qr/^${env_name}\.yml$/
		};
		my @tarball_files = $artifact_tarball->list_files();
		for my $filename (grep {$_ ne artifact_map_file} @tarball_files) {
			my $matched = 0;
			for my $key (keys %$artifact_regex_map) {
				if ($filename =~ $artifact_regex_map->{$key}) {
					$artifact_map{$key} = $filename;
					$matched = 1;
					last;
				}
			}
			# If we didn't find a match, use the filename as the key
			if (!$matched) {
				$artifact_map{$filename} = $filename;
			}
		}
	}
	return $self->{artifacts}{map} = \%artifact_map;
}

# }}}
# _is_artifact_type - Check if the given artifact is a type {{{
sub _is_artifact_type {
	return exists $_[0]->_artifact_map->{$_[1]} ? 1 : 0;
}

# }}}
# _is_artifact_filename - Check if the given artifact is a filename {{{
sub _is_artifact_filename {
	my ($self, $ref) = @_;
	return (grep {$_ eq $ref} values $self->_artifact_map->%*) ? 1 : 0;
}

# }}}

# _get_artifact_type - Get the artifact type for the given reference {{{
sub _get_artifact_type {
	my ($self, $ref) = @_;
	# Get the artifact type for the given reference
	my $artifact_map = $self->_artifact_map();
	return $ref if exists $artifact_map->{$ref};
	return (grep {$artifact_map->{$_} eq $ref} keys %$artifact_map)[0];
}

# }}}
# _get_artifact_filename - Get the artifact filename for the given reference {{{
sub _get_artifact_filename {
	my ($self, $ref) = @_;
	# Get the artifact filename for the given reference
	my $artifact_map = $self->_artifact_map();
	return $artifact_map->{$ref} if exists $artifact_map->{$ref};
	return (grep {$_ eq $ref} values %$artifact_map)[0];
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

# _ts_string - Make a timestamp string from a Time::Piece object or a string {{{
sub _get_ts_string {
	my ($ts) = @_;
	$ts //= Time::Piece->new;  # Default to current time if not provided
	return $ts->strftime(EXODUS_TIME_FORMAT_SHORT) if ref($ts) eq 'Time::Piece';
	return (
		$ts =~ s/[Z ]?[+-]0000$//r =~ s/[^0-9]+//gr
	) if $ts =~ /^\d{4}-?\d{2}-?\d{2}[T ]?\d{2}:?\d{2}:?\d{2}([Z ]?[+-]0000)?$/;
	# FIXME: Support non-UTC timestamps with timezone offsets?
	bail("Invalid timestamp format: $ts");
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
