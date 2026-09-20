package Genesis::Top;
use v5.20;
use warnings;

use base 'Genesis::Base';

use Genesis;
use Genesis qw/without_backtrace/;
use Scalar::Util ();
use Genesis::State;
use Genesis::Term qw/in_controlling_terminal csprintf decolorize/;
use Genesis::UI qw/prompt_for_boolean prompt_for_choice/;
use Genesis::Env;
use Genesis::Kit::Compiled;
use Genesis::Kit::Dev;
use Genesis::Kit::Provider;
use Service::Vault::Remote;
use Service::Vault::None;
use Genesis::Config;
use Genesis::Exit qw/CONFIG TEMPFAIL/;

use Cwd ();
use File::Path qw/rmtree/;
use Time::Piece;

# ---- Constants --------------------------------------------------------------
#
# Default name of the CI "control" branch -- the branch the environment
# files live on, and against which 'genesis deploy' validates its working
# state.  The deployment branches themselves are cut by
# 'genesis pipeline-apply', and 'genesis propagate' is what delivers
# control's commits onto them.  Captured as a constant (and a config key)
# so it can change without rippling through the codebase; not currently
# exposed to end users.
use constant DEFAULT_CONTROL_BRANCH  => 'control';
use constant DEFAULT_PR_PREFIX       => 'pr/';
use constant CI_PIPELINE_CONTROL_KEY => 'control'; # key in pipeline.branches{} hash for the control branch
use constant LATEST_CONFIG_VERSION   => 3;

### Config Section Delegation Registry {{{
# Modules may register themselves as handlers for specific top-level keys in
# .genesis/config.  Top.pm owns the core schema; registered handlers own their
# section's schema and validation.  This pattern is reusable for any future
# section beyond pipeline:.
#
#   Genesis::Top->register_config_section('pipeline', 'Genesis::CI::Compiler');
#
# The handler class must implement:
#   validate_config_section($data, $top)  # called after core schema validation

my %_config_section_handlers;

# register_config_section - register a module as owner of a config section {{{
sub register_config_section {
	my ($class, $section, $handler) = @_;
	$_config_section_handlers{$section} = $handler;
}

# }}}
# }}}
### Class Methods {{{

# _build - common construction logic for bare Genesis::Top object {{{
sub _build {
	my ($class, $root, %opts) = @_;
	my $self = bless({ root => Cwd::abs_path($root) }, $class);

	$ENV{GENESIS_ROOT}=$self->path();

	if ($opts{no_vault}) {
		debug "Top for $ENV{GENESIS_ROOT} requested with no vault support";
		$self->_set_memo('__vault', Service::Vault::None->new());
		return $self;
	}

	if ($opts{vault}) {
		# TODO: #ADDVAULT
		# if ($opts{env}) {
		#   $top->add_vault($opts{vault},$opts{env})
		# } else {
		debug ("Overriding vault %s with user specified %s for this session", $self->vault->name, $opts{vault})
			if $self->has_vault;
		$self->set_vault(target => $opts{vault}, session_only => 1);
		#}
	}

	return $self;
}

# }}}
# _set_vault_env - helper to set vault environment variables {{{
sub _set_vault_env {
	my ($self, %opts) = @_;

	if ($self->vault(silent => $opts{silent_vault_check}, no_vault => $opts{allow_no_vault})) {
		$ENV{GENESIS_TARGET_VAULT} = $ENV{SAFE_TARGET} = $self->vault->name;
	} elsif (!$ENV{GENESIS_NO_VAULT}) {
		debug {label => "WARNING"}, "Could not find any #M{safe} target.  This may cause consequences later on";
	}

	return $self;
}

# }}}
# new - returns a new Genesis::Top Repository object {{{
sub new {
	my $class = shift;

	# If args are odd, assume root wasn't given and default it to '.'
	my $root = @_ % 2 == 1 ? shift @_ : '.';
	my %opts = @_;

	# Validate that this is a proper Genesis repository
	bail("'$root' is not a Genesis deployment repository")
		unless $class->is_repo($root);

	# A tree written out of a commit is a reading surface rather than a
	# repository, so it carries no vault of its own and it cannot answer the
	# repository questions the configuration checks ask, such as whether an
	# enabled pipeline sits in a git checkout with a remote behind it.  The
	# caller that materialised it has already had those answers from the
	# repository it is running in, so both are skipped together here rather
	# than each being worked around at the call site.
	$opts{no_vault} = 1 if $opts{materialised_tree};

	# Build the base object
	my $self = $class->_build($root, %opts);
	$self->{__config_validated} = 1 if $opts{materialised_tree};

	# Initialize vault connection and set environment variables
	$self->_set_vault_env(%opts) unless $opts{materialised_tree};

	return $self;
}

# }}}
# create - create a new Genesis repository at the specified location {{{
sub create {
	my ($class, $path, $name, %opts) = @_;
	debug("creating a new Genesis deployments repository named '$name' at $path...");

	# TODO: $opts{kit} does get passed in, and future versions will only allow one kit type per deployment
	# Need to determine how this gets added to the configuration and how it impacts the current use of deployment type
	# Probably becomes deployment-name and kit becomes the type (or drop type and use kit)

	$name =~ s/-deployments?//;
	bail(
		"Invalid Genesis deployment repository name '$name'"
	) unless $name =~ m/^[a-z][a-z0-9_-]+$/;

	debug("generating a new Genesis repo, named $name");

	my $dir = $opts{directory} || "${name}".(
		$Genesis::RC->get('legacy_repo_suffix') ? "-deployments" : ""
	);
	bail(
		"Repository directory name must only contain alpha-numeric characters, periods, hyphens and underscores"
	) if $dir =~ /([^\w\.-])/;

	$path .= "/$dir";
	bail(
		"Cannot create new deployments repository `$dir': already exists!"
	) if -e $path;

	# Build the bare object (path doesn't exist yet, so can't use new())
	my $self = $class->_build($path, %opts);
	$self->mkdir(".genesis");

	$self->{__kit_provider} = $opts{kit_provider} || Genesis::Kit::Provider->init(%opts);
	# Override vault if specified (will be saved to config later)
	$self->{__vault} = Service::Vault::Remote->target($opts{vault}) if $opts{vault};
	my $kits_path = '';
	if ($kits_path = $opts{kits_path}) {
		$kits_path = expand_path($kits_path);
		my $rel_path = humanize_path($kits_path, base_dir => $self->path());
		if ($rel_path !~ m#^/#) {
			debug("Kit: using relative path $rel_path for kits path");
			$kits_path = $rel_path;
		} else {
			debug("Kit: using absolute path $kits_path for kits");
			my $home_parent_dir = dirname($ENV{HOME});
			$kits_path =~ s{^$ENV{HOME}/}{~/};
			$kits_path =~ s{^$home_parent_dir/}{~};
		}
	}

	eval { # to delete path if creation fails

		# Write new configuration - Set defaults
		$self->config->set('deployment_type',$name);
		$self->config->set('version', LATEST_CONFIG_VERSION);
		$self->config->set('creator_version', $Genesis::VERSION);
		$self->config->set('minimum_version', $Genesis::VERSION) unless $Genesis::VERSION eq '(development)';
		$self->config->set('manifest_store', 'exodus');
		$self->config->set('kits_path', $kits_path) if $kits_path;

		# Apply any config overrides from %opts
		for my $override (grep {exists $opts{$_}} qw(creator_version updater_version minimum_version manifest_store)) {
			if (defined $opts{$override}) {
				$self->config->set($override, $opts{$override});
			} else {
				$self->config->clear($override);
			}
		}

		# Set vault configuration if available
		if ($opts{no_vault} || $opts{skip_vault}) {
			# no_vault: test contexts only
			# skip_vault: user explicitly deferred via --skip-vault (legacy mode)
			bail("no_vault option can only be used in test contexts")
				if $opts{no_vault} && $ENV{GENESIS_COMMAND};
		} else {
			my %provider = (
				url       => $self->vault->url,
				insecure  => $self->vault->verify ? Genesis::Config::FALSE : Genesis::Config::TRUE,
				namespace => $self->vault->namespace,
				alias     => $self->vault->name
			);
			my $strongbox = $self->_strongbox_for_config($self->vault);
			$provider{strongbox} = $strongbox if defined($strongbox);
			$self->config->set('secrets_provider', \%provider);
		}

		$self->config->set('kit_provider', $self->kit_provider->config)
			unless ref($self->kit_provider) eq "Genesis::Kit::Provider::GenesisCommunity";

		$self->_validate_config;
		$self->config->save;
		if ($kits_path) {
			my $resolved_kits_path = $self->local_kits_path;
			mkdir_or_fail($resolved_kits_path) unless -d $resolved_kits_path;
		}

		$self->mkfile("README.md", # {{{
<<EOF);
$name deployments
==============================

This repository contains the YAML templates that make up a series of
$name BOSH deployments, using the format prescribed by the
[Genesis][1] utility. These deployments are based off of the
[$name-genesis-kit][2].

Environment Naming
------------------

Each environment managed by this repository will have its own
deployment file, e.g. `us-east-prod.yml`. However, in many cases,
it can be desirable to share param configurations, or kit configurations
across all of the environments, or specific subsets. Genesis supports
this by splitting environment names based on hyphens (`-`), and finding
files with common prefixes to include in the final manifest.

For example, let's look at a scenario where there are three environments
deployed by genesis: `us-west-prod.yml`, `us-east-prod.yml`, and `us-east-dev.yml`.
If there were configurations that should be shared by all environments,
they should go in `us.yml`. Configurations shared by `us-east-dev` and `us-east-prod`
would go in `us-east.yml`.

To see what files are currently in play for an environment, you can run
`genesis <environment-name>`

Quickstart
----------

To create a new environment (called `us-east-prod`):

    genesis create us-east-prod

To edit an environment file:

    genesis us-east-prod edit

To edit without opening the kit manual:

    genesis us-east-prod edit --no-manual

To use a specific editor command:

    genesis us-east-prod edit --editor "code --wait"
    genesis us-east-prod edit --editor "grep '<feature>'" # it doesn't have to be an editor

To build the full BOSH manifest for an environment:

    genesis us-east-prod manifest

... and then deploy it:

    genesis us-east-prod deploy

To deploy and automatically fix any missing requirements (secrets, stemcells, etc.):

    genesis us-east-prod deploy -F

The `-F` flag tells Genesis to automatically generate any missing secrets,
upload required stemcells, and handle other deployment prerequisites.

To rotate credentials for an environment:

    genesis us-east-prod rotate-secrets
    genesis us-east-prod deploy

To check for missing or invalid secrets:

    genesis us-east-prod check-secrets

To manage secrets provider for the environments in this repo, select from known safe targets:

    genesis secrets-provider -i

... or clear it to use safe's currently targeted vault:

    genesis secrets-provider --clear

By default, the provider for kits is the Genesis Community at
https://github.com/genesis-community, but you can set this to another
provider url via the `genesis kit-provider` command:

    genesis kit-provider https://github.mycorp.com/mygenesiskits

This requires that url to provide releases in the same manner as GitHub does.
You can see the current kit provider by calling it with no argument, or revert
back to default with the `--default` option.

To check for kit updates and download new versions:

    genesis list-kits --updates
    genesis fetch-kit $name [version]  # omitting version downloads the latest

To update an environment to use a new kit version:

    # Edit the environment file to specify the new kit version
    vi us-east-prod.yml

    # Then deploy the updated environment
    genesis us-east-prod deploy

Environment Management
----------------------

Genesis provides several commands for managing environments:

- `genesis <env> info` - Show environment details and configuration
- `genesis <env> check` - Validate environment configuration and run checks
- `genesis <env> edit` - Edit the environment file in your default editor
- `genesis <env> deploy` - Deploy the environment to BOSH
- `genesis <env> deploy -F` - Deploy with automatic prerequisite handling
- `genesis <env> secrets` - List available secrets for the environment
- `genesis <env> check-secrets` - Check for missing certificates and credentials
- `genesis <env> add-secrets` - Generate missing certificates and credentials
- `genesis <env> rotate-secrets` - Regenerate secrets for the environment
- `genesis <env> remove-secrets` - Remove certificates and credentials
- `genesis <env> bosh <cmd>` - Run BOSH commands against the environment
- `genesis <env> credhub <cmd>` - Run Credhub commands against the environment
- `genesis <env> do <task>` - Run kit-specific addon tasks
- `genesis <env> logs` - Fetch logs from the BOSH director
- `genesis <env> terminate` - Terminate the environment on the BOSH director

Match-Mode Environment Selection
--------------------------------

Genesis supports match-mode selection using @-notation, which allows you to
work with environments without being in their repository directory. This is
especially useful when managing multiple repositories.

To set up match-mode selection, configure deployment roots in your global
Genesis configuration file `\$HOME/.genesis/config`:

    ---
    deployment_roots_map:
      ops: /path/to/root/of/ops/deployments
      test: /path/to/root/of/test/deployments

This allows you to run commands like:

  See the contents without changin the directory:
    genesis \@dev:cf edit --editor "cat"

  Not specifying the type defaults to bosh kit
    genesis \@prod info

  Targets the vault repository under the deployment roots map:
    genesis \@:v secrets-provider --interactive

The \@-notation supports several patterns:

- `\@<env-pattern>` - Match bosh environments by name pattern
- `\@<env-pattern>:<deployment-pattern>` - Match environments within specific deployment types
- `\@*:<deployment-pattern>` - Match any environment within deployment types matching the pattern
- `\@:<deployment-pattern>` - Match the repo within the specified deployment type

The patterns can be incomplete glob patterns, and can additonally use `^` and
`\$` to anchor the start and end of the name. If in a controlling terminal, you
will be presented with a list of matching environments to choose from if the
match is not unique.

The `--editor` option is particularly useful with match-mode, as it allows you
to interact with the environment files without changing directories:

    genesis \@dev:cf edit --editor "code --wait --new-window"
    genesis \@prod:vault edit --editor "emacs"
    genesis \@aws-east1:jumpbox edit # Defaults to your \$EDITOR

Deployment Options
------------------

The `genesis deploy` command supports several useful flags:

- `-F` - Automatically fix missing requirements (secrets, stemcells, releases)
- `-y` - Skip confirmation prompts and deploy automatically
- `-n` - Dry-run mode (show what would be deployed without actually deploying)
- `--redact` - Show redacted manifest during deployment process

For example, to deploy an environment with automatic fixes and no prompts:

    genesis us-east-prod deploy -F -y

Secrets Management
------------------

Genesis integrates with Vault for secrets management. Each environment
can have its own secrets path, and Genesis provides tools for:

- Generating and rotating secrets automatically
- Validating secret requirements
- Supporting both Vault and Credhub backends
- Tracking secret changes and dependencies

To configure the secrets provider, use the interactive selection:

    genesis secrets-provider -i

This will show you a list of known safe targets and allow you to select
the appropriate one for your environment.

To clear the secrets provider and use safe's currently targeted vault:

    genesis secrets-provider --clear

This resets the secrets provider to use whatever vault `safe` is currently
targeting, which is useful when switching between different vault instances
or when you want to use your default safe configuration.

Kit Features
------------

The $name kit supports various features that can be enabled in your
environment files. Common features include:

- IaaS-specific configurations (aws, azure, gcp, vsphere, etc.)
- Scaling options (small-footprint, ha, etc.)
- Integration features (external databases, load balancers, etc.)

Check the kit documentation for a complete list of available features
and their requirements:

    genesis kit-manual $name

Repository Structure
--------------------

Most of the deployment configuration happens at the base level.
Environment YAML files and shared YAML files are stored here.

The `.genesis/` directory contains:

- `config` - Repository configuration and metadata
- `kits/` - Downloaded and compiled kits
- `manifests/` - Deployed manifest archives (if enabled)
- `bin/` - Embedded Genesis binary for CI/CD (if present)

Environment files can be organized hierarchically using hyphens in names,
allowing shared configuration across related environments.

Development and Testing
-----------------------

For kit development, you can use a local development kit:

    genesis create-kit --dev --name $name

This creates a `dev/` directory with an uncompiled kit for testing
changes before release.

You can also decompile an existing kit for modification:

    genesis decompile-kit $name/version

To build a distributable kit from your dev directory:

    genesis build-kit

Information and Debugging
-------------------------

Genesis provides several commands for inspecting environments:

- `genesis <env> yamls` - List YAML files used for the environment
- `genesis <env> lookup <key>` - Look up values from environment files or manifests
- `genesis <env> vault-paths` - List vault paths used by the environment
- `genesis environments` - List all environments in known repositories

Kit Management
--------------

Genesis provides commands for managing kits:

- `genesis list-kits` - List available local kits
- `genesis list-kits --remote` - List available remote kits
- `genesis list-kits --updates` - Check for kit updates
- `genesis fetch-kit <name>` - Download a kit from the provider
- `genesis compare-kits` - Compare two kit versions

Getting Help
------------

Genesis provides comprehensive built-in help for all commands and options:

### General Help

Get an overview of all available commands:

    genesis help

Show the Genesis version and build information:

    genesis version

### Command-Specific Help

Get detailed help for any command by adding `help` after the command:

    genesis help <command>

This is synonymous with `genesis <command> --help` and provides detailed
information about the command's usage, options, and examples.

To get a list of available commands, you can use:

    genesis help

### Addon Task Help

List available addon tasks for an environment:

    genesis <env> do list

Get help for a specific addon task:

    genesis <env> do <task> --help

### Command Synopsis

Most commands support `--help` or `-h` flags for quick reference:

    genesis deploy --help
    genesis secrets --help
    genesis edit --help

The help system shows:
- Command syntax and usage patterns
- Available options and flags
- Examples of common usage scenarios
- Related commands and cross-references

### Kit Documentation

Access kit-specific documentation and manual pages:

		genesis kit-manual <kit-name>

This opens the kit's documentation in your default pager, showing:
- Available features and their descriptions
- Configuration parameters and their usage
- Examples and best practices

This file is opened automatically when you run `genesis <env> edit` and placed
in a side-by-side split with the environment file for easy reference, if you're
\$EDITOR is `code`, `emacs`, or `vim` (gvim, mvim, nvim are also supported).

Helpful Links
-------------

- [$name Genesis Kit][2] - Kit documentation, features, and parameters
- [Genesis Documentation][3] - Complete Genesis user guide
- [Genesis Community][4] - Community kits and support

[1]: https://github.com/genesis-community/genesis
[2]: https://github.com/genesis-community/$name-genesis-kit
[3]: https://github.com/genesis-community/genesis/tree/master/docs
[4]: https://github.com/genesis-community
EOF

# }}}

	};
	if (my $err = $@) {
		debug("removing incomplete Genesis deployments repository at #C{$path} due to failed creation");
		rmtree $path;
		die $err;
	}

	# Initialize vault connection and set environment variables
	$self->_set_vault_env(%opts);

	return $self;
}

# }}}
# search_for_repo_path - search for an deployment repository path in known deployment root(s) {{{
sub search_for_repo_path {
	my ($class, $deployment, %opts) = @_;
	my $label = "\@:$deployment";

	# Process and validate options
	my $return_all = delete($opts{all_paths}) // 0;
	bug(
		"Invalid option specified to search_for_repo_path: %s",
		join(", ", keys %opts)
	) if scalar(keys %opts) > 0;

	my ($root_labels, $root_map) = Genesis::deployment_roots_map(
		['@current', $ENV{GENESIS_ORIGINATING_DIR}],
		['@parent', Cwd::abs_path(Genesis::expand_path($ENV{GENESIS_ORIGINATING_DIR}.'/..'))],
	);

	$deployment = "*$deployment*" =~ s/\*\^//r =~ s/\$\*//r if defined($deployment) && $deployment ne '*';

	my %path_map = ();
	for my $root_label (@$root_labels) {
		my $root = $root_map->{$root_label};
		my @deployments = map {s{/\.genesis/config$}{}r} grep {-f $_}
			glob("$root/".($deployment//'*')."/.genesis/config"); # Only include genesis repos
		next unless @deployments;
		$path_map{$root_label} = [@deployments];
	}

	# Order the files by current directory, then by the order of the deployment
	# roots specified in the .genesis/config file, then bosh first, followed by
	# any other deployments in alphabetical order.
	my @paths = ();
	for my $root_label (uniq ('@current', '@parent', @$root_labels)) {
		if ($path_map{$root_label}) {
			my $is_bosh= qr{/bosh(-deployments)?/?$};
			push(@paths,
				map {[$root_label, $_]}
				sort {
					($a =~ $is_bosh ? 0 : 1) <=> ($b =~ $is_bosh ? 0 : 1 ) || $a cmp $b
				} @{$path_map{$root_label}}
			);
		}
	}

	if (!@paths) {
		bail("No deployment repositories found matching #C{%s}", $label);

	} elsif (scalar(@paths) > 1) {
		my $last_section = '';
		my @path_labels = map {
			my ($section, $path) = @$_;
			$path =~ m{(?:(.*?)/)?([^/]*/?)$};
			my $fmt_label = csprintf("#c{%s}/", $2);
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
					$fmt_section = csprintf("#Yu{%sParent Directory:} #Ki{%s}", $flag, $target_path);
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
		} @paths;
		bail(
			"Ambiguous deployment repository name: #C{%s} matches multiple paths:\n  -#\@{_}%s\n\n".
			"Please refine your match criteria.",
			$label, join("\n  -#\@{_}", map {$_->[1]} grep {ref($_) eq 'ARRAY'} @path_labels)
		) unless in_controlling_terminal || $return_all;

		return @paths if $return_all;

		my $selected_path = prompt_for_choice(
			csprintf(
				"Multiple deployment repositories found matching #C{$label}:"
			),
			[@paths, ['none']],
			$paths[0],
			[ @path_labels, '---', csprintf('#R{%s of these - cancel}', scalar(@paths) == 2 ? 'Neither' : "None") ],
			undef,
			"the desired deployment repository path"
		);
		output({stderr=>1}, "");
		bail("No deployment repository path selected.") if $selected_path->[0] eq 'none';
		$paths[0] = $selected_path;
	}
	$paths[0][1] =~ m{(?:(.*?)/)?([^/]+)/?$};
	my $deployment_root = $1;
	return ($deployment_root, $paths[0][1]);
}
# }}}
# is_repo - returns true if the specified path is a Genesis deployment repository {{{
sub is_repo {
	my ($class, $path) = @_;
	return -d "$path/.genesis" && -f "$path/.genesis/config" && slurp("$path/.genesis/config") =~ /deployment_type:/;
}
# }}}

### Instance Methods

# Kit Provider handling
# kit_provider - return the kit provider for the Top object {{{
sub kit_provider {
	my $ref = $_[0]->_memoize(sub {
		my ($self) = @_;
		return Genesis::Kit::Provider->new(%{$self->config->get("kit_provider", {})});
	});
	return $ref;
}

# }}}
# set_kit_provider - set the kit provider {{{
sub set_kit_provider {

	my ($self, %opts) = @_;
	my $new_provider;

	# TODO: If needed, provide an interactive wizard to enter provider type and details
	#	if ($opts{interactive}) {
	#		$new_provider = Genesis::Kit::Provider->target(undef);
	#	} else ...
	eval {
		info {pending => 1}, "\nSetting up new kit provider...";
		$new_provider = Genesis::Kit::Provider->init(%opts);
		info "done.";
		info {pending => 1}, "Writing configuration...";
		$self->{__kit_provider} = $new_provider;
		if (ref($self->kit_provider) eq "Genesis::Kit::Provider::GenesisCommunity") {
			$self->config->clear('kit_provider');
		} else {
			$self->config->set('kit_provider', $self->kit_provider->config);
		}
		$self->config->set('updater_version', $Genesis::VERSION) if $self->config->exists();
		$self->_validate_config;
		$self->config->save;
		info "done.";
	};
	return $@;
}

# }}}
# kit_provider_info - return that status of the kit provider {{{
sub kit_provider_info {
	my $self = shift;
	$self->kit_provider->status(@_);
}

# }}}

# Secrets provider handling
# vault - initialize connectivity to the vault specified by the secrets provider {{{
sub vault {
	my ($self, %opts) = @_;
	my $ref = $self->_memoize(sub {
		return Service::Vault::None->new() if ($ENV{GENESIS_NO_VAULT});
		my ($self) = @_;
		if (in_callback && $ENV{GENESIS_TARGET_VAULT}) {
			return Service::Vault->rebind();
		} elsif ($self->has_vault) {
			my $namespace =  $self->config->get("secrets_provider.namespace");
			my $strongbox = $self->config->get("secrets_provider.strongbox");
			my %attach_opts = (
				url      => $self->config->get("secrets_provider.url"),
				verify   => $self->config->get("secrets_provider.insecure") ? 0 : 1,
				silent   => $opts{silent},
				no_vault => $opts{no_vault}
			);
			$attach_opts{namespace} = $namespace if defined($namespace);
			$attach_opts{strongbox} = ($strongbox ? 1: 0) if defined($strongbox);
			my $vault = Service::Vault::Remote->attach(%attach_opts);
			$vault = Service::Vault::None->new() if (!$vault && $opts{no_vault});
			return $vault;
		} else {
			my $vault = Service::Vault::default;
			$vault->connect_and_validate($opts{silent})->ref_by_name() if $vault;
			return $vault;
		}
	});
	return $ref;
}

# }}}
# repo_vault - returns the repository vault if specified in config, or env vault otherwise {{{
# TODO: examine how this can work with multiple vaults (#ADDVAULT)
sub repo_vault {
	my $self = shift;
	return Service::Vault::default unless $self->has_vault();
	my $namespace = $self->config->get("secrets_provider.namespace");
	my $strongbox = $self->config->get("secrets_provider.strongbox");
	my %opts = (
		url    => $self->config->get("secrets_provider.url"),
		verify => $self->config->get("secrets_provider.insecure") ? 0 : 1,
	);
	$opts{namespace} = $namespace if defined($namespace);
	$opts{strongbox} = ($strongbox ? 1 : 0) if defined($strongbox);
	return Service::Vault::Remote->attach(%opts);
}

# }}}
# has_vault - returns true if the configuration has a vault defined {{{
sub has_vault {
	my ($self) = @_;
	defined($self->config->get("secrets_provider")) && ref($self->config->get("secrets_provider")) eq 'HASH' && scalar(keys %{$self->config->get("secrets_provider")}) > 0;
}

# }}}
# _strongbox_for_config - the strongbox value to record for a vault {{{
sub _strongbox_for_config {
	my ($self, $vault) = @_;

	# An unstated flag is not a statement that Strongbox is off.  safe omits
	# the key for whichever state is its own default, and that default
	# flipped, so a vault object with nothing to say must not overwrite a
	# value that was recorded here when something did know.
	return $self->config->get('secrets_provider.strongbox')
		unless defined($vault->strongbox);

	return $vault->strongbox ? Genesis::Config::TRUE : Genesis::Config::FALSE;
}

# }}}
# set_vault - set the secret provider to the specified vault. {{{
sub set_vault {
	my ($self,%opts) = @_;
	my $new_vault;
	if ($opts{interactive}) {
		my $current_vault = $self->config->get("secrets_provider");
		if ($current_vault) {
			$current_vault = (Service::Vault->find_by_target($current_vault->{url}))[0];
		}
		$new_vault = Service::Vault::Remote->target(undef, default_vault => $current_vault);
	} elsif (exists($opts{target})) {
		# TODO: allow the creation of a new safe target by parsing target string (#BETTERVAULTTARGET)
		my @candidates = Service::Vault->find_by_target($opts{target});
		return "#R{[Error]} No vault found that matches $opts{target}." unless @candidates;
		return "#R{[Error]} Target $opts{target} has URL that is not unique across the known vaults on this system."
			if scalar(@candidates) > 1;
		$new_vault = $candidates[0];
	} elsif ($opts{clear}) {
		$new_vault = undef;
	} elsif (Scalar::Util::blessed($opts{vault})
	         && $opts{vault}->isa('Service::Vault')) {
		# Any vault of the family, because a local vault serves a read as a
		# remote one does and the two are siblings rather than one being a
		# kind of the other.  Service::Vault::None is not one of them, and
		# it falls through to the refusal below, which is what it is for.
		$new_vault = $opts{vault}
	} else {
		bug "Invalid call to Genesis::Top->set_vault"
	}
	$self->{__vault} = $new_vault;
	return if $opts{session_only};

	if ($new_vault) {
		my %provider = (
			url       => $new_vault->url,
			insecure  => $new_vault->verify ? Genesis::Config::FALSE : Genesis::Config::TRUE,
			namespace => $new_vault->namespace,
			alias     => $new_vault->name
		);
		my $strongbox = $self->_strongbox_for_config($new_vault);
		$provider{strongbox} = $strongbox if defined($strongbox);
		$self->config->set('secrets_provider', \%provider);
		$self->config->set('updater_version', $Genesis::VERSION) if $self->config->exists();
		$self->_validate_config;
		$self->config->save;
	} else {
		$self->config->clear('secrets_provider',1);
	}
	return;
}

# }}}
# add_vault - TODO: #ADDVAULT add ability to support multiple vaults, default, base and per env {{{
sub add_vault {
}
# }}}
# vault_status - get the status for the associated secret-provider vault {{{
sub vault_status {
	my ($self) = @_;
	return () unless $self->has_vault;

	my $info = $self->config->get("secrets_provider");
	$info->{security} = ($info->{url} =~ /^https/)
		? ($info->{insecure} ? "#Y{(noverify)}" : "")
		: "#Y{(insecure)}";

	my @candidates = Service::Vault->find(url => $info->{url});
	if (! scalar(@candidates)) {
		$info->{alias_error} = "No alias for this URL found on local system";
		$info->{status} = qq(Run 'safe target "$info->{url}" "}#Ri{<alias>}#R{") . ($info->{insecure} ? " -k" : "") . "' to create an alias for this URL";
		return %$info;
	}

	if (scalar(@candidates) > 1) {
		$info->{alias_error} = "Multiple aliases for this URL found on local system";
		$info->{status} = "Remove all but one of the following safe targets: ".join(", ", map {$_->{name}} @candidates);
		return %$info;
	}

	my $vault = $candidates[0];
	local $ENV{QUIET} = 1;
	$info->{alias} = $vault->name;
	$info->{status} = $vault->status;
	return %$info;
}

# }}}
# get_ancestral_vault {{{
sub get_ancestral_vault {
	my ($self, $env) = @_;
	return Genesis::Env->new(name=>$env, top=>$self)->get_ancestral_vault();
}

sub reset_vault {
	my $self = shift;
	my $no_vault = defined($_[0]) && $_[0] eq 'no-vault';

	$self->_clear_memo('__vault');
	$ENV{GENESIS_NO_VAULT}=($no_vault ? '1' : '')
}

# }}}

# Repository management
# link_dev_kit - build a symbolic link to the specified path as a dev kit {{{
sub link_dev_kit {
	my ($self, $path) = @_;
	debug("linking dev kit '$path'");
	my $abs = Cwd::abs_path($path)
		or die "Unable to locate $path from ".Cwd::getcwd."\n";

	my $dev = $self->path('dev');
	unlink($dev) if -l $dev; # overwrite the link
	die "dev/ already exists, and is not a symbolic link\n"
		if -e $dev;

	symlink_or_fail($abs, $dev);
	return $self;
}

# }}}
# embed - embed the current version of genesis in the repository for CI pipeline usage {{{
sub embed {
	my ($self, $bin) = @_;
	debug("embedding `genesis' binary installed at $bin...");

	$self->mkdir(".genesis/bin");
	copy_or_fail(Cwd::abs_path($bin), $self->path(".genesis/bin/genesis"));
	chmod_or_fail(0755, $self->path(".genesis/bin/genesis"));
	return 1;
}

# }}}
# path - return the path of the repo, or absolute path of the specified relative path {{{
sub path {
	my ($self, $relative) = @_;
	return $relative ? "$self->{root}/$relative"
	                 :  $self->{root};
}

# }}}
# mkfile - make a file with the given content relative to the root of the repo {{{
sub mkfile {
	my ($self, $file, @rest) = @_;
	mkfile_or_fail($self->path($file), @rest);
}

# }}}
# mkdir - make a directory relative to the root of the repo {{{
sub mkdir {
	my ($self, $dir, @rest) = @_;
	mkdir_or_fail($self->path($dir), @rest);
}

# }}}
# config - read the configuration of the repo {{{
sub config {
	my ($self) = @_;
	return $self->{__config} if defined($self->{__config});
	my $ref = $self->_memoize(sub {
		my ($self) = @_;
		return Genesis::Config->new($self->path(".genesis/config"));
	});
	$self->_validate_config if -f $self->path(".genesis/config");
	return $ref;
}

# }}}
# type - return the deployment type {{{
sub type {
	my ($self) = @_;
	return $self->config->get("deployment_type");
}

# }}}
# deployment_slug_for - the deployment slug for an environment name {{{
#
# <env>/<type>, the one identity the branch, the vault path, and the BOSH
# deployment name all render (D66, D71).  The argument is a name as a
# string and never an environment object, so that a caller holding only a
# name composes the slug without loading one, which is what pipeline-apply
# creating branches and pipeline-status listing them both do.
sub deployment_slug_for {
	my ($self, $env_name) = @_;
	bug(
		"deployment_slug_for expects an environment name, got a %s",
		ref($env_name)
	) if ref($env_name);
	bug("deployment_slug_for called without an environment name")
		unless defined($env_name) && length($env_name);
	return sprintf('%s/%s', $env_name, $self->type);
}

# }}}
# branch_for - the deployment branch for an environment name {{{
#
# The deployment branch is the slug, with no decoration of its own (D66).
sub branch_for {
	my ($self, $env_name) = @_;
	return $self->deployment_slug_for($env_name);
}

# }}}
# pr_branch_for - the pull request branch for an environment name {{{
#
# The prefix joined onto the slug, with no second argument, so the branch
# reads pr/qa/bosh under the defaults (D19, D66, D71).  The join can take
# a name that is already the control branch or that a deployment branch
# already owns, and the second of those needs an environment whose name
# is the prefix followed by another environment's name, as with the
# prefix pr- and the environments lab and pr-lab.  Both the prefix and
# the type append, so the type cancels on both sides and the comparison
# is against the composed branch names.  Refusing the collision belongs
# here, in the one place a pull request branch is named, rather than in
# each caller.
#
# The names to compare against are the caller's to pass where it already
# holds them.  pipeline_env_names memoises nothing and builds the whole
# topology, which walks every environment file, so a run asking about each
# pull request environment in turn paid for one entire topology per ask.
# Every such caller already has one in hand and passes its environment
# names through envs.
sub pr_branch_for {
	my ($self, $env_name, %opts) = @_;
	my $branch = $self->pr_prefix . $self->deployment_slug_for($env_name);
	my @envs   = $opts{envs} ? @{$opts{envs}} : $self->pipeline_env_names;

	bail(
		{exitcode => CONFIG},
		"The pull request branch for #C{%s} would be #R{%s}, which is the ".
		"deployment branch of the environment #C{%s}.\n".
		"Change #C{pipeline.source_control.pr_prefix} to a prefix no ".
		"environment name begins with.",
		$env_name, $branch, $_
	) for grep {$branch eq $self->branch_for($_)} @envs;

	bail(
		{exitcode => CONFIG},
		"The pull request branch for #C{%s} would be #R{%s}, which is the ".
		"control branch.\n".
		"Change #C{pipeline.source_control.pr_prefix} so the two names ".
		"cannot meet.",
		$env_name, $branch
	) if $branch eq $self->control_branch;

	return $branch;
}

# }}}
# pipeline_enabled - whether this repository declares a pipeline {{{
#
# Reads pipeline.enabled and nothing else, under D70.  It replaces
# ci_configured and ci_enabled, which are removed rather than kept as a
# guard beside the provider read, because pairing the two is what let a
# repository with no pipeline and one with a manual pipeline read alike.
sub pipeline_enabled {
	my ($self) = @_;
	return $self->config->get('pipeline.enabled') ? 1 : 0;
}

# }}}
# pipeline_provider_type - the pipeline's provider, or undef when there is none {{{
#
# Checks pipeline_enabled first and answers undef when the pipeline is not
# enabled, so one read answers both questions and no call site needs a
# guard beside it.  The default is manual, under D15, so pipeline.enabled
# on its own is a manual pipeline rather than a half-configured one.  The
# name is qualified because Genesis classifies providers of several kinds
# (D64, D70).
sub pipeline_provider_type {
	my ($self) = @_;
	return undef unless $self->pipeline_enabled;
	return $self->config->get('pipeline.provider.type', 'manual') // 'manual';
}

# }}}
# manual_pipeline - whether the enabled pipeline is the manual one {{{
#
# True only when pipeline_provider_type is defined and equals manual, so
# the check stays out of every call site (D70).
sub manual_pipeline {
	my ($self) = @_;
	my $type = $self->pipeline_provider_type;
	return (defined($type) && $type eq 'manual') ? 1 : 0;
}

# }}}
# recreate_on_deploy - when this repository recreates VMs on a deploy {{{
#
# D101: never, redeploy-only, or always, repository-wide rather than per
# environment, because a key that changes how a deployment progresses has to
# be uniform or the earlier environments stop rehearsing the later ones.  It
# has no capability behind it, since --recreate is a BOSH flag and not a
# provider feature.
sub recreate_on_deploy {
	my ($self) = @_;
	return $self->config->get('pipeline.recreate_on_deploy') // 'never';
}

# }}}
# control_branch - the name of the branch that is control {{{
#
# The one reader of pipeline.source_control.control_branch, under D19.
# The constant is its default and nothing more, so a site that reads the
# constant instead of this accessor contradicts the design.
sub control_branch {
	my ($self) = @_;
	return $self->config->get(
		'pipeline.source_control.control_branch', DEFAULT_CONTROL_BRANCH
	);
}

# }}}
# control_requires_pr - the one reader of the key D45 derives from {{{
#
# It decides the branch protection pipeline-apply applies to control, and
# under D45 it also decides whether a command that commits on control
# expects a feature branch instead.  One key, two readings of it, so a
# site that turns the protection on never has to find a second switch.
sub control_requires_pr {
	my ($self) = @_;
	return $self->config->get('pipeline.source_control.control_requires_pr', 0)
		? 1 : 0;
}

# }}}
# pr_prefix - the prefix every pull request branch carries {{{
#
# The one reader of pipeline.source_control.pr_prefix, defaulting to
# 'pr/', under D19.  It is joined onto the deployment slug to name the
# pull request branch.
sub pr_prefix {
	my ($self) = @_;
	return $self->config->get(
		'pipeline.source_control.pr_prefix', DEFAULT_PR_PREFIX
	);
}

# }}}
# source_control_remote - the remote the pipeline derives its url from {{{
#
# The public reader over the resolved block, so a caller asks for the one
# value it wants instead of reaching into a private hash.  Precedence is
# explicit over derived over default, under D29, and the derivation and
# every refusal live in _source_control, which resolves once and keeps
# its answer.
sub source_control_remote {
	my ($self) = @_;
	return $self->_source_control->{remote};
}

# }}}
# source_control_uri - the url a pipeline task clones {{{
sub source_control_uri {
	my ($self) = @_;
	return $self->_source_control->{uri};
}

# }}}
# source_control_repository - the owner/repo the GitHub API targets {{{
sub source_control_repository {
	my ($self) = @_;
	return $self->_source_control->{repository};
}

# }}}
# source_control_resolved - every source-control value and its tier {{{
#
# What pipeline-describe prints, so an override that has drifted away from
# what git says is visible rather than silent, under D29.  A value is
# explicit where the operator wrote the key, derived where git answered for
# it, unset where a derivation was never run, and default where the key
# takes no derivation at all.
#
# is_set decides the explicit tier rather than get, the way
# _validate_capability_gates does, because the schema fills control_branch
# and pr_prefix in for every repository and a filled default is the
# schema's answer rather than anybody's choice.
sub source_control_resolved {
	my ($self) = @_;

	my $sc = $self->_source_control;
	my %derived = map {($_ => 1)} qw/remote uri repository/;

	my @rows;
	for my $key (qw/remote uri repository control_branch pr_prefix/) {
		my $value = $sc->{$key};
		push @rows, {
			key   => $key,
			# A value that never resolved shows as (none) rather than as a
			# blank column the reader has to interpret.
			value => $value // '(none)',
			# A derived key with no value was never derived: under D29 the
			# url is asked of git only where the repository has to come out
			# of it, so calling that row derived would tell the reader git
			# answered when git was never asked.
			source => $self->config->is_set("pipeline.source_control.$key")
				? 'explicit'
				: $derived{$key}
					? (defined $value ? 'derived' : 'unset')
					: 'default',
		};
	}

	return \@rows;
}

# }}}
# _pipeline_exodus_mount - the one exodus mount the pipeline shares {{{
#
# D103 puts the applied record at <exodus mount>_pipelines/<type>, so a
# pipeline whose environments kept separate mounts would have no single
# home for it.  Configuration load already refuses a repository whose
# environments resolve the mount differently, in
# _validate_one_exodus_mount, so reading it from the first pipeline
# environment through the merged hierarchy is enough, and exodus_mount
# normalises to a trailing slash.
#
# The pipeline's environments are asked first and the root's environment
# files second, because the record has to stay readable when
# pipeline.enabled reads false.  pipeline_env_names answers nothing at all
# for a disabled pipeline, and D64's disowned repository is exactly one
# whose key is off while the record still stands, so an address that only
# a live pipeline could spell would put that record out of reach of the
# refusal that exists to find it.  The mount is a repository-wide fact
# either way, and configuration load refuses a repository whose
# environments disagree about it.
sub _pipeline_exodus_mount {
	my ($self) = @_;
	return $self->_memoize(sub {
		my ($self) = @_;
		my ($first) = ($self->pipeline_env_names, $self->_env_file_names);
		bail(
			{exitcode => CONFIG},
			"This repository has a pipeline but no environment to resolve ".
			"#C{genesis.exodus_mount} from, so the pipeline's own record ".
			"has no address.\n".
			"Add an environment file, or disable the pipeline."
		) unless $first;
		return Genesis::Env->bare($first, $self)->exodus_mount;
	});
}

# }}}
# applied_record_path - the vault path of the pipeline's own facts {{{
#
# <exodus mount>_pipelines/<type>, which reads /secret/exodus/_pipelines/bosh
# under the nominal mount.  The leading underscore makes the address
# unreachable by any environment, because Env::_env_name_errors requires a
# name to start with a lowercase letter (D103).
sub applied_record_path {
	my ($self) = @_;
	return sprintf(
		'%s_pipelines/%s', $self->_pipeline_exodus_mount, $self->type
	);
}

# }}}
# applied_record - read or write the control commit the pipeline was applied from {{{
#
# D103 makes this the owner of the pipeline's own facts, so pipeline-apply
# writes through here and never spells the address for itself.  Called with
# no arguments it reads the three flat fields, and answers undef where the
# path is absent.  Called with a field list it writes those fields and
# returns what it wrote.  The deploy rewrites its own exodus record every
# run, which is why these live at their own path rather than beside the
# deployments.
#
# D58 makes `at` an EXODUS_TIME_FORMAT value rather than an ISO one, and a
# write that names no time of its own is stamped with the current time in
# that format.
sub applied_record {
	my ($self, %fields) = @_;
	my $path = $self->applied_record_path;

	unless (%fields) {
		my $data = $self->vault->get($path);
		return undef unless ref($data) eq 'HASH' && keys %$data;
		return {
			map  {($_ => $data->{$_})}
			grep {defined $data->{$_}}
			qw/control_commit provider at/
		};
	}

	# A caller who hands us nothing but undefined values has nothing to
	# record, and Service::Vault::set would answer an empty argument list
	# with "no key was given", which blames the vault for a mistake this
	# call made.  We say what the fields are instead.
	bug(
		"Genesis::Top::applied_record was asked to write the applied record ".
		"without a value for any of #C{control_commit}, #C{provider}, or ".
		"#C{at}, so there is nothing to record."
	) unless grep {defined $fields{$_}} qw/control_commit provider at/;

	$fields{at} //= Time::Piece->new->strftime(EXODUS_TIME_FORMAT);

	my @written =
		map  {($_ => $fields{$_})}
		grep {defined $fields{$_}}
		qw/control_commit provider at/;

	$self->vault->authenticate->set($path, @written);
	return {@written};
}

# }}}
# pipeline_staleness - the environments whose pipeline no longer matches control {{{
#
# The one home of the comparison (D103).  The propagate pre-flight, the
# deploy pre-flight, and pipeline-status all ask this rather than each
# computing its own, because three copies would drift three ways.
#
# Three inputs go in.  The applied commit comes from the applied record.
# The second is a path diff between that commit and control over D43's
# known set, which is .genesis/config and every file of each
# environment's hierarchy.  The third is each environment's compiled
# dependency set against the set its last deploy recorded reading, which
# is a fact where the compile's answer was a prediction (D77).
#
# A repository the apply has never run against reports nothing, because
# there is no commit to be stale against; that case is the awaiting
# pipeline-apply outcome, which is a different read.
#
# A repository with no pipeline at all reports nothing too, and it has to
# answer before the applied record is addressed.  The deploy pre-flight
# asks this on every deploy, and composing the record's address in a
# repository with no pipeline reaches the refusal in
# _pipeline_exodus_mount, which would stop an ordinary deploy with a
# sentence about a pipeline the operator does not have.
sub pipeline_staleness {
	my ($self, $git) = @_;

	return [] unless $self->pipeline_enabled;

	my $applied = $self->applied_record;
	return [] unless $applied && $applied->{control_commit};

	my %changed = map {($_ => 1)} $git->diff_names(
		$applied->{control_commit}, $self->control_branch
	);

	# The roster and the environment files come from control rather than from
	# the working tree, because two of this comparison's three inputs used to
	# be read out of whatever tree the caller was standing in while only the
	# diff was read from refs.  The propagate pre-flight and pipeline-status
	# stand on control, so the two agreed and the mismatch never showed.  The
	# deploy is the first caller that asks from somewhere else: it stands on
	# a deployment branch, which carries one environment's hierarchy, so the
	# roster was a list of one and an environment added to control since the
	# apply was invisible to it.
	#
	# Only this comparison reads control's tree.  pipeline_topology and
	# pipeline_env_names still read the working tree, because the branch
	# class, the walk, and the pipeline commands all read them and every one
	# of those wants the tree in front of it.
	#
	# The nothing answer is for a control branch this clone cannot read a
	# deployment root out of at all, which is a question about control that
	# the caller's own control check has already asked.
	#
	# Opening a Top sets GENESIS_ROOT and lending it a vault sets the vault's
	# own variables, so the whole read is localised and this query leaves the
	# process as it found it.
	local %ENV = %ENV;
	my ($topology, $at) = $self->_topology_at($git, $self->control_branch);
	return [] unless $topology;

	# The environments' own records are read through the vault this
	# repository has, lent to the materialised tree, which carries none of
	# its own.  Both halves of the dependency comparison then address under
	# one vault, which is the whole point of reading them together.
	my $vault = eval {$self->vault};
	$at->set_vault(vault => $vault, session_only => 1)
		if Scalar::Util::blessed($vault) && $vault->isa('Service::Vault');

	my @changes;
	for my $name (sort keys %{$topology->{nodes}}) {
		my $env = Genesis::Env->bare($name, $at);

		# The names an environment's hierarchy could hold rather than the
		# ones a tree happens to carry, because a defining path that exists
		# only on control has to be compared rather than skipped.  It is
		# pure name derivation and reads no disk, which is what lets it
		# answer for an environment this clone is not standing on.  What it
		# gives up is explicitly inherited files, which need file contents
		# and so need a tree whichever way this is read.
		my @defining = $git->prefixed(
			'.genesis/config',
			map {s{^\./}{}r} $env->potential_environment_files
		);
		if (grep {$changed{$_}} @defining) {
			push @changes, {env => $name, reason => 'configuration-changed'};
			next;
		}

		my $record = $env->pipeline_record or next;
		my $compiled  = join("\n", sort @{$record->{dependencies}});
		my $last_read = join("\n", sort @{$env->last_read_dependencies});
		push @changes, {env => $name, reason => 'dependencies-changed'}
			if $compiled ne $last_read;
	}

	return \@changes;
}

# }}}
# _topology_at - the pipeline's environments as one ref holds them {{{
#
# The configuration and the environment files of the deployment root are
# written out of the ref into a scratch tree, and a Genesis::Top is opened
# over that tree as a reading surface, so the topology comes back exactly as
# pipeline_topology would answer it for a clone standing on the ref.  The
# archive carries the bytes git holds, which is what
# Genesis::Env::_propagation_file_kinds_at does for the same reason.
#
# Nothing but the configuration and the environment files is written out.  No
# kit hook runs against this tree, so the kit source and everything else under
# the root would be extraction paid for and never read.
#
# The scratch directory is held on the Top it belongs to, because the caller
# reads environments out of that Top and a directory taken down when this sub
# returns would leave every one of those reads looking at nothing.
#
# Returns the topology and the Top, or nothing at all where the ref carries no
# deployment root to read.
sub _topology_at {
	my ($self, $git, $ref) = @_;

	my $prefix = ($git->prefixed(''))[0] // '';
	my %tree   = map {($_ => 1)} $git->ls_tree($ref, $prefix eq '' ? '.' : $prefix);

	my $config = $prefix.'.genesis/config';
	return () unless $tree{$config};
	my @want = grep {
		$_ eq $config || m{^\Q$prefix\E[^/]+\.ya?ml$}
	} sort keys %tree;

	require File::Temp;
	my $scratch = File::Temp->newdir();
	my $root    = "$scratch";
	my $archive = File::Temp->new(SUFFIX => '.tar');
	run({dir => $git->root,
		onfailure => "Failed to read the deployment root at $ref"},
		'git', 'archive', '--format=tar', '-o', "$archive", $ref, @want);
	my $depth = ($prefix =~ tr{/}{});
	run({dir => $root,
		onfailure => "Failed to write out the deployment root at $ref"},
		'tar', '-x', '-f', "$archive",
		($depth ? ('--strip-components', $depth) : ()));

	# Opening a Top sets GENESIS_ROOT, and the caller localises the
	# environment around this call and around every read it makes through the
	# Top that comes back.
	my $at = Genesis::Top->new($root, materialised_tree => 1);
	$at->{__scratch_tree} = $scratch;
	return ($at->pipeline_topology, $at);
}

# }}}
# has_legacy_ci_yml - return true when a legacy pipeline ci.yml is present {{{
#
# Set at config-load time when a top-level `ci.yml` file exists AND its
# content is a pipeline config (has a top-level `pipeline:` key).  Used
# by command dispatch to gate the PIPELINE-group commands
# behind a migration message, while letting non-pipeline commands run
# in v2 mode against the same repo.
sub has_legacy_ci_yml {
	my ($self) = @_;
	# Ensure config validation has run so the flag is populated.
	# Genesis::Top->new() defers _validate_config until config() is
	# first accessed; without this touch, callers that only ever
	# call has_legacy_ci_yml (like the dispatch gate) would silently
	# see 0 and let pipeline commands slip past migration.
	$self->config if -f $self->path(".genesis/config");
	return $self->{__has_legacy_ci_yml} ? 1 : 0;
}

# }}}
# pipeline_env_names - return the sorted list of env names in this repo {{{
#
# Returns the names of all valid environments in this repo, sorted
# alphabetically.  Returns an empty list when CI is not configured.
# Delegates to envs() for the canonical name-and-validation logic.
sub pipeline_env_names {
	my $self = shift;
	return sort keys %{$self->pipeline_topology->{nodes}};
}

# }}}
# pipeline_topology - the pipeline's environments, edges and order {{{
#
# The single answer to "what environments are in this pipeline, and in
# what order".  Previously that question had two implementations that
# agreed only by coincidence: this method globbed *.yml, while
# Genesis::CI::Compiler::ASTBuilder::_build_from_env_files walked the
# same directory building a DAG -- and the DAG one, though private, was
# called from four places in Genesis::Commands::Pipelines.  Anything
# reading pipeline membership now goes through here.
#
# Returns a hashref:
#
#   nodes      env name => its genesis.pipeline data
#   edges      [ {from => ..., to => ...}, ... ] from prior_env
#   children   env => [ envs downstream of it ]
#   parent_of  env => the env it follows
#   order      topological, roots first, siblings by name
#
# Empty in every field where the repository declares no pipeline, so
# callers can iterate unconditionally.
sub pipeline_topology {
	my ($self) = @_;

	my %empty = (nodes => {}, edges => [], children => {}, parent_of => {}, order => []);
	return \%empty unless $self->pipeline_enabled;

	require Genesis::CI::Compiler::ASTBuilder;
	my $builder = Genesis::CI::Compiler::ASTBuilder->new(
		top     => $self,
		env_dir => $self->path,
	);
	my ($nodes, $edges) = $builder->_build_from_env_files($self->path);
	return \%empty unless $nodes && %$nodes;

	my (%children, %has_parent, %parent_of);
	for my $edge (@$edges) {
		push @{$children{$edge->{from}}}, $edge->{to};
		$has_parent{$edge->{to}} = 1;
		$parent_of{$edge->{to}}  = $edge->{from};
	}

	# Breadth-first from the roots.  Sorted at every step so siblings
	# come back in a stable order -- callers print this, and tests
	# compare it.
	my (@order, %visited);
	my @queue = sort grep {!$has_parent{$_}} keys %$nodes;
	while (@queue) {
		my $env = shift @queue;
		next if $visited{$env}++;
		push @order, $env;
		push @queue, sort @{$children{$env} || []};
	}

	return {
		nodes     => $nodes,
		edges     => $edges,
		children  => \%children,
		parent_of => \%parent_of,
		order     => \@order,
	};
}

# }}}
# fetch_pipeline_envs - the one refresh, control included {{{
#
#   my $result = $top->fetch_pipeline_envs($git);
#   my $result = $top->fetch_pipeline_envs($git, command => 'qa deploy',
#                                                action  => 'deploy',
#                                                outcome => 'Nothing was deployed.');
#
# Brings the remote into the remote-tracking refs for the control branch and
# for every deployment branch in the pipeline, in one round trip, so
# credentials are prompted once.  Control is named unconditionally, because a
# run that never compares control with the remote propagates whatever the
# clone happens to hold.
#
# The names are deployment branches rather than environment names, under D66,
# because the branch is what the remote has and an environment name is not a
# ref on it.  A refresh asking for the name fetched nothing for any
# environment whose branch carries a type, which is every environment in a
# typed repository.
#
# Returns fetch_branches' result, whose `created` list is what the caller
# reports the creation of a local ref from.  A failure is fatal here rather
# than survivable later, because under D40 every pipeline command but
# pipeline-status refreshes unconditionally, so an unreachable remote is the
# unsurvivable class and exits TEMPFAIL for the caller to retry.
sub fetch_pipeline_envs {
	my ($self, $git, %opts) = @_;
	return undef unless $self->pipeline_enabled;
	my $remote = $git->default_remote;
	return undef unless $remote;

	my $action  = $opts{action}  // sprintf('run #C{genesis %s}', $opts{command} // 'propagate');
	my $outcome = $opts{outcome} // 'Nothing was written.';

	my @names = ($self->control_branch,
		map { $self->branch_for($_) } $self->pipeline_env_names);

	my (undef, $result) = $git->fetch_branches(\@names, $remote);
	return $result if $result->{ok};

	my $because = $result->{kind} eq 'network'
		? 'the network or the remote is unreachable'
		: $result->{kind} eq 'auth'
		? 'the remote rejected our credentials'
		: 'the remote failed the request';

	bail({exitcode => TEMPFAIL},
		"Refusing to %s.  Failed to reach #C{%s} to refresh the pipeline ".
		"branches, because %s, so nothing this command reads can be shown to ".
		"be current.\n\n%s\n\n".
		"Restore access to #C{%s} and run the command again.  %s",
		$action, $remote, $because,
		($result->{err} // 'no further detail') =~ s/\s+$//r,
		$remote, $outcome
	);
}

# }}}
# version - return the version of the cofiguration schema {{{
sub version {
	my ($self) = @_;
	return $self->config->get("version") if ($self->config->get("version")||'') =~ /^\d+$/;
	return 1;
}

# }}}
# genesis_version - return the genesis version that initialized the repo {{{
sub genesis_version {
   my ($self) = @_;
	 return $self->config->get("creator_version") if $self->config->get("creator_version");
   return $self->config->get("genesis_version") if $self->config->get("genesis_version");
   return $self->config->get("version") if $self->config->get("version") !~ /^\d+$/;
   return "Unknown";
}
# }}}
# local_kits_path - return the path to the local kit directory {{{
sub local_kits_path {
	my ($self) = @_;

	# Check user config first (highest precedence)
	my $kits_path = expand_path(
		$Genesis::RC->get('kits_path') // $self->config->get('kits_path'),
		$self->path()
	);
}

# }}}
# has_dev_kit - returns true if the repo has an embedded dev kit {{{
sub has_dev_kit {
	my ($self) = @_;
	return -d $self->path("dev");
}

# }}}

# Environment handling
# envs - return a list of the environments in the repo {{{
sub envs {
	my ($self) = @_;

	my $root_path = $self->path();
	my @envs;
	my @candidates =
		grep {! scalar(Genesis::Env::_env_name_errors($_))} # only pick envs with valid names
		map {s{^$root_path/}{}r}                            # strip the root path
		map {s{.yml$}{}r}                                   # strip the .yml extension
		glob($self->path("*.yml"));

	foreach my $env (@candidates) {
		# Use has_env to validate the environment (checks for genesis.env and kit info)
		next unless $self->has_env($env);
		push @envs, Genesis::Env->new(name => $env, top => $self);
	}
	return @envs;
}
# }}}
# load_env - return a Genesis::Env object for the specified environment in the repo {{{
sub load_env {
	my ($self, $name) = @_;
	$name =~ s/.yml$//;
	debug("loading environment #C{%s}", $name);

	# Check if environment exists and get validation errors if any
	my ($valid, @errors) = $self->has_env($name);
	if ($valid) {
		return Genesis::Env->load(top  => $self, name => $name);
	} elsif (in_callback() && $name eq $ENV{'GENESIS_ENVIRONMENT'}) {
		return Genesis::Env->from_envvars($self);
	} else {
		# If we have specific validation errors, use them; otherwise generic message
		if (@errors) {
			bail(join("\n\n", @errors));
		} else {
			bail(
				"Environment file #C{%s} does not exist%s",
				humanize_path($self->path($name.".yml")),
				-f $self->path(".genesis/config") ? '' : " - this does not appear to be a Genesis deployment directory!"
			);
		}
	}
}

# }}}
# has_env - returns true if the repo has an enviroment of the given name {{{
sub has_env {
	my ($self, $name) = @_;
	# Delegate to Genesis::Env for all validation logic
	# This ensures consistent validation behavior and DRY principle
	return Genesis::Env->is_valid_env_file($name, $self);
}

# }}}
# create_env - create a new environment of the given name in the repo {{{
sub create_env {
	my ($self, $name, $kit, %opts) = @_;
	debug("setting up new environment #C{%s}", $name);
	return Genesis::Env->create(
		%opts,
		top  => $self,
		name => $name,
		kit  => $kit,
	);
}

# }}}

# Kit handling
# local_kits - return the list of the kits available locally {{{
sub local_kits {
	my ($self) = @_;
	return Genesis::Kit::Compiled->local_kits(
		$self->kit_provider(),
		$self->local_kits_path()
	);
}

# }}}
# local_kit_version - return the Genesis::Kit object for the given name and version {{{
sub local_kit_version {
	my ($self, $name, $version) = @_;

	($name, $version) = ($1, $2)
		if (!defined($version) && defined($name) && $name =~ m{(.*)/(.*)});

	# local_kit_version('dev') or local_kit_version() with a dev kit present
	return Genesis::Kit::Dev->new($self->path("dev"))
		if ((!$name && !$version) || ($name && $name eq 'dev')) && $self->has_dev_kit;
	return undef if ($name and $name eq 'dev');

	#    local_kit_version() without a dev/ directory
	# or local_kit_version($name, $version)
	my $kits = $self->local_kits();

	# we either need a $name, or only one kit type
	# (i.e. we can autodetect $name for the caller)
	$name = (keys %$kits)[0] if (!$name && keys(%$kits) == 1);
	return undef unless $kits->{$name};

	$version = (reverse sort by_semver keys %{$kits->{$name}})[0]
		if (!defined($version) || $version eq 'latest');
	return $kits->{$name}{$version};
}

# }}}
# remote_kit_names - get available kit names from kit provider {{{
sub remote_kit_names {
	my $self = shift;
	$self->kit_provider->kit_names(@_);
}

# }}}
# remote_kit_versions - get versions available for a remote kit from the kit provider {{{
sub remote_kit_versions {
	my $self = shift;
	$self->kit_provider->kit_versions(@_);
}

# }}}
# remote_kit_version_info - return the metadata about the specified remote kit version {{{
sub remote_kit_version_info {
	my ($self, $name, $version) = @_;
	($name, $version) = ($1, $2)
		if (!defined($version) && defined($name) && $name =~ m{(.*)/(.*)});
	$version = $self->kit_provider->latest_version_of($name) unless $version && $version ne 'latest';
  $self->kit_provider->kit_versions($name, version => $version);
}

# }}}
# download_kit - install remote kit into the local repository {{{
sub download_kit {
	my ($self, $id, %opts) = @_;
	my ($name, $version) = ($1, $2) if $id =~ m/([^\/]+)(?:\/(.*))?/;
	$version = $self->kit_provider->latest_version_of($name) unless $version && $version ne 'latest';

	my $target;
	if ($opts{to}) {
		$target = $opts{to};
		bail(
			"#C{%s} is not a directory", $opts{to}
		) unless -d $opts{to};
		bail(
			"#C{%s} is not writable", $opts{to}
		) unless -w $opts{to};
	} elsif ($opts{'as-dev'}) {
		$target = workdir;
	} else {
		$target = $self->local_kits_path();
		mkdir_or_fail($target) unless -d $target;
	}

	$self->kit_provider->fetch_kit_version($name,$version,$target,$opts{force});
}

# }}}

# Private Methods

# _validate_config - validate the configuration of the repo {{{
sub _validate_config {
	my ($self) = @_;
	return 1 if $self->{__config_validated};
	$self->{__config_validated} = 1;
	my $config_version = $self->config->get(version => 1);

	# Classify before comparing.  In modern repos the `version` field
	# is either an integer schema number (1, 2, 3) or absent (which
	# get(version => 1) defaults to 1).  But ancient pre-2018 repos
	# -- before commit e9cad6ac introduced the dedicated
	# `genesis_version:` field -- wrote the genesis RELEASE semver
	# (e.g. "2.7.1") into the `version:` field itself.  Those configs
	# are now extremely rare in practice but the defensive semver
	# match is preserved here (and in _upgrade_config_to_v2's
	# creator_version capture) to upgrade them cleanly if anyone
	# still has one.
	#
	# Numeric `==` against a semver string warns ("Argument 'X.Y.Z'
	# isn't numeric in numeric eq (==)"), so gate each `==` on an
	# integer-shape check first.
	my $is_integer = ($config_version =~ /^\d+$/);
	my $is_semver  = ($config_version =~ /^\d+\.\d+\.\d+(-[A-Za-z0-9_-]\.?\d+)?$/);

	if (($is_integer && $config_version == 1) || $is_semver) {

		my $upgrade_automatically = $Genesis::RC->get(automatic_config_upgrade => 'no');
		bail(
			"Genesis deployment repo v1 configuration is not supported, and cannot ".
			"update automatically.  Manual intervention required."
		) unless in_controlling_terminal || $upgrade_automatically ne 'no';

		$self->_upgrade_config_to_v2($config_version, $upgrade_automatically);

	} elsif ($is_integer && $config_version == 2){
		$self->config->validate($self->_repo_config_schema_v2());
		$self->{__config_disk_version} = 2;

		# Detect legacy ci.yml -- flag it so command dispatch can gate
		# pipeline-consuming commands, but otherwise let the repo load.
		# Non-pipeline commands (deploy, check, manifest, secrets ops)
		# run unchanged in v2 mode.  Only pages with a top-level
		# 'pipeline:' key are treated as legacy CI configs; env files
		# named ci.yml (which start with 'kit:' or 'genesis:') don't
		# trip the check.
		my $ci_yml = $self->path('ci.yml');
		$self->{__has_legacy_ci_yml} = 1
			if -f $ci_yml && _is_legacy_ci_file($ci_yml);

		# A pipeline block written into a version 2 file is refused here,
		# before the injection below puts one there itself.
		$self->_refuse_v2_pipeline;

		# Augment in-memory with v3 defaults so downstream code sees
		# a uniform v3 shape.  These go into the 'default' layer and
		# will NOT be persisted to disk on save.
		$self->config->_update_source('default', 'pipeline', {
			enabled => Genesis::Config::FALSE,
		});

	} elsif ($is_integer && $config_version == 3){
		$self->config->validate($self->_repo_config_schema());
		$self->{__config_disk_version} = 3;

		# The checks a declarative schema cannot state, under D28, run for
		# every command and right after the schema.  Later work extends
		# _validate_pipeline_config and never touches this call.
		$self->_validate_pipeline_config;

		# Detect legacy ci.yml alongside v3 config -- flag it for the
		# dispatch gate.  Two sub-cases surface at load time:
		#   * v3 config already declares a pipeline
		#     -> stale ci.yml, warn once and keep going; the v3 config
		#     wins downstream.
		#   * v3 config has no pipeline configured -> flag as legacy CI so
		#     pipeline commands gate on migration; other commands run.
		#
		# The configuration is memoized before _validate_config runs, so
		# the accessor reads it back rather than re-entering the load.
		my $ci_yml = $self->path('ci.yml');
		if (-f $ci_yml && _is_legacy_ci_file($ci_yml)) {
			if ($self->pipeline_enabled) {
				warning(
					"Legacy #C{%s} present alongside a v3 CI configuration; ".
					"the v3 config wins.  Remove #C{%s} to clear this warning.",
					$ci_yml, $ci_yml
				);
			} else {
				$self->{__has_legacy_ci_yml} = 1;
			}
		}

		# Delegate validation of registered sections to their owning modules
		for my $section (sort keys %_config_section_handlers) {
			next unless $self->config->has($section);
			my $handler = $_config_section_handlers{$section};
			$handler->validate_config_section($self->config->get($section), $self)
				if $handler->can('validate_config_section');
		}
	} else {
		bail({exitcode => CONFIG},
			"Genesis deployment repo configuration version %s is not supported",
			$config_version
		);
	}
	return 1;
}

# }}}
# _upgrade_config_to_v2 - upgrade the configuration to version 2 from previous unversioned configs {{{
sub _upgrade_config_to_v2 {
	my ($self, $config_version, $upgrade_automatically) = @_;

	# Check if we can upgrade to v2
	my $new_config = Genesis::Config->new();
	$new_config->set('deployment_type', $self->config->get('deployment_type' => $self->config->get('type')));
	$new_config->set('version', 2);
	if ($config_version =~ /^\d+\.\d+\.\d+(-[A-Za-z0-9_-]\.?\d+)?$/) {
		$new_config->set('creator_version', $config_version);
	} else {
		$new_config->set('creator_version',  # There are several possible keys for the creator version
				 $self->config->get('creator_version'
			=> $self->config->get('genesis_version'
			=> $self->config->get('genesis' => 'Unknown'
		))));
	}
	$new_config->set('updater_version', $Genesis::VERSION);
	$new_config->set('kit_provider', $self->config->get('kit_provider')) if $self->config->has('kit_provider');
	if ($self->config->has('secrets_provider')) {
		$new_config->set('secrets_provider', $self->config->get('secrets_provider'))
	} elsif ($self->config->has('vault')) {
		my %provider = (
			url       => $self->vault->url,
			insecure  => $self->vault->verify ? Genesis::Config::FALSE : Genesis::Config::TRUE,
			namespace => $self->vault->namespace,
			alias     => $self->vault->name
		);
		my $strongbox = $self->_strongbox_for_config($self->vault);
		$provider{strongbox} = $strongbox if defined($strongbox);
		$new_config->set('secrets_provider', \%provider);
	}

	if ($self->config->has('allow_oversized_secrets')) {
		$new_config->set('allow_oversized_secrets', $self->config->get('allow_oversized_secrets'));
	}

	my $old_config = $self->config;
	$self->{__config} = $new_config;

	bail(
		"Cannot upgrade Genesis deployment repo v1 configuration to v2.  Manual intervention required."
	) unless $self->_validate_config;

	# Show and ask permission to upgrade
	if ($upgrade_automatically ne 'silent') {
		warning "Genesis deployment repo v1 configuration detected, preparing to upgrade to v2";
		$self->config->show_diff($old_config);
	}

		# Ask user permission to upgrade to v2

	my $upgrade = $upgrade_automatically ne 'no' || prompt_for_boolean(
		"Proceed [y|n]?", 1
	);

	if ($upgrade) {
		$self->config->replace($old_config);
		info(
			"Genesis deployment repo configuration upgraded to v2"
		) unless $upgrade_automatically eq 'silent';
	} else {
		bail "Genesis deployment repo configuration upgrade to v2 aborted";
	}
}

# }}}
# _repo_config_schema_v2 - v2 configuration validation schema {{{
sub _repo_config_schema_v2 {
	my ($self) = @_;
	return {
		# Declared because _validate_config injects a version 3 shaped
		# block here at default priority, so that downstream readers meet
		# one shape whichever version is on disk.  Nothing clears the
		# defaults between one validation and the next, so a validation
		# that met the injection undeclared would report it as a key
		# nobody wrote and refuse every write the repository can make.
		# Only the gate is declared, because the gate is the whole of
		# what is injected and the rest of the block means nothing here.
		pipeline => {
			type        => 'hash',
			description => 'The version 3 shaped gate the loader injects',
			schema => {
				enabled => {
					type        => 'boolean',
					description => 'Whether this repository has a pipeline'
				},
			},
		},
		deployment_type => {
			type           => 'string',
			required       => 1,
			description    => 'Type of deployment this repository manages'
		},
		version => {
			type           => '"2"',
			required       => 1,
			description    => 'Configuration schema version'
		},
		creator_version => {
			type           => 'semver||"(development)"||"Unknown"',
			required       => 1,
			description    => 'Genesis version that created this repository'
		},
		updater_version => {
			type           => 'semver||"(development)"',
			description    => 'Genesis version that last updated this repository'
		},
		minimum_version => {
			type           => 'semver',
			description    => 'Minimum Genesis version required for this repository'
		},
		manifest_store => {
			type           => 'enum',
			values         => ['repository','hybrid','exodus'],
			default        => 'exodus',
			description    => 'Where to store manifests'
		},
		kits_path => {
			type           => 'string',
			default        => '$GENESIS_ROOT/.genesis/kits',
			description    => 'Path to directory containing compiled kits (defaults to .genesis/kits under the deployment base directory)',
		},
		kit_provider => {
			type           => 'hash',
			description    => 'Configuration for kit provider',
			schema => {
				type         => {type => 'enum', values => ['github','genesis-community']},
				organization => {type => 'string'},
				label        => {type => 'string'},
				tls          => {type => 'enum', values => ['yes', 'no', 'skip', 'insecure']},
				domain       => {type => 'string'},
			}
		},
		secrets_provider => {
			type           => 'hash',
			description    => 'Configuration for secrets provider (Vault)',
			schema => {
				url          => {type => 'string', required => 1},
				insecure     => {type => 'boolean', default => Genesis::Config::FALSE},
				# No default: an absent key means no one stated it, which is
				# a third state and not a synonym for on.  Defaulting here
				# would re-create on read the ambiguity the writer avoids.
				strongbox    => {type => 'boolean'},
				namespace    => {type => 'string'},
				alias        => {type => 'string'}
			}
		},
		deployment_change_reason_required_size => {
			type           => 'number',
			default        => 0,
			description    => 'Minimum size of the deployment change reason in characters (0 to disable)',
		},
		user_provided_bosh_creds => {
			type           => 'enum',
			default        => 'ignore',
			values         => [qw/ignore allow require/],
			description    => 'How should BOSH_USER and BOSH_PASSWORD env vars be handled',
		},
		allow_oversized_secrets => {
			type           => 'boolean',
			description    => 'Allow secrets larger than recommended size'
		},
		confirm_release_overrides => {
			type           => 'enum',
			values         => [qw/always outdated never/],
			envvar         => 'GENESIS_CONFIRM_RELEASE_OVERRIDES',
			description    => 'Confirm release overrides'
		},
	};
}

# }}}
# _repo_config_schema - v3 configuration validation schema (superset of v2) {{{
sub _repo_config_schema {
	my ($self) = @_;
	return {
		%{$self->_repo_config_schema_v2()},
		version => {
			type           => '"3"',
			required       => 1,
			description    => 'Configuration schema version'
		},
		pipeline => $self->_pipeline_config_schema(),
	};
}

# }}}
# _pipeline_config_schema - the pipeline section of the v3 schema {{{
#
# Under D18 the section is named pipeline while the Genesis::CI code
# namespace stays where it is, and under D28 the schema is the contract:
# every key the compiler reads is declared here, so Genesis::Config's own
# recursion refuses an undeclared key by name at configuration load, for
# every command and not only for the pipeline ones.  There are no
# compatibility aliases, because the v3 schema is unreleased.
#
# The provider block is not required beside an enabled gate, because
# under D15 an absent provider type is a manual pipeline rather than no
# pipeline at all.
sub _pipeline_config_schema {
	my ($self) = @_;

	return {
		type        => 'hash',
		description => 'Pipeline configuration',
		schema => {
			enabled => {
				type        => 'boolean',
				default     => Genesis::Config::FALSE,
				description => 'Whether this repository has a pipeline'
			},
			# D105: the schema for this block is a function of the block's
			# own type, so the block says so rather than having something
			# read the type ahead of validation and assemble a schema from
			# what it found.  D15 keeps its default here, on the
			# declaration, so an enabled section with no provider block is
			# still a manual pipeline.
			# The empty hash is what lets that default be reached, because
			# validation walks into a block that is present and nowhere
			# else.
			provider => {
				type                  => 'custom_struct',
				discriminator         => 'type',
				default               => {},
				discriminator_default => 'manual',
				noun                  => 'CI provider',
				schema_method         => 'provider_options_schema',
				description           => 'The automation that owns the pipeline',
				modules               => $self->_provider_module_map(),
			},
			# D66 released the label from the branch, so it names the
			# provider's pipeline and nothing else, and it is deliberately
			# not checked as a git ref component.
			name => {
				type        => 'string',
				description => "The pipeline's name in its provider (defaults to deployment_type)"
			},

			# D101: a BOSH flag rather than a provider feature, so no
			# capability gates it.  Repository-wide, because a key that
			# changes how a deployment progresses must be uniform or the
			# earlier environments stop rehearsing the later ones.
			recreate_on_deploy => {
				type        => 'enum',
				values      => [qw/never redeploy-only always/],
				default     => 'never',
				description => 'Which runs pass --recreate to the BOSH deploy'
			},

			source_control => {
				type        => 'hash',
				description => 'What the pipeline needs to know about the repository',
				schema => {
					# Derived from git, with an explicit override, because each
					# is a choice with a good default rather than a fact of the
					# checkout.  The deployment root takes no key, being a fact
					# of the checkout, and neither does the branch a command
					# runs from, that being runtime state.
					remote     => {type => 'string', description => "The remote CI clones from; derived from the control branch's upstream"},
					uri        => {type => 'string', description => "That remote's fetch URL"},
					repository => {type => 'string', description => "The GitHub owner/repo the API targets"},

					# Defaulted, and read through one accessor apiece.
					control_branch      => {type => 'string',  default => DEFAULT_CONTROL_BRANCH, description => "The control branch's name"},
					pr_prefix           => {type => 'string',  default => 'pr/', description => 'The pull request branch prefix'},
					control_requires_pr => {type => 'boolean', default => Genesis::Config::FALSE, description => 'Whether control accepts direct pushes'},

					# CI only, and required wherever a pipeline task has to
					# clone and commit on its own.
					auth => {
						type        => 'hash',
						required    => \&_automated_provider_configured,
						description => 'Vault references for the clone credential',
						schema => {
							type     => {type => 'enum', values => [qw/ssh https/], default => 'ssh', description => 'How the task authenticates'},
							vault    => {type => 'string', description => 'Vault path holding the credential'},
							username => {type => 'string', description => 'Username for the https form'},
						}
					},
					identity => {
						type        => 'hash',
						required    => \&_automated_provider_configured,
						description => 'The name and email a pipeline task commits under',
						schema => {
							name  => {type => 'string', required => 1, description => 'Committer name'},
							email => {type => 'string', required => 1, description => 'Committer email'},
						}
					},
				}
			},

			# D23 fixes the backend and refuses a directory, and D105 makes
			# the block say that its backend decides its shape, so a GCS
			# configuration can no longer carry a region that nothing will
			# ever read.
			#
			# There is no discriminator_default, because the block has never
			# had one: the backend is required today and there is no sensible
			# default between two object stores.  A block written with no
			# backend at all is refused as an unknown value naming the two an
			# operator may write, rather than as a missing required key.
			shuttle => {
				type          => 'custom_struct',
				discriminator => 'backend',
				noun          => 'shuttle backend',
				schema_method => 'options_schema',
				required      => \&_automated_provider_configured,
				description   => "The object store behind every deployment's queue and event",
				modules => {
					s3  => {class => 'Genesis::CI::Shuttle::S3',  module => 'Genesis/CI/Shuttle/S3.pm'},
					gcs => {class => 'Genesis::CI::Shuttle::GCS', module => 'Genesis/CI/Shuttle/GCS.pm'},
				},
			},

			# D17 and D27: the vault a pipeline task writes exodus through.
			vault => {
				type        => 'hash',
				required    => \&_automated_provider_configured,
				description => 'The vault a pipeline task writes exodus through',
				schema => {
					url       => {type => 'string', required => 1, description => 'Vault URL'},
					namespace => {type => 'string', description => 'Vault namespace'},
					auth      => {type => 'string', description => 'Vault reference for the task credential'},
					options   => {type => 'any',    description => 'Provider-specific vault options'},
				}
			},

			# D22 and D74: the locker behind the two mandatory deploy locks,
			# read by the compiler for the emitted resources and by the CLI.
			locker => {
				type        => 'hash',
				required    => \&_automated_provider_configured,
				description => 'The locker behind the two mandatory deploy locks',
				schema => {
					url                  => {type => 'string',  required => 1, description => 'Locker URL'},
					username             => {type => 'string',  description => 'Locker username'},
					password             => {type => 'string',  description => 'Locker password, as a vault reference'},
					ca_cert              => {type => 'string',  description => 'CA certificate for the locker'},
					skip_ssl_validation  => {type => 'boolean', default => Genesis::Config::FALSE, description => 'Skip TLS verification'},
				}
			},

			# D27: optional, with a repository default the environment's own
			# genesis.pipeline.notifications.* overrides.
			notifications => {
				type        => 'hash',
				description => 'How the pipeline notifies, and where',
				schema => {
					style => {type => 'string', default => 'default', description => 'The repository default rendering'},
					slack => {type => 'any', description => 'Slack entries'},
					email => {type => 'any', description => 'Email entries'},
				}
			},
		}
	};
}

# }}}
# _current_config_schema - the schema for the version on disk {{{
#
# Built on demand rather than read back off the config object.  Under D86
# the configured provider's own fragment is merged as the schema is built,
# so a command that changes the provider type changes the schema its keys
# have to be judged against, and the copy the load left behind is a
# version out of date.  Every writer that re-validates asks for this one.
sub _current_config_schema {
	my ($self) = @_;

	$self->config unless $self->{__config_disk_version};
	return ($self->{__config_disk_version} // 0) >= 3
		? $self->_repo_config_schema
		: $self->_repo_config_schema_v2;
}

# }}}
# _refuse_v2_pipeline - a pipeline section is version 3 work {{{
#
# The version 2 schema declares the pipeline key, because the gate
# _validate_config injects has to survive the first write, and declaring a
# key is also what makes it writable.  So the write is refused on its own
# and the declaration keeps its one job.
#
# is_set reads the loaded and set layers alone, so this sees a block
# somebody wrote into the file and a block a command set in this run, and
# never the injection, which goes in at default priority.
#
# Both callers need it.  The load meets a block that was already on disk,
# and a command that writes one meets it only after the load has been and
# gone, so a check in one place alone would let the other through.
sub _refuse_v2_pipeline {
	my ($self) = @_;

	return 1 unless ($self->{__config_disk_version} // 0) == 2;
	bail({exitcode => CONFIG},
		"A pipeline section belongs to a version 3 repository configuration, ".
		"and this repository is still version 2.  Migrate ".
		"#C{.genesis/config} to version 3 first, and the pipeline block ".
		"becomes one you can write."
	) if $self->config->is_set('pipeline');
	return 1;
}

# }}}
# _provider_module_map - every provider type, and the class that owns it {{{
#
# One read of the registry under D28, where the enum and the lookup used
# to be two.  Every registered type has a CLI class, so the map is total
# and nothing downstream asks whether a provider has a class.
sub _provider_module_map {
	my ($self) = @_;

	require Genesis::CI::ProviderRegistry;
	my %map;
	for my $type (Genesis::CI::ProviderRegistry->known_providers) {
		my $info = Genesis::CI::ProviderRegistry->provider_info($type);
		$map{$type} = {class => $info->{cli_class}, module => $info->{cli_file}};
	}
	return \%map;
}

# }}}
# _pipeline_env_keys_schema - the genesis.pipeline block of an env file {{{
#
# Declared as its own schema rather than folded into the repository's,
# because it is validated once per environment against that environment's
# merged parameters.  Under D79 the read is merged and never leaf-only: a
# leaf-only read finds an inherited key absent, silently, and answers
# wrongly with no error, and most of these keys live high in the
# hierarchy, typically in the site file.
sub _pipeline_env_keys_schema {
	my ($self) = @_;
	return {
		type        => 'hash',
		description => "The environment's pipeline settings",
		schema => {
			prior_env  => {type => 'string',  description => 'The topology edge, the environment this one follows'},
			require_pr => {type => 'boolean', description => 'Propagate through a pull request rather than directly'},
			manual     => {type => 'boolean', description => "The deploy job waits for a human trigger"},

			# D21 replaced the shipped redeploy key, the two flat cron keys,
			# and the boolean-or-block form with one crontab expression, or a
			# list of them, in UTC.  A bare string is normalised to a
			# one-element list before validation, so the declaration stays a
			# list of strings and the operator may still write one.
			redeploy_cron => {
				type        => 'array',
				subtype     => 'string',
				envsplit    => ',',
				description => 'Crontab expressions, in UTC, that trigger the redeploy job'
			},

			# D26: two sources, no opt-out.  An entry is a deployment type at
			# this environment, or <env>/<type> elsewhere, and the shape is
			# checked beside the declaration because the validator has no
			# pattern of its own.
			track_dependencies => {
				type        => 'array',
				subtype     => 'string',
				envsplit    => ',',
				description => 'Deployments whose exodus records this one reads'
			},

			# D24: renamed, with its path semantics unchanged.
			track_additional_files => {
				type        => 'array',
				subtype     => 'string',
				envsplit    => ',',
				description => 'Extra deployment-root-relative paths for the propagation set'
			},

			# D27: per environment only; the global fallback went with the
			# multi-file layout.  A boolean turns every config type on, and a
			# list names them, so the declaration is permissive here and the
			# shape is checked beside it.
			track_bosh_configs => {
				type        => 'any',
				description => 'BOSH config types whose change triggers a redeploy'
			},

			notifications => {
				type        => 'any',
				description => "This environment's override of the repository's notification style"
			},
		}
	};
}

# }}}
# _automated_provider_configured - true when the pipeline is not manual {{{
#
# The predicate the required flag of source_control.auth, identity,
# shuttle, vault, and locker reads.  Under D15 an absent provider type is
# manual, so an absent block is only required once somebody names an
# automation that has to do the work unattended.
sub _automated_provider_configured {
	my ($siblings, $config) = @_;
	return 0 unless $config && $config->get('pipeline.enabled');
	my $type = $config->get('pipeline.provider.type', 'manual') // 'manual';
	return $type eq 'manual' ? 0 : 1;
}

# }}}
# _source_control - the resolved source-control values {{{
#
# Precedence is explicit over derived over default, under D29.  The remote
# is the control branch's configured upstream, else origin where it
# exists, and never "the first git remote", because that is alphabetical
# order and a repository holding dev and origin would pick dev.  The
# repository is the GitHub owner/repo the remote's URL carries; under D102
# the MVP supports GitHub alone, whether github.com or GitHub Enterprise,
# so any other host needs the override and is refused by name without it,
# with no exception under the manual provider.
sub _source_control {
	my ($self) = @_;

	return $self->{__source_control} if $self->{__source_control};

	require Service::Git;

	# The nested read terminates rather than recursing, because _memoize
	# installs the configuration object before _validate_config runs, so
	# this call and the two accessors below it meet the memo and not the
	# validation that is still on the stack above them.
	my $config = $self->config;

	# Through the accessors, because each of those two keys has one reader
	# and a second read here would make that untrue.
	my %sc = (
		control_branch => $self->control_branch,
		pr_prefix      => $self->pr_prefix,
	);

	bail({exitcode => CONFIG},
		"#C{pipeline.source_control.control_branch} must not be empty.\n".
		"The control branch is the branch every pipeline command reads the ".
		"repository from, so there is nothing to name without it."
	) unless defined $sc{control_branch} && length $sc{control_branch};

	bail({exitcode => CONFIG},
		"#C{pipeline.source_control.pr_prefix} must not be empty.\n".
		"An empty prefix gives the pull request branch the deployment ".
		"branch's own name, so the two could not be told apart."
	) unless length $sc{pr_prefix};

	# Asked before the handle is built, because the constructor refuses a
	# path under no git control with a message about the path, and what an
	# operator who turned a pipeline on needs to hear is what a pipeline
	# needs a repository for.
	bail({exitcode => CONFIG},
		"#C{pipeline} is enabled, but #C{%s} is not a git checkout.\n".
		"A pipeline is a set of branches, so the deployment repository has ".
		"to be under git before one can be configured.",
		$self->path
	) unless Service::Git->is_inside_work_tree($self->path);

	my $git = Service::Git->new($self->path);

	$sc{remote} = $config->get('pipeline.source_control.remote')
		// $git->branch_upstream_remote($sc{control_branch})
		// ($git->has_remote('origin') ? 'origin' : undef);
	bail({exitcode => CONFIG},
		"#C{pipeline.source_control.remote} could not be derived.\n".
		"The control branch #C{%s} has no configured upstream and there is ".
		"no remote named #C{origin}.  Name the remote explicitly.",
		$sc{control_branch}
	) unless $sc{remote};

	$sc{uri} = $config->get('pipeline.source_control.uri');

	# The repository is the only value derived from the url, and asking git
	# for the url costs a fork on every command, so where the operator named
	# the repository the url is left alone.  That is the one way the uri
	# comes back undef, and the one way a report shows it as (none).
	$sc{repository} = $config->get('pipeline.source_control.repository');
	unless ($sc{repository}) {
		$sc{uri} //= $git->remote_url($sc{remote});
		$sc{repository} = _github_owner_repo($sc{uri});
		bail({exitcode => CONFIG},
			"#C{pipeline.source_control.repository} could not be derived from ".
			"#C{%s}.\nThe MVP supports GitHub, github.com or GitHub Enterprise, ".
			"and that URL carries no #C{owner/repo} pair.  Name the repository ".
			"explicitly, or move the pipeline to a GitHub remote.",
			$sc{uri} // '<no remote url>'
		) unless $sc{repository};
	}

	return $self->{__source_control} = \%sc;
}

# }}}
# _github_owner_repo - the owner/repo a GitHub URL carries, or undef {{{
#
# Enterprise parses the same way, because its URLs carry the pair in the
# same shape and only the host differs.  The host is what says GitHub: any
# https URL at all carries two path segments, so without a host test every
# forge on earth would parse and the D102 refusal would never fire.
#
# The host test is a substring rather than a label boundary, so it is
# deliberately loose: it has to admit every Enterprise hostname an operator
# might run, and those are named freely.  A host that merely contains the
# word therefore parses too, and the pair it yields then fails against the
# configured API base, which is a later refusal rather than a wrong answer.
sub _github_owner_repo {
	my ($uri) = @_;
	return undef unless defined $uri && length $uri;
	return "$1/$2" if $uri =~ m{^https?://[^/]*github[^/]*/([^/]+)/([^/]+?)(?:\.git)?/?$}i;
	return "$1/$2" if $uri =~ m{^(?:ssh://)?[^@]+\@[^:/]*github[^:/]*[:/]([^/]+)/([^/]+?)(?:\.git)?/?$}i;
	return undef;
}

# }}}
# _ref_component_errors - why a value is not a git ref component {{{
#
# The pattern admits three shapes git then rejects, so they are refused
# beside it: a trailing dot, a .lock suffix, and any '..' sequence.
sub _ref_component_errors {
	my ($value) = @_;
	return 'it must not be empty'                unless defined $value && length $value;
	return 'it must match ^[A-Za-z0-9][A-Za-z0-9._-]*$'
		unless $value =~ m{^[A-Za-z0-9][A-Za-z0-9._-]*$};
	return 'it must not end in a dot'            if $value =~ m{\.$};
	return 'it must not contain ".."'            if $value =~ m{\.\.};
	return 'it must not end in ".lock"'          if $value =~ m{\.lock$};
	return undef;
}

# }}}
# _validate_slug_components - both halves of the deployment slug {{{
#
# Under D66 the deployment branch is <env>/<type>, so both halves become
# git ref components and neither is trusted over the other.  Both already
# reach vault through the exodus slug and BOSH through the deployment
# name, so the check is narrow in practice and catches a value that was
# never safe in those places either.  The message names the branch the
# value would have composed, because that is what makes it obvious why a
# name that was fine before this release is not fine now.
sub _validate_slug_components {
	my ($self) = @_;

	my $type = $self->config->get('deployment_type');
	if (my $why = _ref_component_errors($type)) {
		bail({exitcode => CONFIG},
			"The deployment type #R{%s} in #C{.genesis/config} is not a git ".
			"ref component: %s.\nIt names the branch #C{<env>/%s} for every ".
			"environment of this repository.",
			$type // '<unset>', $why, $type // ''
		);
	}

	# The same guard every other load-time read of the merged hierarchy
	# uses, so a legacy ci.yml sitting beside the environments is not read
	# as an environment and a genesis key that is not a hash at all cannot
	# blow the check up on its way past.
	for my $env_name ($self->_env_file_names) {
		my $genesis = $self->_merged_env_params($env_name)->{genesis};
		next unless ref($genesis) eq 'HASH' && exists $genesis->{pipeline};
		my $why = _ref_component_errors($env_name) or next;
		bail({exitcode => CONFIG},
			"The environment name #R{%s} is not a git ref component: %s.\n".
			"It names the branch #C{%s/%s}.",
			$env_name, $why, $env_name, $type
		);
	}

	return 1;
}

# }}}
# _validate_one_exodus_mount - every environment resolves the same mount {{{
#
# Under D103 the applied record lives at <exodus mount>_pipelines/<type>,
# so a pipeline whose environments kept separate mounts would have no
# single home for it.  The merged hierarchy of D79 makes the root file the
# natural place to set it, and D101's uniformity rule already argues for
# it, so the load refuses two mounts by name.
sub _validate_one_exodus_mount {
	my ($self) = @_;

	my %by_mount;
	for my $env_name ($self->_env_file_names) {
		my $genesis = $self->_merged_env_params($env_name)->{genesis};
		next unless ref($genesis) eq 'HASH' && exists $genesis->{pipeline};

		# The default is the one Genesis::Env::default_exodus_mount answers,
		# which is the secrets mount with exodus/ under it, and the secrets
		# mount is normalised before anything is appended to it so that a
		# value written without its slashes lands where the run time would
		# put it rather than one segment short.
		# An empty value is taken as written rather than as unset, because
		# Genesis::Env::exodus_mount takes it as written too, and two mounts
		# the run time tells apart have to be two mounts here as well.
		my $mount = $genesis->{exodus_mount};
		unless (defined $mount) {
			(my $secrets = $genesis->{secrets_mount} // '/secret/')
				=~ s{^/?(.*?)/?$}{/$1/};
			$mount = $secrets.'exodus/';
		}
		$mount =~ s{^/?(.*?)/?$}{/$1/};
		push @{$by_mount{$mount}}, $env_name;
	}
	return 1 if keys(%by_mount) < 2;

	bail({exitcode => CONFIG},
		"Every environment of a pipeline must resolve one #C{genesis.exodus_mount}, ".
		"because the pipeline's applied record lives at ".
		"#C{<exodus mount>_pipelines/<type>}.\nThis repository resolves %s.\n".
		"Set the mount once, in the root environment file the others inherit.",
		join('; ', map {sprintf("#R{%s} for %s", $_, join(', ', sort @{$by_mount{$_}}))}
			sort keys %by_mount)
	);
}

# }}}
# _validate_pipeline_config - the checks a declarative schema cannot state {{{
#
# Runs from _validate_config after Genesis::Config::validate, for every
# command, under D28.  What it checks, in what order, and what each check
# refuses is in this module's POD under _validate_pipeline_config, so the
# account lives in one place as the sub grows.  Later work extends the sub
# and leaves the one call site in _validate_config alone.
sub _validate_pipeline_config {
	my ($self) = @_;

	return 1 unless $self->config->get('pipeline.enabled');

	# First, because both halves of the deployment slug name the branches
	# everything below this is about, and a name that cannot compose a ref
	# is worth saying before anything is said about what it configures.
	$self->_validate_slug_components;

	$self->_source_control;

	# Before the environment blocks are read for their shape, because a key
	# with no ability behind it is a fact about the provider rather than
	# about how the operator wrote the block.
	$self->_validate_capability_gates;

	# After the provider is settled, because a store that cannot be used is
	# a fact about the pipeline as a whole rather than about any one
	# provider, and before the environment blocks are read for their shape.
	$self->_validate_manifest_store;

	# After the store, because the mount is where that store keeps the
	# pipeline's own applied record, and before the environment blocks are
	# read for their shape.
	$self->_validate_one_exodus_mount;

	# Every environment's genesis.pipeline block, read merged under D79.
	# A file whose genesis key is not a hash at all carries no block to
	# check, and is left to whatever reads the environment itself.
	for my $env_name ($self->_env_file_names) {
		my $params  = $self->_merged_env_params($env_name);
		my $genesis = $params->{genesis};
		next unless ref($genesis) eq 'HASH';
		next unless exists $genesis->{pipeline};
		$self->_validate_env_pipeline_block($env_name, $genesis->{pipeline});
	}

	return 1;
}

# }}}
# _validate_capability_gates - refuse a key whose capability is false {{{
#
# Under D101 a key is the operator's choice inside an ability the provider
# has.  Where the ability is absent the key cannot mean anything, so it is
# refused at load naming both the key and the capability, rather than
# being accepted and quietly ignored when the pipeline is emitted.
sub _validate_capability_gates {
	my ($self) = @_;

	# Every provider declares its abilities under D105, so there is a
	# declaration to gate against for each of them and nothing here asks
	# whether a provider has a class.  The type comes through the accessor
	# rather than off the key, because the gates are reached only from
	# _validate_pipeline_config, which has already returned for a
	# repository with no pipeline, so the accessor always has an answer.
	require Genesis::CI::Provider;
	require Genesis::CI::ProviderRegistry;
	my $type  = $self->pipeline_provider_type;
	my $class = Genesis::CI::ProviderRegistry->provider_class($type);
	my $caps  = Genesis::CI::Provider->declared_capabilities($class);
	my $gates = Genesis::CI::Provider->capability_gates;

	# The gates that are going to fire are separated by where their key
	# lives before anything is read, so the environment files are walked
	# once rather than once for every capability.
	my (%env_gates, %repo_gates);
	for my $capability (sort keys %$gates) {
		next if $caps->{$capability};
		my $key = $gates->{$capability};
		if ($key =~ s/^genesis\.pipeline\.//) {
			$env_gates{$key} = $capability;
		} else {
			$repo_gates{$key} = $capability;
		}
	}
	return 1 unless %env_gates || %repo_gates;

	# The repository-wide key is read for what the operator wrote and not
	# for what the schema filled, because a gate is about the choice inside
	# an ability and a default is the provider's own answer rather than
	# anybody's choice.  is_set reads the loaded and set layers alone, and
	# has would look through the merged contents and cannot tell a filled
	# default from a written key.  The per-environment half needs no such
	# care, reading the files themselves, where no default is ever applied.
	my @errors;
	for my $key (sort keys %repo_gates) {
		next unless $self->config->is_set($key);
		push @errors, sprintf(
			"#R{%s}: the #C{%s} provider does not declare the #C{%s} capability",
			$key, $type, $repo_gates{$key}
		);
	}

	if (%env_gates) {
		for my $env_name ($self->_env_file_names) {
			my $genesis = $self->_merged_env_params($env_name)->{genesis};
			next unless ref($genesis) eq 'HASH';
			my $block = $genesis->{pipeline};
			next unless ref($block) eq 'HASH';
			for my $key (sort keys %env_gates) {
				next unless exists $block->{$key};
				push @errors, sprintf(
					"#R{genesis.pipeline.%s} in #C{%s}: the #C{%s} provider ".
					"does not declare the #C{%s} capability",
					$key, $env_name, $type, $env_gates{$key}
				);
			}
		}
	}

	bail({exitcode => CONFIG},
		"Configuration validation failed for #C{%s}:%s",
		$self->path('.genesis/config'),
		join('', map {"\n[[".Genesis::Term::bullet('', inline => 1, indent => 0).">>$_"} @errors)
	) if @errors;

	return 1;
}

# }}}
# _validate_manifest_store - the store a pipeline repository may use {{{
#
# D14 requires the exodus store under a pipeline and D63 makes the
# refusal permanent and puts it here, where every command sees it, rather
# than in the compiler's validator, where a deploy never met it.  The
# certified commit and the applied, hold and proposed records all live in
# exodus, so an environment whose manifests live only in git still needs
# every one of them and the routing cannot run without them.
#
# The floor case is the same refusal reached another way.  An environment
# whose kit declares a Genesis floor below 3.1.0 is forced onto the
# repository store at runtime whatever the configuration says, because
# earlier versions cannot update the exodus deployment audit data, so the
# deploy would commit manifests onto the deployment branch that the
# propagation writer also advances.  That is the two-writer case, and the
# remedy is the kit's floor rather than the store's value.
sub _validate_manifest_store {
	my ($self) = @_;

	# The key is read with no fallback of its own, because the schema
	# declares the default and a second one here would read an explicit null
	# as exodus instead of refusing it by name.  A configuration that has
	# not met the version 2 schema yet, which is a version 1 file on its way
	# through _upgrade_config_to_v2, is the case where nothing supplies it.
	my $store = $self->config->get('manifest_store');
	bail({exitcode => CONFIG},
		"#R{manifest_store: %s} cannot be used under a pipeline.\n".
		"The certified commit and the applied, hold and proposed records ".
		"live in exodus, so the store must be #C{exodus}.",
		$store // '<unset>'
	) unless defined $store && $store eq 'exodus';

	# The floor a deploy actually honours is the effective one, which is
	# the higher of the repository's own minimum and the environment's, the
	# same pair Genesis::Env::effective_minimum_version takes the maximum
	# of.  Reading the environment's line alone would refuse a repository
	# whose own floor already lifts it, over a number the run time would
	# never honour.
	my $repo_min = $self->config->get('minimum_version', '') =~ s/^v//r;
	for my $env_name ($self->_env_file_names) {
		my $params = $self->_merged_env_params($env_name);
		my $genesis = $params->{genesis};
		next unless ref($genesis) eq 'HASH';
		my $env_min = $genesis->{min_version}
			// $genesis->{minimum_version}
			// '';
		$env_min =~ s/^v//;

		my @declared = grep {length $_} ($env_min, $repo_min);
		next unless @declared;
		my $floor = shift @declared;
		for my $version (@declared) {
			$floor = $version if new_enough($version, $floor);
		}
		next if new_enough($floor, '3.1.0');

		bail({exitcode => CONFIG},
			"The environment #C{%s} has a Genesis floor below #C{3.1.0}, ".
			"which forces the repository store whatever #C{manifest_store} ".
			"says.\nRaise the kit's floor to #C{3.1.0} or later, or raise ".
			"#C{genesis.min_version} where it is set by hand.",
			$env_name
		);
	}

	return 1;
}

# }}}
# _merged_env_params - an environment's merged parameters, without a kit {{{
#
# Genesis resolves an environment by merging its ancestral hierarchy, with
# the nearer file winning, and under D79 every genesis.pipeline.* read
# follows that rule.  This is the load-time form of that read: it works
# from the name through Genesis::Env::relate_by_name, loads the files that
# exist, and deep-merges them.  It builds no Genesis::Env and needs no
# kit, so validation at load stays a read of the files on disk.
sub _merged_env_params {
	my ($self, $env_name) = @_;

	# Five call sites walk every environment, and every pass used to spawn
	# one spruce run per file, so an ancestor was parsed once per descendant
	# per pass.  The answer is kept on the instance instead, which leaves
	# every one of those callers as it was written.
	#
	# There is no invalidator and none is wanted yet.  All five run from
	# _validate_pipeline_config, config runs that once behind its own memo,
	# and nothing writes an environment file between the first read and the
	# last.  _validate_env_pipeline_block is the only caller that writes
	# into what it was handed, and it copies the top level before it does.
	# A caller added after a file is written would need one.
	return $self->{__merged_env_params}{$env_name}
		if $self->{__merged_env_params}{$env_name};

	require Genesis::Env;

	# The deployment root is handed over as both bases, because with no
	# other environment to relate to every token of the name is unique and
	# the whole hierarchy comes back off the unique base.  Naming the root
	# once would leave those files relative to the working directory.
	my %merged;
	for my $file (Genesis::Env::relate_by_name(
			$env_name, undef, $self->path, $self->path)) {
		next unless -f $file;

		# A file that will not parse is refused rather than skipped: under
		# D79 a key can live anywhere in the hierarchy, so a file nobody
		# could read is a key nobody can see, which is the silent wrong
		# answer this read exists to prevent.
		my ($params, $rc, $err) = load_yaml_file($file);
		bail({exitcode => CONFIG},
			"An environment file could not be read as YAML.\n".
			"  #C{%s}%s\n".
			"Every environment file has to parse before anything can be ".
			"said about what the pipeline reads from it.",
			humanize_path($file), ($err ? "\n$err" : '')
		) if $rc;
		next unless ref($params) eq 'HASH';

		%merged = %{deep_merge(\%merged, $params)};
	}
	return $self->{__merged_env_params}{$env_name} = \%merged;
}

# }}}
# _env_file_names - the environment names the deployment root holds {{{
#
# A glob of the root's *.yml files, which is what the load can see without
# building a Genesis::Env, and which is enough for a check that only reads
# the merged parameters.
sub _env_file_names {
	my ($self) = @_;
	my @names;
	require File::Glob;
	for my $path (File::Glob::bsd_glob($self->path('*.yml'))) {
		# Three later checks read this list and every one of them opens what
		# it is handed, and a directory whose name ends in .yml is not an
		# environment file however much it looks like one.
		next unless -f $path;
		my $name = (split m{/}, $path)[-1];
		$name =~ s/\.yml$//;
		push @names, $name;
	}
	return sort @names;
}

# }}}
# _validate_env_pipeline_block - check one environment's block {{{
#
# The same declarative rules Genesis::Config applies to the repository's
# own section, applied to a block that lives in an environment file.  The
# block is validated through a throw-away in-memory Genesis::Config, so
# the types, the defaults, the required flags, and the unknown-key refusal
# are the ones the repository configuration already gets, and there is no
# second validator to keep in step with the first.  We catch its bail so
# the message can name the environment and carry the CONFIG code.
sub _validate_env_pipeline_block {
	my ($self, $env_name, $block) = @_;

	# A block that is not a hash at all goes to the validator as it stands,
	# so the answer is the declaration's own refusal rather than a Perl
	# error out of the checks below.
	my %block = ref($block) eq 'HASH' ? %$block : ();

	# D21 lets an operator write one crontab expression where a list is
	# declared, and the other list keys are owed the same courtesy, so a
	# bare string becomes a one-element list first.  Nothing is split on
	# the way, because a crontab expression carries commas of its own.
	my @list_keys = qw/redeploy_cron track_dependencies track_additional_files/;
	for my $key (@list_keys) {
		$block{$key} = [$block{$key}]
			if defined $block{$key} && !ref $block{$key};
	}

	# The shape checks below read the block as the operator wrote it.  Each
	# list key declares envsplit, and Genesis::Config answers a value that
	# is not a list by splitting it as though it came from the environment,
	# which turns a mapping into the address of a reference and hides the
	# fault from anything that reads the block afterwards.
	#
	# The copy is shallow, and that is enough while all three of these keys
	# are lists of strings: what the checks below read is the reference the
	# operator's own value came in as, and nothing between here and them
	# writes through it.  A key that grows a nested subtype would need a
	# deep copy instead.
	my %raw = map {$_ => $block{$_}} @list_keys;

	my @errors;
	my $probe = Genesis::Config->new(undef, 0,
		{pipeline => ref($block) eq 'HASH' ? \%block : $block});
	eval {$probe->validate({pipeline => $self->_pipeline_env_keys_schema}); 1}
		or do {
			# The caught text is taken before anything else is called,
			# because the readers below run evals of their own and would
			# clear it.  A refusal we cannot pick apart is still a refusal,
			# so that text stands in wherever there are no bullets in it to
			# read; without the fallback an eval that failed would leave
			# nothing behind and the block would pass.
			my $caught = $@;
			my @found  = _first_errors($caught);
			my ($first) = grep {length}
				split /\n/, decolorize($caught // 'validation failed');
			push @errors, @found ? @found : ($first // 'validation failed');
		};

	# A mapping written where a list is declared is refused outright,
	# before any entry of it is read.
	for my $key (@list_keys) {
		next unless defined $raw{$key};
		next unless ref($raw{$key}) && ref($raw{$key}) ne 'ARRAY';
		push @errors, sprintf(
			"#R{genesis.pipeline.%s}: expected a list of strings", $key);
	}

	# Two shapes the declaration cannot state.  A dependency entry is a
	# deployment type here or <env>/<type> elsewhere, and the BOSH-config
	# key is a boolean or a list of config type names.
	for my $entry (@{ref($raw{track_dependencies}) eq 'ARRAY'
			? $raw{track_dependencies} : []}) {
		push @errors, sprintf(
			"#R{genesis.pipeline.track_dependencies}: not a deployment ".
			"type or an #ri{<env>/<type>} pair: #ri{%s}",
			ref($entry) ? ref($entry).' reference' : $entry
		) unless !ref($entry) && $entry =~ m{^[^/]+(?:/[^/]+)?$};
	}
	if (exists $block{track_bosh_configs}) {
		my $v = $block{track_bosh_configs};
		push @errors, "#R{genesis.pipeline.track_bosh_configs}: expected a ".
			"boolean or a list of config types"
			unless !ref($v) || ref($v) eq 'ARRAY';
	}

	bail({exitcode => CONFIG},
		"Configuration validation failed for environment #C{%s}:%s",
		$env_name,
		join('', map {"\n[[".Genesis::Term::bullet('', inline => 1, indent => 0).">>$_"} @errors)
	) if @errors;

	return 1;
}

# }}}
# _first_errors - the bullet lines out of a caught validation bail {{{
#
# Genesis::Config::validate bails with the errors already formatted and
# wrapped to the terminal, so the caught text is split on the bullet the
# formatter itself uses, each error is folded back onto one line, and the
# pipeline. prefix is rewritten to the genesis.pipeline. one the operator
# actually wrote.  The bullet is asked for rather than assumed, because
# which glyph it is depends on what the terminal can render.
sub _first_errors {
	my ($caught) = @_;

	my $mark = decolorize(csprintf(
		Genesis::Term::bullet('', inline => 1, indent => 0)));
	$mark =~ s/\s+//g;
	return () unless length $mark;

	my @parts = split /\Q$mark\E/, decolorize($caught // '');
	shift @parts;  # the heading above the first bullet

	my @errors;
	for my $part (@parts) {
		# Carp::Always folds its backtrace into the bullet it was raised
		# under, so the error is cut at the first file and line behind it
		# and the stack stays out of what the operator reads.
		$part = without_backtrace($part);
		next unless length $part;
		# Anchored to the head of the folded line, because the rewrite is
		# for the key the error opens with and a value of the operator's
		# that happens to carry the word is not a key.
		$part =~ s/^pipeline(?![\w])/genesis.pipeline/;
		push @errors, $part;
	}
	return @errors;
}

# }}}
# _is_legacy_ci_file - detect whether ci.yml is a pipeline config (not an env file) {{{
sub _is_legacy_ci_file {
	my ($path) = @_;
	open my $fh, '<', $path or return 0;
	while (<$fh>) {
		return 1 if /^pipeline:/;
		return 0 if /^kit:/ || /^genesis:/;
	}
	close $fh;
	return 0;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
