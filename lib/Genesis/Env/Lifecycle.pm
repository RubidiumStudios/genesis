package Genesis::Env::Lifecycle;
use strict;
use warnings;
use utf8;

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::UI;

use Service::BOSH::Director;
use Service::BOSH::CreateEnvProxy;
use Service::Vault::Remote;

use JSON::PP qw/encode_json decode_json/;
use POSIX qw/strftime/;

use constant {
	EXODUS_TIME_FORMAT => "%Y-%m-%d %H:%M:%S %z",
	EXODUS_TIME_FORMAT_SHORT => "%Y%m%d%H%M%S",
};

### Class Methods {{{

# new - create a raw Genesis::Env object {{{
sub new {
	# Do not call directly, use create or load instead
	my ($class, %opts) = @_;

	# validate call
	for (qw(name top)) {
		bug("No '$_' specified in call to Genesis::Env->new!!")
			unless $opts{$_};
	}

	# drop the YAML suffix
	$opts{name} =~ s/\.yml$//;
	$opts{file} = "$opts{name}.yml";

	# environment names must be valid.
	my $err = _env_name_errors($opts{name});
	bail("Bad environment name '$opts{name}': %s", $err) if $err;

	# make sure .genesis is good to go
	bail("No deployment type specified in .genesis/config!\n")
		unless $opts{top}->type;

	$opts{__tmp} = workdir('ENV');
	return bless(\%opts, $class);
}

# }}}
# load - return an Genesis::Env object represented by a environment file {{{
sub load {
	my ($class,%opts) = @_;

	bug("No '$_' specified in call to Genesis::Env->load!!")
		for (grep {! $opts{$_}} qw/name top/);

	my $env = $class->new(get_opts(\%opts, qw(name top)));
	my (@errors, @config_warnings, @deprecations);
	while (1) {
		push(@errors, sprintf(
			"Environment file #C{%s} does not exist.",
			$env->{file}
		)) unless -f $env->path($env->{file});
		last if @errors;

		$env->notify("using environment file #M{%s}", humanize_path($env->path($env->{file})))
			if ($ENV{GENESIS_PREFIX_TYPE}//'none') eq "search";

		push(@errors, "#ci{kit.subkits} has been superceeded by #ci{kit.features}")
			if $env->defines('kit.subkits');

		my ($env_name, $env_src) = $env->lookup(['genesis.env','params.env']);
		if ($env_name) {
			push(@errors, "environment name mismatch: #ci{$env_src} specifies #ri{$env_name}, expected #ci{$env->{name}}")
				unless $env->{name} eq $env_name || in_callback || envset("GENESIS_LEGACY");
		} else {
			push(@errors, "missing required #ci{genesis.env} field")
		}

		# Deprecation Warnings
		if ($env->defines('params.genesis_version_min')) {
			push(@deprecations, "#ci{params.genesis_version_min} has been superceeded by #ci{genesis.min_version}");
			$env->{__params}{genesis}{min_version} = delete($env->{__params}{params}{genesis_version_min});
		}
		if ($env->defines('params.bosh')) {
			push(@deprecations, "#ci{params.bosh} has been superceeded by #ci{genesis.bosh_env}");
			$env->{__params}{genesis}{bosh_env} = delete($env->{__params}{params}{bosh});
		}

		(my $min_version = $env->lookup(['genesis.min_version','genesis.minimum_version'],'')) =~ s/^v//i;
		if ($min_version) {
			if ($Genesis::VERSION eq "(development)") {
				push(@config_warnings, "using development version of Genesis, cannot confirm it meets minimum version of #ci{$min_version}");
			} elsif (! new_enough($Genesis::VERSION, $min_version)) {
				push(@errors, "genesis #Ri{v$Genesis::VERSION} does not meet minimum version of #ci{$min_version}");
			}
		}
		$env->{__min_version} = $min_version || '0.0.0';

		my $kit_name = $env->lookup('kit.name');
		my $kit_version = $env->lookup('kit.version');
		my $kit = $env->{top}->local_kit_version($kit_name, $kit_version);
		if ($kit) {
			$env->{kit} = $kit;
			my $overrides = $env->lookup('kit.overrides');
			if (defined($overrides)) {
				$overrides = [ $overrides ] unless (ref($overrides) eq 'ARRAY');
				my @override_files;

				my $i=0;
				my $override_dir = workdir;
				for my $override (@$overrides) {
					my $file="$override_dir/env-overrides-$i.yml";
					$i+=1;
					if (ref($override) eq "HASH") {
						save_to_yaml_file($override,$file);
					} else {
						mkfile_or_fail($file,$override);
					}
					push @override_files, $file;
				}
				$env->kit->apply_env_overrides(@override_files);
			}
		} elsif (!$kit_name) {
			push(@errors, "Missing #ci{kit.name} and no local dev kit");
			push(@errors, "Missing #ci{kit.version}") unless $kit_version;
		} elsif (!$kit_version) {
			push(@errors, "Missing #ci{kit.version}");
		} else {
			push(@errors, sprintf(
				"Unable to locate v%s of #M{%s}` kit for #C{%s} environment.",
				$kit_version, $kit_name, $env->name
			));
		}
		last if @errors;
		$env->kit->check_prereqs($env) or bail "Cannot use the selected kit.";

		if (! $env->kit->feature_compatibility("2.7.0")) {
			push(@errors, sprintf("kit #M{%s} is not compatible with #ci{secrets_mount} feature; check for newer kit version or remove feature.", $env->kit->id))
				if ($env->secrets_mount ne $env->default_secrets_mount);
			push(@errors, sprintf("kit #M{%s} is not compatible with #C{exodus_mount} feature; check for newer kit version or remove feature.", $env->kit->id))
				if ($env->exodus_mount ne $env->default_exodus_mount);
		}
		last;
	}

	unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION' ) {
		if (@deprecations && !envset("REPORTED_ENV_DEPRECATIONS")) {
			error({label => "DEPRECATIONS", colors => 'Y'},
				"Environment #C{%s} contains the following deprecation:\n[[- >>%s\n",
				$env->{file}, join("\n[[- >>",map {join("\n    ",split("\n",$_))} @deprecations)
			);
			$ENV{REPORTED_ENV_DEPRECATIONS}=1;
		}
		if (@config_warnings && !envset("REPORTED_ENV_CONFIG_WARNINGS")) {
			warning(
				"\nEnvironment #C{%s} contains the following configuration warnings:\n[[- >>%s\n",
				$env->{file}, join("\n[[- >>",map {join("\n    ",split("\n",$_))} @config_warnings)
			);
			$ENV{REPORTED_ENV_CONFIG_WARNINGS}=1
		}
	}

	bail(
		"Environment #C{%s} could not be loaded:\n[[- >>%s\n\n".
		"Please fix the above errors and try again.",
		$env->{file}, join("\n[[- >>",map {join("\n    ",split("\n",$_))} @errors)
	) if @errors;

	return $env
}

# }}}
# from_envvars -- builds a pseudo-env based on the current env vars - used for hooks callbacks {{{
sub from_envvars {
	my ($class,$top) = @_;

	bail "Can only assemble environment from environment variables in a kit hook callback"
		unless ($ENV{GENESIS_KIT_HOOK}||'') eq 'new' && in_callback();

	bug("No 'GENESIS_$_' found in enviornmental variables - cannot assemble environemnt!!")
		for (grep {! $ENV{'GENESIS_'.$_}} qw(ENVIRONMENT KIT_NAME KIT_VERSION ENVIRONMENT_PARAMS));

	my $env = $class->new(name => $ENV{GENESIS_ENVIRONMENT}, top => $top);
	$env->{is_from_envvars} =1;
	$env->{__params} = decode_json($ENV{GENESIS_ENVIRONMENT_PARAMS});

	# reconstitute our kit via top
	my $kit_name = $ENV{GENESIS_KIT_NAME};
	my $kit_version = $ENV{GENESIS_KIT_VERSION};
	$env->{kit} = $env->{top}->local_kit_version($kit_name, $kit_version)
		or bail "Unable to locate v$kit_version of `$kit_name` kit for '$env->{name}' environment.";
	$env->kit->apply_env_overrides(split(' ',$ENV{GENESIS_ENV_KIT_OVERRIDE_FILES}))
	  if defined $ENV{GENESIS_ENV_KIT_OVERRIDE_FILES};

	my $min_version = $ENV{GENESIS_MIN_VERSION} || scalar($env->lookup('genesis.min_version', ''));
	$min_version =~ s/^v//i;

	if ($min_version) {
		if ($Genesis::VERSION eq "(development)") {
			warning(
				"Environment `$env->{name}` requires Genesis v$min_version or higher.\n".
				"\n".
				"This version of Genesis is a development version and its feature ".
				"availability cannot be verified -- unexpected behaviour may occur."
			) unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION');
		} elsif (! new_enough($Genesis::VERSION, $min_version)) {
			bail(
				"Environment `$env->{name}` requires Genesis v$min_version or higher.  ".
				"You are currently using Genesis v$Genesis::VERSION."
			) unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION');
		}
	}
	$env->{__min_version} = $min_version || '0.0.0';

	# features
	$env->{'__features'} = [split(' ',$ENV{GENESIS_REQUESTED_FEATURES})]
		if $ENV{GENESIS_REQUESTED_FEATURES};

	# bosh and credhub env overrides
	if (envset 'GENESIS_USE_CREATE_ENV') {
		$env->{__params}{genesis}{use_create_env} = 'true';
		$env->{__params}{genesis}{min_version} ||= $min_version;
		$env->{__bosh} = Service::BOSH::CreateEnvProxy->new();
	} else {
		$env->{__bosh} = Service::BOSH::Director->from_environment();
	}
	$env->{__params}{genesis}{credhub_env} = $ENV{GENESIS_CREDHUB_EXODUS_SOURCE}
		if ($ENV{GENESIS_CREDHUB_EXODUS_SOURCE});

	# determine our vault and secret path
	$env->{__params}{genesis}{vault} = $ENV{GENESIS_ENV_VAULT_DESCRIPTOR} if $ENV{GENESIS_ENV_VAULT_DESCRIPTOR};
	for (qw(secrets_mount secrets_base secrets_slug exodus_mount exodus_base ci_mount ci_base root_ca_path)) {
		$env->{'__'.$_} = $env->{__params}{genesis}{$_} = $ENV{'GENESIS_'.uc($_)}
			unless eval "\$env->$_" eq $ENV{'GENESIS_'.uc($_)};
	}

	# Check for v2.7.0 features
	unless ($env->kit->feature_compatibility("2.7.0")) {
		bail(
			"Kit #M{%s} is not compatible with #C{secrets_mount} feature\n".
			"Please upgrade to a newer release or remove params.secrets_mount from #M{%s}",
			$env->kit->id, $env->{file}
		) if ($env->secrets_mount ne $env->default_secrets_mount);
		bail(
			"Kit #M{%s} is not compatible with #C{exodus_mount} feature\n".
			"Please upgrade to a newer release or remove params.exodus_mount from #M{%s}",
			$env->kit->id, $env->{file}
		) if ($env->exodus_mount ne $env->default_exodus_mount);
	}

	bail(
		"No vault specified or configured."
	) unless $env->vault;

	return $env;
}

# }}}
# create - create a new Genesis::Env object from user input {{{
sub create {
	my ($class,%opts) = @_;

	# validate call
	for (qw(name top kit)) {
		bug("No '$_' specified in call to Genesis::Env->create!!")
			unless $opts{$_};
	}

	my $env = $class->new(get_opts(\%opts, qw(name top kit)));
	my $create_env = $opts{'create-env'};

	# environment must not already exist...
	die "Environment file $env->{file} already exists.\n"
		if -f $env->path($env->{file});

	# Sanitize the vault descriptor, if present
	if ($opts{vault}) {
		unless (grep {$_ =~ /^https?:\/\/[^\/]+/} (split(' ',$opts{vault}))) {
			my $vault = (Service::Vault->find(name => $opts{vault}))[0];
			bail(
				"Cannot find a vault target with alias '$opts{vault}'"
			) unless $vault;
			$opts{vault} = $vault->build_descriptor();
		}
	}

	# Setup minimum parameters (normally from the env file) to be able to build
	# the env file.
	$env->{__params} = {
		genesis => {
			env => $opts{name},
			get_opts(\%opts, qw(vault secrets_path secrets_mount exodus_mount ci_mount root_ca_path credhub_env))}
	};

	my $bosh_env = ($ENV{GENESIS_BOSH_ENVIRONMENT}//'') eq '' ? undef : $ENV{GENESIS_BOSH_ENVIRONMENT};

	# The crazy-intricate create-env/bosh_env dance...
	if ($env->kit->feature_compatibility("2.8.0")) {
		# Kits that are explicitly compatible with 2.8.0 can specify if they
		# support or require create-env deployments.
		my $uce = $env->kit->metadata('use_create_env')||'';
		if ($uce eq 'yes') {
			bail(
				"Kit %s requires use of create-env, but --no-create-env option was specified",
				$env->kit->id
			) if defined($create_env) && !$create_env;
			bail(
				"Cannot specify a bosh environment for environments that use ".
				"create-env deployment method"
			) if defined($bosh_env);
			$env->{__params}{genesis}{use_create_env} = 1;
			$env->{__params}{genesis}{bosh_env} = '';
		} elsif ($uce eq 'no') {
			bail(
				"Kit %s cannot use create-env, but --create-env option was specified",
				$env->kit->id
			) if $create_env;
			$env->{__params}{genesis}{use_create_env} = 0;
			$env->{__params}{genesis}{bosh_env} = $bosh_env//$opts{name};
		} else {
			# Complicated state: the kit allows but does not require create-env.
			warning(
				"\nKit #M{%s} supports both bosh and create-env deployment.  No --create-env ".
				"option specified, so using bosh deployment method.",
				$env->kit->id
			) unless defined($create_env) || $bosh_env;
			bail(
				"Cannot specify a bosh environment for environments that use create-env deployment method."
			) if $create_env && $bosh_env;
			$env->{__params}{genesis}{use_create_env} = $create_env//0;
			$env->{__params}{genesis}{bosh_env} = $create_env ? '' : $bosh_env || $opts{name};
		}
	} else {
		bail(
			"Kit %s does not support the --[no-]create-env option",
			$env->kit->id
		) if defined($create_env);
		if ($env->is_bosh_director()) { # Prior to 2.8.0, only the bosh kit can use create_env.
			$env->{__params}{genesis}{use_create_env} = ($bosh_env) ? 0 : 1;
			$env->{__params}{genesis}{bosh_env} = $bosh_env || '';
		} else {
			$env->{__params}{genesis}{use_create_env} = 0;
			$env->{__params}{genesis}{bosh_env} = $bosh_env || $opts{name};
		}
	}

	# target vault and remove secrets that may already exist
	bail("No vault specified or configured.")
		unless $env->vault;

	my ($results) = $env->remove_secrets(all => 1, no_populate => 1);
	bail "Cannot continue with existing secrets for this environment"
		if ($results->{abort} || $results->{error});

	# credhub env overrides
	$env->{__params}{genesis}{credhub_env} = $ENV{GENESIS_CREDHUB_EXODUS_SOURCE}
		if ($ENV{GENESIS_CREDHUB_EXODUS_SOURCE});

	## initialize the environment
	$env->download_required_configs('new')
		unless $env->lookup('genesis.use_create_env','0');

	# Use the current version of Genesis as the minimum version if not specified
	$ENV{GENESIS_MIN_VERSION} ||= $Genesis::VERSION;

	bail(
		"Kit %s is not supported in Genesis %s (no hooks/new script).  Check for ".
		"a newer version of this kit.",
		$env->kit->id, $Genesis::VERSION
	) unless $env->has_hook('new');
	$env->run_hook('new');

	# Load the environment from the file to pick up hierarchy, and generate secrets
	$env = $class->load(name =>$env->name, top => $env->top);

	# Make environment file executable if requested
	if ($Genesis::RC->get('executable_environments')) {
		# append hashbang to the file
		my $file = $env->path($env->file);
		my $contents = slurp($file);
		unless ($contents =~ /^#!/) {
			$contents = "#!/usr/bin/env genesis\n".$contents;
			mkfile_or_fail($file, 0755, $contents);
		}
	}

	if (! $env->add_secrets(verbose=>1, import => 1)) {
		$env->remove_secrets(all => 1, 'no-prompt' => 1);
		unlink $env->file;
		return undef;
	}
	return $env;
}

# }}}
# exists - returns true if the given environment exists {{{
sub exists {
	my ($ref,%args) = @_;
	unless (ref($ref)) {
		# called on the class, need a instance
		my $err = _env_name_errors($args{name});
		bail("Bad environment name '%s': %s", $args{name}, $err) if $err;
		return undef unless $args{top};
		eval{ $ref = $ref->new(%args) };
		bug ("Failed to check existence of Genesis Environment: %s", $@) if $@;
		return undef unless $ref;
	}
	return -f $ref->path($ref->{file});
}

#}}}
# search_for_env_file - search for an environment file in known deployment root(s) {{{
sub search_for_env_file {
	my ($class, $env, $deployment) = @_;
	my $label = '@'.($env//'').($deployment ? ":$deployment" : '');
	my $director_target = defined($deployment) ? 'parent' : 'self';
	my %file_map;

	my ($root_labels, $root_map) = Genesis::deployment_roots_map(
		['@current', $ENV{GENESIS_ORIGINATING_DIR}],
		['@parent', Cwd::abs_path(Genesis::expand_path($ENV{GENESIS_ORIGINATING_DIR}.'/..'))],
	);
	$env = "*$env*" =~ s/\*\^//r =~ s/\$\*//r unless $env eq '*';
	my $given_deployment = $deployment//'';
	$deployment = "*$deployment*" =~ s/\*\^//r =~ s/\$\*//r if defined($deployment) && $deployment ne '*';

	for my $label (@$root_labels) {
		my $root = $root_map->{$label};
		my @deployments = map {s{/\.genesis/config$}{}r}
			glob("$root/".($deployment//'*')."/.genesis/config"); # Only include genesis repos
		next unless @deployments;
		if (defined $deployment) {
			$file_map{$label} = [map {glob("$_/$env.yml")} @deployments];
		} else {
			$file_map{$label} = [map {glob("$_/$env.yml")} grep { /\/bosh(-deployments)?$/ } @deployments];
		}
	}

	# Order the files by current directory, then by the order of the deployment
	# roots specified in the .genesis/config file, then bosh first, followed by
	# any other deployments in alphabetical order.
	my @files = ();
	for my $label ('@current', '@parent', @$root_labels) {
		if ($file_map{$label}) {
			my $is_bosh= qr{/bosh(-deployments)?/[^/]*\.yml$};
			push(@files,
				map {[$label, $_]}
				sort {
					($a =~ $is_bosh ? 0 : 1) <=> ($b =~ $is_bosh ? 0 : 1 ) || $a cmp $b
				} @{delete $file_map{$label}}
			);
		}
	}

	# Filter out files that aren't genesis environments
	@files = grep {
		my (undef, $name) = $_->[1] =~ m{(.*)/([^/]*)\.yml$};
		my $contents = slurp($_->[1]);
		($contents =~ m/^genesis:\s*$(\n  .*: .*$)*(\n  env: *$name)/m)
			&& ($contents !~ m/^name:/);
	} @files;

	bail("No environment files found matching #C{%s}", $label)
		unless @files;

		# Check if the deployment, if given, is an exact singular match
	if (scalar(@files) > 1 && $given_deployment =~ /^[\w-]+$/) {
		my @exact_matches = grep {$_->[1] =~ m{/$given_deployment(-deployments)?/}} @files;
		@files = @exact_matches	if (scalar(@exact_matches) == 1);
	}

	if (scalar(@files) > 1) {
		my $last_section = '';
		my @file_labels = map {
			my ($section, $label) = @$_;
			$label =~ m{(?:(.*?)/)?([^/]*)/([^/]*)\.yml};
			my $fmt_label = csprintf("#c{%s}/#m{%s}", $2, $3);
			if ($section ne $last_section) {
				$last_section = $section;
				my $fmt_section;
				my $target_path = $root_map->{$section} =~ s{^$ENV{HOME}/}{~/}r;
				my $is_current = $root_map->{$section} eq $ENV{GENESIS_ORIGINATING_DIR};
				my $flag = $ENV{GENESIS_NO_UTF8}
					? ''
					: $is_current ? "\x{1F4C2} " : "\x{1F4C1} ";
				if ($section eq '@current') {
					$fmt_section = csprintf("#Gu{%sCurrent Directory:} #Ki{%s}", $flag, $target_path);
				} elsif ($section eq '@parent') {
					$fmt_section = csprintf("%s#Yu{%sParent Directory:} #Ki{%s}", $flag, $target_path);
				} elsif ($section ne $root_map->{$section}) {
					my $is_current = $root_map->{$section} eq $ENV{GENESIS_ORIGINATING_DIR};
					$fmt_section = csprintf("#%su{%sDeployment Root '%s':} #Ki{%s}", $is_current ? 'g' : 'B', $flag, $section, $target_path);
				} else {
					$fmt_section = csprintf("#Bu{%sDeployment Root:} #Ki{%s}", $flag, $target_path);
				}
				("---$fmt_section---", [$fmt_label, csprintf("#C{%s}", humanize_path($root_map->{$section}, absolute => 1))."/$fmt_label"])
			} else {
				[$fmt_label, csprintf("#C{%s}", humanize_path($root_map->{$section}, absolute => 1))."/$fmt_label"]
			}
		} @files;

		bail(
			"Ambiguous environment name: #C{%s} matches multiple files:\n  - %s\n\n".
			"Please refine your match criteria.",
			$label, join("\n  - ", map {$_->[1]} grep {ref($_) eq 'ARRAY'} @file_labels)
		) unless in_controlling_terminal;

		my $selected_file = prompt_for_choice(
			csprintf(
				"Multiple environment files found matching #C{$label}:"
			),
			[@files, ['none']],
			$files[0],
			[ @file_labels, '---', csprintf('#R{%s of these - cancel}', scalar(@files) == 2 ? 'Neither' : "None") ],
			undef,
			"the desired environment file"
		);
		output({stderr=>1}, "");
		bail("No environment file selected.") if $selected_file->[0] eq 'none';
		$files[0] = $selected_file;
	}

	$files[0][1] =~ m{(?:(.*?)/)?([^/]*)/([^/]*)\.yml};
	my $deployment_root = $1;
	return ($deployment_root, $files[0][1]);
}
#}}}
#}}}

### Private Class Methods {{{

# _env_name_errors - ensure name is valid {{{
sub _env_name_errors {
	my ($name) = @_;

	my @errors = ();

	bug(
		"Environment name expected to be a string, got a %s",
		ref($name) || 'undefined value'
	) if !defined($name) || ref($name);

	push(@errors,"names must not be empty.\n")
		if !$name;

	push(@errors,"names must not contain whitespace.\n")
		if $name =~ m/\s/;

	push(@errors,"names can only contain lowercase letters, numbers, underscores and hyphens.\n")
		if $name !~ m/^[a-z0-9_-]+$/;

	push(@errors,"names must start with a (lowercase) letter.\n")
		if $name !~ m/^[a-z]/;

	push(@errors,"names must not end with a hyphen.\n")
		if $name =~ m/-$/;

	push(@errors,"names must not contain sequential hyphens (i.e. '--').\n")
		if $name =~ m/--/;

	return '' unless scalar(@errors);
	return join("\n  - ", '', @errors);
}

# }}}
# }}}

### Instance Methods {{{

# _genesis_inherits - return the list of inherited files (recursive) {{{
sub _genesis_inherits {
	my ($self,$file, @files) = @_;
	my ($out,$rc,$err) = run({stderr => 0},'cat "$1" | spruce merge --skip-eval --go-patch --multi-doc | spruce json', $self->path($file));
	bail "Error processing json in $file!:\n$err" if $rc;
	my @contents = map {load_json($_)} lines($out);

	my @new_files;
	for my $contents (@contents) {
		next unless $contents->{genesis}{inherits};
		bail(
			"$file specifies 'genesis.inherits', but it is not a list"
		) unless ref($contents->{genesis}{inherits}) eq 'ARRAY';

		for (@{$contents->{genesis}{inherits}}) {
			s/\.yml$//; # remove any .yml extensions
			my $cached_file;
			if ($ENV{PREVIOUS_ENV}) {
				$cached_file = ".genesis/cached/$ENV{PREVIOUS_ENV}/$_.yml";
				$cached_file = undef unless -f $self->path($cached_file);
			}
			my $inherited_file = $cached_file || "./$_.yml";
			next if grep {$_ eq $inherited_file} @files;
			push(@new_files, $self->_genesis_inherits($inherited_file,$file,@files,@new_files),$inherited_file);
		}
	}
	return(@new_files);
}

# }}}
# _init_yaml_file - build the initialization yaml file for merging and return the path to it {{{
sub _init_yaml_file {
	my $self       = shift;
	my $vault_path = $self->secrets_base =~ s#/?$##r; # backwards compatibility
	my $type       = $self->type;
	my $init_file  = $self->workpath("init.yml");


	if ($self->kit->feature_compatibility('2.6.13')) {
		mkfile_or_fail($init_file, 0644, <<EOF);
---
meta:
  vault: $vault_path
kit:
  features: []
exodus:  {}
genesis: {}
params:  {}
EOF
	} else {
		mkfile_or_fail($init_file, 0644, <<EOF);
---
meta:
  vault: $vault_path
kit:
  features: []
exodus: {}
genesis: {}
params:
  env:  (( grab genesis.env ))
  name: (( concat genesis.env || params.env "-$type" ))
EOF
	}
	return $init_file;
}

# }}}
# _cap_yaml_file - build the wrap-up yaml file for merging and return the path to it {{{
sub _cap_yaml_file {
	my $self       = shift;
	my $type       = $self->type;
	my $cap_file  = $self->workpath("fin.yml");

	my $now = strftime(EXODUS_TIME_FORMAT, gmtime());
	my $bosh_target = $self->use_create_env ? "~" : $self->bosh_env->{description};
	mkfile_or_fail($cap_file, 0644, <<EOF);
---
name: (( concat genesis.env "-$type" ))
genesis:
  env:           ${\(scalar $self->lookup(['genesis.env','params.env'], $self->name))}
  type:          $type
  vault_env:     ${\($self->env_vault_slug)}
  secrets_mount: ${\($self->secrets_mount)}
  secrets_path:  ${\($self->secrets_slug)}
  secrets_base:  ${\($self->secrets_base)}
  exodus_mount:  ${\($self->exodus_mount)}
  exodus_path:   ${\($self->exodus_slug)}
  exodus_base:   ${\($self->exodus_base)}
  ci_mount:      ${\($self->ci_mount)}${\(
  ($self->use_create_env || $self->bosh_env->{description} eq $self->name) ? "" :
  "\n  bosh_env:      $bosh_target")}${\(
	$self->is_ocfp
	? "\n  ocfp:          true".
		"\n  ocfp_env:      ".$self->ocfp_env .
		"\n  ocfp_config_mount:  ".$self->ocfp_config_mount
	: ''
	)}

exodus:
  version:        $Genesis::VERSION
  dated:          $now
  deployer:       (( grab \$CONCOURSE_USERNAME || \$USER || "unknown" ))
  kit_name:       ${\($self->kit->metadata->{name} || 'unknown')}
  kit_version:    ${\($self->kit->metadata->{version} || '0.0.0-rc0')}
  kit_is_dev:     ${\($self->kit->is_dev ? 'true' : 'false')}
  vault_base:     (( grab meta.vault ))
  bosh:           $bosh_target
  iaas:           ${\($self->iaas)}
  scale:          ${\($self->scale)}
  is_director:    ${\($self->is_bosh_director ? 'true' : 'false')}
  use_create_env: ${\($self->use_create_env ? 'true' : 'false')}
  features:       (( join "," kit.features ))
EOF
}

# }}}
# }}}

1;

=head1 NAME

Genesis::Env::Lifecycle

=head1 DESCRIPTION

This module contains the lifecycle management methods for Genesis environments,
including creation, loading, and validation of environment files.

=head1 CLASS METHODS

=head2 new(%opts)

Creates a raw Genesis::Env object. Do not call directly; use create() or load() instead.

=head2 load(%opts)

Returns a Genesis::Env object represented by an environment file.

=head2 from_envvars($top)

Builds a pseudo-env based on current environment variables. Used for hook callbacks.

=head2 create(%opts)

Creates a new Genesis::Env object from user input.

=head2 exists($ref, %args)

Returns true if the given environment exists.

=head2 search_for_env_file($env, $deployment)

Searches for an environment file in known deployment root(s).

=cut