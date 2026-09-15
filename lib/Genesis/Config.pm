package Genesis::Config;
use strict;
use warnings;

use Genesis qw/bail bug debug info struct_lookup struct_set_value struct_has in_array load_yaml_file run workdir mkdir_or_fail semver save_to_yaml_file spruce_diff priority_merge flatten unflatten without_backtrace/;
use Genesis::Term qw/bullet decolorize/;
use Genesis::Exit qw/CONFIG/;

use JSON::PP ();
use Digest::SHA qw/sha1_hex/;
use File::Basename qw/dirname/;
use POSIX qw/strftime/;

### Class Constants {{{

use constant {
	TRUE  => JSON::PP::true,
	FALSE => JSON::PP::false,
};

# }}}

### Class Methods {{{

# new - return a bare config object {{{
sub new {
	my ($class,$path,$autosave,$content) = @_;

	bug('No path to config file was specified - cannot autosave') if $autosave && !$path;

	return bless({
			path => $path,
			persistent_signature => undef,
			autosave => ($autosave && $path)? 1 : 0,
			loaded_values => {},
			set_values => $content//{},
			env_values => {},
			default_values => {},
		}, $class);
}

# }}}
# }}}

# Instance Methods {{{
# path - get the path to the configuration file {{{
sub path {
	$_[0]->{path}
}

# }}}
# exists - returns true if the configuration file exists on the filesystem {{{
sub exists {
	return 0 unless $_[0]->{path};
	-f $_[0]->{path}
}

# }}}
# loaded - returns true if the file has been initialized (loaded from or saved to disk) {{{
sub loaded {
	return 1 if defined($_[0]->{persistent_signature});
}

# }}}
# changed - returns true if the local representation differs from the filesystem {{{
sub changed {
	my $self = shift;
	($self->{persistent_signature}||'') ne $self->_signature;
}

# }}}
# get - read a value from the configuration {{{
sub get {
	my ($self,$key,$default,$set_if_missing) = @_;

	# Caching
	$key ||= '';
	return $self->{cache}{$key} if exists($self->{cache}{$key});

	my ($value,$found) = Genesis::struct_lookup($self->_contents,$key,$default);
	if ($set_if_missing && ! defined($found)) {
		$self->set($key,$value);
		$found = $key;
	}
	$self->{cache}{$key} = $value if $found;
	return $value;
}

# }}}
# get_all - get all effective configuration values from all sources {{{
sub get_all {
	my ($self) = @_;
	# Return a deep copy to prevent external mutation of internal state
	return JSON::PP->new->decode(JSON::PP->new->encode($self->_contents));
}

# }}}
# schema - the schema this configuration was last validated against {{{
#
# Also installs one, for a caller that has rebuilt the schema and needs
# set() to coerce against the new one before the configuration is whole
# enough to validate.  Installing is not validating: nothing is checked,
# no default is filled, and the caller still validates before it saves.
sub schema {
	my ($self, $schema) = @_;
	$self->{schema} = $schema if defined $schema;
	return $self->{schema};
}

# }}}
# schema_has - whether the schema declares a dotted path {{{
sub schema_has {
	my ($self, $key) = @_;
	return defined($self->_schema_for_key($key)) ? 1 : 0;
}

# }}}
# has - check if a key exists in the configuration {{{
sub has {
	my ($self, $key) = @_;

	bug("Cannot check for key in configuration without a key") unless defined($key);

	return 1 if exists($self->{cache}{$key});
	my (undef,$found) = Genesis::struct_lookup($self->_contents,$key);
	return $found;
}

# }}}
# is_set - check if a key was explicitly loaded or set (not from env/defaults) {{{
sub is_set {
	my ($self, $key) = @_;

	bug("Cannot check for key in configuration without a key") unless defined($key);

	# Check if key exists in explicit contents (loaded + set, excludes env + defaults)
	return struct_has($self->_explicit_contents, $key);
}

# }}}
# get_source - returns the source of a configuration value {{{
sub get_source {
	my ($self, $key) = @_;

	# Access contents to trigger lazy loading
	$self->_contents;

	# Check each source in priority order (env > set > loaded > default)
	# Return the highest priority source that has this key
	return 'env'     if $self->{env_values}     && struct_has($self->{env_values},     $key);
	return 'set'     if $self->{set_values}     && struct_has($self->{set_values},     $key);
	return 'loaded'  if $self->{loaded_values}  && struct_has($self->{loaded_values},  $key);
	return 'default' if $self->{default_values} && struct_has($self->{default_values}, $key);

	# Key doesn't exist in any source
	return undef;
}

# }}}
# _update_source - updates a value in a specific source structure {{{
sub _update_source {
	my ($self, $source, $key, $value) = @_;
	bug("Cannot update key in configuration without a source") unless defined($source);
	bug("Cannot update key in configuration without a key") unless defined($key);

	my $source_field = "${source}_values";
	bug("Invalid source '$source' - must be one of: env, set, loaded, default")
		unless exists $self->{$source_field};

	# Update the value in the specified source structure
	struct_set_value($self->{$source_field}, $key, $value);

	# Invalidate caches - both the key itself, its descendants, and any parent keys
	# that might contain it (since flatten uses literal empty refs, not actual refs)
	delete($self->{cache}{$_}) for (grep {
		$_ =~ /^$key($|[\.\[])/  ||  # Invalidate self and all descendants
		$key =~ /^\Q$_\E[\.\[]/      # Invalidate if updating a descendant of a cached parent
	} keys(%{$self->{cache}}));
	delete $self->{_contents};
	# Only invalidate _explicit_contents if we modified loaded or set
	delete $self->{_explicit_contents} if $source eq 'loaded' || $source eq 'set';
}

# }}}
# set - write a value to the configuration {{{
sub set {
	my ($self, $key, $value, $save) = @_;
	# TODO: Validate key and value against schema

	bug("Cannot save configuration without a path") if $save && ! $self->{path};

	$value = $self->_coerce_to_schema_type($key, $value);

	# Use _update_source to handle cache invalidation
	$self->_update_source('set', $key, $value);

	$self->save if $self->changed && ($save || $self->{autosave});
	return $self->changed;
}

# }}}
# clear - remove a key from the configuration {{{
sub clear {
	my ($self, $key, $save) = @_;
	# TODO: Delete entire structure if key is undefined, or should that be an error?
	# TODO: Validate key and value against schema

	# Trigger lazy loading
	$self->_contents;

	# Removed from every source that could answer for the key, defaults
	# included.  A default outlives nothing: it was filled from a schema,
	# and a schema built from the configuration's own values changes when
	# the value it was built from is cleared.  Leaving the defaults behind
	# leaves keys the operator never wrote, which the next validation
	# reports as unknown and refuses a removal nobody asked it to refuse.
	struct_set_value($self->{loaded_values},  $key, undef, 1);
	struct_set_value($self->{set_values},     $key, undef, 1);

	# A schema may declare a scalar default at a key an operator then names
	# a path beneath.  Nothing is stored under a scalar, so there is nothing
	# there to remove, and walking down to it would report the scalar it
	# meets as a type mismatch and turn a removal that does nothing into a
	# fatal.
	struct_set_value($self->{default_values}, $key, undef, 1)
		unless _blocked_by_scalar($self->{default_values}, $key);

	# An empty parent left behind wins the merge outright and takes the
	# key's siblings with it.
	$self->_prune_empty_parents($_, $key)
		for ($self->{loaded_values}, $self->{set_values}, $self->{default_values});

	# Invalidate caches
	delete($self->{cache}{$_}) for (grep {$_ =~ /^$key($|[\.\[])/} keys(%{$self->{cache}}));
	delete $self->{_contents};
	delete $self->{_explicit_contents};

	$self->save if $self->changed && ($save || $self->{autosave});
	return $self->changed;
}

# }}}
# save - save the configuration to the filesystem {{{
sub save {
	my ($self) = @_;

	bug("Cannot save configuration without a path") unless $self->{path};

	my $tmp = workdir();
	my $i=1; while (-f "$tmp/$i.json") {$i++};
	open my $fh, ">", "$tmp/$i.json"
		or bail "Unable to create tempfile for YAML conversion: $!";
	print $fh JSON::PP->new->canonical->encode($self->_explicit_contents);
	close $fh;
	my ($out,$rc,$err) = run(
		{stderr => 0},
		'cat "$1" | spruce merge --skip-eval - ; rm "$1"',
		"$tmp/$i.json"
	);
	bail(
		"Failed to convert configuration file %s to yaml: %s",
		$self->{path}, $err
	) if $rc;

	# graft, which many hosts install as spruce, starts its merge output
	# with a document marker where spruce prints none.  Drop one leading
	# marker (and any blank lines under it) so the header printed below
	# is the only "---" in the file; otherwise the comment block becomes
	# its own empty document and `spruce json` refuses to load the file.
	$out =~ s/\A---[ \t]*\n(?:[ \t]*\n)*//;

	mkdir_or_fail(dirname($self->{path}));

	my $now = strftime("%Y-%m-%d at %H:%M:%S UTC", gmtime());
	# $ENV{USER} is reliably set in interactive shells but can be
	# absent in minimal container environments (e.g. Docker containers
	# running as root with no USER env), causing an uninit-printf
	# warning here.  Fall back to the system-level user lookup, then
	# to 'unknown' if both are unavailable.
	my $user = $ENV{USER} || (getpwuid($<))[0] || 'unknown';
	open my $fh2, ">", $self->{path}
		or bail(
			"Failed to write configuration file to %s: %s",
			$self->{path}, $!
		);
	printf $fh2 "---\n# This file is generated by Genesis - do not edit manually.\n# Last updated by %s on %s\n\n", $user, $now;
	print $fh2 $out."\n";
	close $fh2;
	$self->{persistent_signature} = $self->_signature;
	return;
}

# }}}
# replace - replace the configuration with a new hash {{{
sub replace {
	my ($self, $prev_config) = @_;
	my $autosave = $prev_config->{autosave};
	local $prev_config->{autosave} = 0;
	$self->{path} = $prev_config->path;
	$self->{persistent_signature} = $prev_config->{persistent_signature};
	$self->save;
	$self->{autosave} = $autosave;
	return;
}


# }}}
# validate - validate the configuration against a schema {{{
sub validate {
	my ($self, $schema) = @_;
	$self->{schema} = $schema;

	# A default belongs to the schema that filled it, so validating against
	# a new schema starts from none.  Every default this schema declares is
	# filled again below, and one only the previous schema declared would
	# otherwise survive as a key nobody wrote and be reported here as
	# unknown.  That is not hypothetical: part of the repository schema is
	# built from the configuration's own values, so clearing the value the
	# provider block is built from leaves that provider's filled defaults
	# behind and refuses a removal nobody asked it to refuse.
	#
	# The value cache goes with them, because it is a removal like any
	# other and every other remover here invalidates it.  A cached parent
	# hash that still carries a default decides the question below: the
	# fill is skipped when the parent already holds the sub-key, so a warm
	# cache would leave a nested default dropped from the store and gone
	# from the contents while the cache went on reporting it.
	#
	# The env store is left standing, and that is the exposure to be aware
	# of rather than a decision to revisit here: a key an old schema's
	# envvar filled would survive a rebuild and then be reported below as
	# unknown.  Nothing in the repository schema or in any provider
	# fragment declares an envvar today, so no key can reach that store
	# through this path, and the reset stays as it is until one does.
	$self->{default_values} = {};
	$self->{cache} = {};
	delete $self->{_contents};

	my @errors = ();

	# Ensure all required keys are present, and all defaults are set
	for my $key (keys %$schema) {
		if (exists($schema->{$key}{envvar}) and exists($ENV{$schema->{$key}{envvar}})) {
			# Environment variables take precedence over configuration values.
			$self->_update_source('env', $key, $ENV{$schema->{$key}{envvar}});
		} elsif (exists($schema->{$key}{default}) and ! struct_has($self->{loaded_values}, $key) and ! struct_has($self->{set_values}, $key)) {
			# Set default only if not loaded or explicitly set
			$self->_update_source('default', $key, $schema->{$key}{default});
		} elsif ($schema->{$key}{required} and ! struct_has($self->{loaded_values}, $key) and ! struct_has($self->{set_values}, $key)) {
			if (_is_required($schema->{$key}{required}, $self->_contents, $self)) {
				push @errors, "#R{$key}: missing required key";
				next;
			}
		}
	}

	for my $key (sort keys %{$self->_contents}) {
		if (! exists($schema->{$key})) {
			push @errors, "#R{$key}: unknown configuration key: expected one of ".join(', ', keys %$schema);
			next;
		}
		my $value = $self->get($key);
		my @key_errors = $self->_validate_key($key, $schema->{$key});
		push @errors, @key_errors if @key_errors;
	}

	if (@errors) {
		# Under D98 an invalid configuration is a refusal and not a crash,
		# so it carries CONFIG rather than the bare 1 a fatal system error
		# uses.  A pipeline job reads the code to decide whether to retry,
		# to page someone, or to stop.
		bail({exitcode => CONFIG},
			"Configuration validation failed for #C{%s}:%s",
			$self->{path} // '<in-memory config>',
			join('', map {"\n[[".bullet('', inline => 1, indent => 0).">>$_"} @errors));
	}

	# Invalidate contents cache after all validation is complete
	delete $self->{_contents};

	return 1;
}
# }}}
# validate_subtree - validate one block against a schema {{{
#
# Under D105 the module owning a block's shape owns validating it, and
# validate() above is a method on a whole configuration, so this is how a
# module asks for the same treatment of the one block it was handed.
#
# It fills through _validate_key rather than against a copy, deliberately.
# The defaults a fragment declares are read back out of the configuration
# by everything downstream, so a validator handed a detached hash would
# pass and leave the store with none of them in it.
#
# The ignore list is for a key the parent declared and this schema did
# not, which is the discriminator custom_struct has already checked.
sub validate_subtree {
	my ($self, $path, $schema, %opts) = @_;

	my %ignore = map {($_ => 1)} @{$opts{ignore} || []};
	my %declared = (%$schema, map {($_ => {type => 'any'})} keys %ignore);

	# This owns the defaults it files at default priority under the path,
	# which is what lets validate() above stop clearing every default in
	# the configuration before it walks.  A default filled from the schema
	# that was selected last time is not a key anybody wrote, so it goes
	# before this schema fills its own, or the walk below meets it and
	# calls it unknown.  The scalar guard is clear()'s: nothing is stored
	# under a scalar default, so walking down to one would turn a removal
	# that does nothing into a fatal.
	#
	# One block shape is outside that ownership.  When the file carries the
	# block as an explicit empty hash, _validate_key files that block's
	# defaults at loaded priority instead, because the empty hash would
	# otherwise mask them in the merge, and the loaded store is not swept
	# here: it also holds what the operator wrote, and nothing tells the
	# two apart.  So such a block keeps the fills the first walk gave it,
	# and a second schema over it meets them.
	struct_set_value($self->{default_values}, $path, undef, 1)
		unless _blocked_by_scalar($self->{default_values}, $path);
	$self->_prune_empty_parents($self->{default_values}, $path);
	# Swept in both directions, which is what _update_source does for the
	# same reason.  A cached ancestor is a hash that was flattened when the
	# default was still in it, so a caller that read pipeline before this
	# call would go on being handed the default this call just dropped.
	delete($self->{cache}{$_})
		for grep {$_ =~ /^\Q$path\E($|[\.\[])/ || $path =~ /^\Q$_\E[\.\[]/}
			keys %{$self->{cache}};
	delete $self->{_contents};

	return $self->_validate_key($path, {type => 'hash', schema => \%declared});
}

# }}}
# }}}

### Instance Private Methods {{{

# _schema_for_key - the schema entry a dotted path names, if any {{{
sub _schema_for_key {
	my ($self, $key) = @_;

	return undef unless $self->{schema};

	my $spec = $self->{schema};
	for my $part (split /\./, $key) {
		$spec = $spec->{schema} if exists $spec->{schema};
		return undef unless ref($spec) eq 'HASH' && exists $spec->{$part};
		$spec = $spec->{$part};
	}
	return $spec;
}

# }}}
# _blocked_by_scalar - whether a non-hash sits on the way down to a key {{{
#
# Answers no for a path that stops short, because an absent ancestor is not
# a mismatch, and no for anything that is not a plain dotted path, so an
# array index is left to the walk that understands it.
sub _blocked_by_scalar {
	my ($struct, $key) = @_;

	return 0 if $key =~ /[\[\]]/;
	my @parts = split(/\./, $key);
	pop @parts;
	my $node = $struct;
	for my $part (@parts) {
		return 0 unless ref($node) eq 'HASH' && exists($node->{$part});
		$node = $node->{$part};
		return 1 unless ref($node) eq 'HASH';
	}
	return 0;
}

# }}}
# _prune_empty_parents - drop hashes a cleared key left empty behind it {{{
sub _prune_empty_parents {
	my ($self, $struct, $key) = @_;

	my @parts = split(/\./, $key);
	pop @parts;
	while (@parts) {
		my $node = $struct;
		$node = $node->{$_} for @parts[0..$#parts-1];
		last unless ref($node) eq 'HASH';
		my $leaf = $parts[-1];
		last unless ref($node->{$leaf}) eq 'HASH' && !keys %{$node->{$leaf}};
		delete $node->{$leaf};
		pop @parts;
	}
	return;
}

# }}}
# _coerce_to_schema_type - convert a string value to the type its schema declares {{{
sub _coerce_to_schema_type {
	my ($self, $key, $value) = @_;

	return $value if ref($value) || !defined($value);
	return $value unless $self->{schema};

	my $spec = $self->_schema_for_key($key);
	my $type = ref($spec) eq 'HASH' ? ($spec->{type} // '') : '';
	my %types = map {$_ => 1} split(/\|\|/, $type);

	# The only spelling of null available on a command line.
	return undef if $types{null} && $value =~ /^(?:null|~)$/i;

	# A union admitting strings keeps the text: it validates either way, and
	# guessing at a boolean would discard what the operator actually typed.
	return $value if $types{string};

	if ($types{boolean}) {
		# Every non-empty string is true in Perl, so the spellings a person
		# would actually type for false have to be recognised explicitly.
		return $value =~ /^(?:false|no|off|0|)$/i ? FALSE : TRUE;
	}
	return 0 + $value
		if ($types{integer} || $types{number}) && $value =~ /^-?\d+(?:\.\d+)?$/;
	return $value;
}

# }}}
# _contents - the contents of the configuration object computed from source structures {{{
sub _contents {
	my ($self) = @_;
	$self->_load() unless ($self->loaded) || (! $self->exists && exists($self->{loaded_values}));

	# Merge all sources with priority: env > set > loaded > default
	# priority_merge takes multiple hashes in priority order (highest first)
	# and prevents ancestor/descendant conflicts
	# (if it it hasn't been cached already)
	return $self->{_contents} //= priority_merge(
		$self->{env_values},
		$self->{set_values},
		$self->{loaded_values},
		$self->{default_values}
	);
}

# }}}
# _explicit_contents - only loaded and set values (for saving to disk) {{{
sub _explicit_contents {
	my ($self) = @_;
	$self->_load() unless ($self->loaded) || (! $self->exists && exists($self->{loaded_values}));

	# Return cached explicit contents if available
	return $self->{_explicit_contents} if exists $self->{_explicit_contents};

	# Merge only explicit sources: set > loaded
	# Exclude env and default values from disk persistence
	# priority_merge preserves undef values and prevents ancestor/descendant conflicts
	return $self->{_explicit_contents} //= priority_merge(
		$self->{set_values},
		$self->{loaded_values}
	);
}

# }}}
# _load - load the contents of the configuration file from disk {{{
sub _load {
	my ($self, $path) = @_;

	# Re-entrancy guard: prevent infinite recursion when debug/bail
	# triggers configure_log which reads from this same config object
	return if $self->{_loading};
	local $self->{_loading} = 1;

	$path ||= $self->{path};
	bug("Cannot load configuration without a path") unless $path;

	if (-f $path) {
		($self->{loaded_values}, my $rc, my $err) = load_yaml_file($path);
		debug "Loaded ".$path." - rc:$rc";
		bail("Failed to load %s: %s", $path, $err) if ($rc || ! $self->{loaded_values});

		$self->{persistent_signature} = $self->_signature;
	} else {
		$self->{loaded_values} = {};
		$self->save if $self->{autosave} && $self->{path};
	}
}

# }}}
# _signature - generate a signature for the current in-memory contents {{{
sub _signature {
	my ($self) = @_;
	# Don't trigger loading - directly compute from source structures
	# Merge loaded + set (explicit contents) without calling _explicit_contents()
	# Uses priority_merge to match _explicit_contents() behavior
	my $explicit = priority_merge($self->{set_values}, $self->{loaded_values});
	return sha1_hex(JSON::PP->new->canonical->encode($explicit));
}
# }}}
# _is_required - evaluate whether a 'required' constraint is active {{{
#   1              → always required
#   'sibling'      → required when sibling is truthy
#   { sibling => v } → required when sibling eq v
#   sub {...}      → required when the predicate says so
#
# Multiple hash keys are OR'd together.  Future: support arrayref values
# for multi-match on a single sibling, and negation (e.g. { '!key' => v }).
#
# The predicate form is for a rule the other three cannot state, where what
# makes a key required is not a sibling's value but something further off in
# the configuration.  It is handed the siblings and the configuration object
# itself, in that order, so it can read a key at any depth by its dotted
# name.  A hash reference is still a dependency match, so the two reference
# forms do not collide.
sub _is_required {
	my ($req, $siblings, $config) = @_;
	return 0 unless $req;
	return 1 unless ref($req) || $req =~ /\D/;
	if (ref($req) eq 'CODE') {
		return $req->($siblings, $config) ? 1 : 0;
	}
	if (ref($req) eq 'HASH') {
		for my $dep (keys %$req) {
			return 1 if exists($siblings->{$dep}) && defined($siblings->{$dep})
				&& $siblings->{$dep} eq $req->{$dep};
		}
		return 0;
	}
	# String (non-numeric): truthy check on named sibling
	return $siblings->{$req} ? 1 : 0;
}

# }}}
# _validate_key - validate a value against a schema {{{
sub _validate_key {
	my ($self, $key, $schema) = @_;
	my @errors = ();
	my $type = $schema->{type} or bug "Schema for $key has no type";
	my $value = $self->get($key);

	if ($type =~ m/\|\|/) {
		# Allows for multiple types - check that at least one is valid
		my @types = split(/\|\|/, $type);
		my $valid = 0;
		for my $t (@types) {
			if ($self->_validate_key($key, {type => $t})) {
				$valid = 1;
				last;
			}
		}
		if (! $valid) {
			push @errors, "#R{$key}: expected one of ".join(', ', @types);
		}
	} elsif ($type eq 'hasharray') { # Special type that allows an array to be specified as a hash in yaml or a string in environment
		if (ref($value) ne 'ARRAY') {
			push @errors, "#R{$key}: expected an array";
		} else {
			for my $i (0..$#{$value}) {
				my @subkey_errors = $self->_validate_key("$key\[$i\]", $schema->{schema});
				push @errors, @subkey_errors if @subkey_errors;
			}
		}
	} elsif ($type eq 'hash') {
		if (ref($value) ne 'HASH') {
			push @errors, "#R{$key}: expected a hash";
		} else {
			# Check if loaded_values has an explicit empty hash for this key
			my $loaded_is_empty_hash = 0;
			if (keys(%$value) == 0 && struct_has($self->{loaded_values}, $key)) {
				my $loaded_val = struct_lookup($self->{loaded_values}, $key);
				$loaded_is_empty_hash = (ref($loaded_val) eq 'HASH' && keys(%$loaded_val) == 0);
			}
			# Ensure all required keys are present, and all defaults are set
			for my $subkey (keys %{$schema->{schema}}) {
				my $subschema = $schema->{schema}{$subkey};
				if (exists($subschema->{envvar}) && exists($ENV{$subschema->{envvar}})) {
					# Environment variables take precedence over configuration values.
					$self->_update_source('env', "$key.$subkey", $ENV{$subschema->{envvar}});
				} elsif (exists($subschema->{default}) and ! exists($value->{$subkey})) {
					# When the parent key was explicitly {} in loaded_values, apply
					# defaults at loaded priority so they aren't blocked by
					# the empty hash placeholder in priority_merge
					my $source = $loaded_is_empty_hash ? 'loaded' : 'default';
					$self->_update_source($source, "$key.$subkey", $subschema->{default});
				} elsif ($subschema->{required} and ! exists($value->{$subkey})) {
					if (_is_required($subschema->{required}, $value, $self)) {
						push @errors, "#R{$key}: missing required key #ri{$subkey}";
					}
				}
			}
			# Refetch value to include newly-added defaults for recursive validation
			# TODO: Optimize to only refetch if defaults or env values were actually set
			$value = $self->get($key);
			for my $subkey (sort keys %$value) {
				if (! exists($schema->{schema}{$subkey})) {
					push @errors, "#R{$key.$subkey}: unknown configuration key: expected one of ".join(', ', keys %{$schema->{schema}});
					next;
				}
				my @subkey_errors = $self->_validate_key("$key.$subkey", $schema->{schema}{$subkey});
				push @errors, @subkey_errors if @subkey_errors;
			}
		}

	} elsif ($type eq 'array') {
		if (ref($value) ne 'ARRAY') {
			# If the value is a scalar, it most likely came from the environment and needs to be split
			# into an array of values
			my $split = $schema->{envsplit};
			bug(
				"Schema for array $key has no envsplit, but was given a string value: #ri{%s}",
				$value
			) unless $split;
			$value = [split(/$split/, $value, -1)];

			if (defined($schema->{envconvert})) {
				# Convert the values to the specified type based on matches to
				# conversion rules
				for my $idx (0..(scalar(@$value)-1)) {
					my $found = 0;
					my @conversion_errors = ();
					for my $match (@{$schema->{envconvert}}) {
						if ($match->{type} eq 'hasharray') {
							# In string form, hasharray is restricted to pairs of key/value pairs
							my @pairs;
							eval { @pairs = split(qr($match->{pair_split}), $value->[$idx]); };
							if ($@) {
								push @conversion_errors, "Invalid hasharray value: %s", $value->[$idx];
								next;
							}
							my $kvs = $match->{kv_split};
							my $failed = 0;
							my @converted_pairs;
							for (@pairs) {
								# Check that the pair is in the form key=value
								my ($key, $value) = $_ =~ qr(^([^$kvs]+)$kvs([^$kvs]*)$);
								if (!defined($key)) {
									$failed = 1;
									push @conversion_errors, "Invalid hasharray string value: %s", $value->[$idx]; # continue processing to get all errors
								} else {
									push @converted_pairs, {$key => $value};
								}
							}
							next if ($failed);
							$value->[$idx] = \@converted_pairs;
							$found = 1;
							last;
						} elsif ($match->{type} eq 'string') {
							# Pretty much any string will match this, but not null or empty strings
							if (!defined($value->[$idx]) || $value->[$idx] eq '') {
								push @conversion_errors, "Invalid string value: %s", $value->[$idx] ? '""' : '<null>';
							} else {
								$found = 1;
								last;
							}
						} else {
							push @conversion_errors, "Unknown conversion type: %s", $match->{type};
						}
					}
					if (! $found) {
						my $error_list = join("", map {"  - $_\n"} @conversion_errors) || "  - No conversion rule matched the value";
						push @errors, "No conversion rule matched the value: %s\n%s", $value->[$idx], $error_list;
					}
				}
			}
		} # end conversion of strings to an array

		if (ref($value) ne 'ARRAY') {
			push @errors, "#R{$key}: expected an array";
		} else {
			my @subtypes = split(/\|\|/, $schema->{subtype});
			for my $i (0..$#{$value}) {
				my $subschema;
				my $found = 0;
				my @subtype_errors = ();
				for my $subtype (@subtypes) {
					if ($subtype eq 'hasharray') {
						# Hasharray is a special type that allows for a hash representation in of an array
						if (ref($value->[$i]) eq 'HASH') {
							$value->[$i] = [map {($_, $value->[$i]{$_})} keys %{$value->[$i]}];
						} elsif (ref($value->[$i]) eq 'ARRAY') {
							# Already in the correct format
						} else {
							push @subtype_errors, "#R{$key}[$i]: expected a hash or array, not #ri{".($value->[$i] ? $value->[$i] : "<null>")."}";
							next
						}
						$found = 1;
						last;
					} elsif ($subtype eq 'string') {
						if (ref($value->[$i]) ne '' || !defined($value->[$i]) || $value->[$i] eq '') {
							push @subtype_errors, "#R{$key}[$i]: expected a string, not #ri{".($value->[$i] ? $value->[$i] : "<null>")."}";
							next;
						}
						$found = 1;
						last;
					} else {
						if ($subtype eq 'hash') {
							bug "Schema for array $key hash value has no schema" unless $schema->{schema};
							$subschema = {schema => $schema->{schema}, type => 'hash'};
						} else {
							$subschema = $schema->{schema}//{};
							$subschema->{type} //= $subtype;
						}
						if (my @subkey_errors = $self->_validate_key("${key}[$i]", $subschema)) {
							push @subtype_errors, @subkey_errors;
						} else {
							$found = 1;
							last;
						}
					}
				}
				if (!$found) {
					my $error_list = join("", map {"  - $_\n"} @subtype_errors) || "  - No conversion rule matched the value";
					push @errors, sprintf("No subtype matched the value: %s\n%s", $value->[$i], $error_list);
				}
			}
			# Normalize array in place - update the source structure, not set()
			my $source = $self->get_source($key);
			bug("Cannot normalize key '$key' - no source found") unless $source;
			$self->_update_source($source, $key, $value);
		}

	} elsif ($type eq 'boolean') {
		if (! in_array($value, TRUE, FALSE, 1, 0, '', undef, 'true', 'false', 'yes', 'no')) {
			push @errors, "#R{$key}: expected a boolean, not #ri{".($value ? $value : '<null>')."}";
		}
		# Normalize boolean in place - update the source structure, not set()
		my $source = $self->get_source($key);
		bug("Cannot normalize key '$key' - no source found") unless $source;
		$self->_update_source($source, $key, $value ? TRUE : FALSE);
	} elsif ($type eq 'enum') {
		if (! in_array($value, @{$schema->{values}})) {
			push @errors, "#R{$key}: unknown value: #ri{".($value ? $value : "<null>")."}; expected one of ".join(', ', @{$schema->{values}});
		}
	} elsif ($type eq 'string') {
		if (ref($value) ne '' || !defined($value)) {
			push @errors, "#R{$key}: expected a string, not #ri{".($value ? $value : "<null>")."}";
		}
	} elsif ($type eq 'number') {
		if (ref($value) ne '' || !defined($value) || $value !~ m/^-?\d+(\.\d+)?$/) {
			push @errors, "#R{$key}: expected a number, not #ri{".($value ? $value : "<null>")."}";
		}
	} elsif ($type eq 'integer') {
		if (ref($value) ne '' || !defined($value) || $value !~ m/^-?(?:0|[1-9]\d*)$/) {
			push @errors, "#R{$key}: expected an integer, not #ri{".($value ? $value : "<null>")."}";
		}
	} elsif ($type eq 'semver') {
		if (ref($value) ne '' || !defined($value) || ! semver($value)) {
			push @errors, "#R{$key}: expected a number, not #ri{".($value ? $value : "<null>")."}"
				unless (!defined($value) && $schema->{allow_null});
		}
	} elsif ($type =~ /^"(.*?)"$/) {
		if (ref($value) ne '' || !defined($value) || $value ne $1) {
			push @errors, "#R{$key}: expected #ri{$1}, not #ri{".($value ? $value : "<null>")."}";
		}
	} elsif ($type eq 'null') {
		if (defined($value)) {
			push @errors, "#R{$key}: expected null, not #ri{".($value ? $value : "<null>")."}";
		}
	} elsif ($type eq 'custom_struct') {
		# D105: a block whose shape is a function of one of its own values
		# declares that here rather than having a builder read the value
		# raw and assemble a schema out of it.  This is a dispatcher and
		# nothing more: it checks the discriminator against the map and
		# hands the block to the module that owns the shape.
		push @errors, $self->_validate_custom_struct($key, $schema);
	} elsif ($type eq 'opaque') {
		# Passthrough — any value accepted, sub-keys not validated here.
		# Used for config sections delegated to other modules (see Top::register_config_section).
	} elsif ($type eq 'any') {
		# Do nothing
	} else {
		push @errors, "#R{$key}: unknown schema type $type";
	}
	return @errors;
}

# }}}
# _validate_custom_struct - check the discriminator, hand over the rest {{{
sub _validate_custom_struct {
	my ($self, $key, $schema) = @_;

	my $field = $schema->{discriminator}
		or bug "Schema for $key has no discriminator";
	my $map = $schema->{modules}
		or bug "Schema for $key has no module map";

	return ("#R{$key}: expected a hash") unless ref($self->get($key)) eq 'HASH';

	# Filled before the match, because D15 gives the provider type a
	# default and a map has nowhere else to put one.  It is spelled
	# discriminator_default rather than default because a schema entry's
	# default belongs to the key that entry declares, and the parent fills
	# it before this arm is ever reached, so the two cannot share a name.
	if (exists $schema->{discriminator_default} && ! $self->has("$key.$field")) {
		# One block shape needs the fill filed higher than the others.  When
		# the file carried the block as an explicit empty hash, that hash
		# claims the key in the merge and skips every default underneath it,
		# so a fill at default priority would be masked and the operator
		# would meet a refusal naming a null value for a block that has a
		# default.  It goes in at loaded priority in that one case, which is
		# the remedy the hash arm of _validate_key uses for the same reason.
		my $block  = $self->get($key);
		my $loaded = struct_has($self->{loaded_values}, $key)
			? struct_lookup($self->{loaded_values}, $key)
			: undef;
		my $source = (keys(%$block) == 0 && ref($loaded) eq 'HASH'
			&& keys(%$loaded) == 0) ? 'loaded' : 'default';
		$self->_update_source($source, "$key.$field",
			$schema->{discriminator_default});
	}

	my $value = $self->get("$key.$field");
	return ("#R{$key.$field}: unknown value: #ri{".($value // '<null>')."}; ".
		"expected one of ".join(', ', sort keys %$map))
		unless defined $value && exists $map->{$value};

	my $entry = $map->{$value};
	unless (eval {require $entry->{module}; 1}) {  ## no critic
		# Copied first, because bail's own readers run evals that clear it,
		# and cut, because the operator reads the refusal and not the line
		# the require failed on.  The cut is Genesis::without_backtrace,
		# which moved out of Genesis::Top because the load it trims now
		# happens here.
		my $err = $@;
		bail({exitcode => CONFIG},
			"Failed to load %s '%s': %s", $schema->{noun} // 'module',
			$value, without_backtrace($err));
	}

	my $method = $entry->{method} || $schema->{method} || 'validate_config';

	# A rule that answers with a bare undef or an empty string has said
	# nothing, and printing one gives the operator a bullet with nothing
	# after it to read, so nothing empty survives the hand back.
	return grep {defined($_) && length($_)}
		$entry->{class}->$method($self, $key, $field);
}

# }}}
sub show_diff {

	# Shows the difference between the current configuration and another
	# configuration, which defaults to the last saved configuration.
	my ($self, $other) = @_;
	$other ||= Genesis::Config->new($self->{path});

	# Use Genesis::spruce_diff to compare configurations
	my $diff = spruce_diff(
		{object => $other->_contents, label => 'saved'},
		{object => $self->_contents, label => 'current'}
	);

	if ($diff) {
		info("Differences between existing and updated configuration:\n%s", $diff);
	} else {
		info("No differences found between existing and updated configuration");
	}
}

# }}}
# TODO: extract the hash schema validation into a separate method
# }}}
1;
# vim: fdm=marker:foldlevel=1:noet
