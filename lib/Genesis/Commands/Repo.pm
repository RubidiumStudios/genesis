package Genesis::Commands::Repo;

use strict;
use warnings;

use Genesis;
use Genesis::Commands;
use Genesis::Top;
use Genesis::Kit::Provider;
use Genesis::UI;

use Cwd qw/getcwd abs_path/;
use File::Basename qw/basename/;
use File::Path qw/rmtree/;
use JSON::PP qw/encode_json/;

sub init {
	my %options;
	# FIXME: The following might work, but it may need some tweaking as it used to
	# run before the regular option parser.
	Genesis::Kit::Provider->parse_opts(\@_, \%options);
	append_options(%options);
	%options = %{get_options()};

	command_usage(1) if @_ > 1; # name is now optional if kit specified
	command_usage(1, "You can only specify one of kit (-k) or link to a kit (-L)")
		if scalar(grep {$_ =~ /^(?:kit|link-dev-kit)$/} keys %options) > 1;

	my $abs_target;
	my $kit_desc = "";
	my $kit_path = undef;
	if (exists($options{'kits-path'})) {
		$kit_path = abs_path($options{'kits-path'}//$ENV{HOME}.'/.genesis/kits');
		mkdir_or_fail ($kit_path) unless -d $kit_path;
		delete($options{'kits-path'});
	}
	if ($options{'link-dev-kit'}) {
		$abs_target = abs_path($options{'link-dev-kit'});
		my $pwd = getcwd;
		bail(
			"Link target '%s' cannot be found from $pwd!", $options{'link-dev-kit'}
		) unless $abs_target;
	}
	my $name = shift;
	my $kit_file;
	if (($options{kit}||'') =~ m#(?:.*/)?([^/]+)-\d+\.\d+\.\d+(?:-rc\.?\d+)?\.t(?:ar\.)?gz#) {
		bail (
			"Local compiled kit file %s not found", $options{kit}
		) unless -f $options{kit};
		$kit_file = $options{kit};
		$name = $1 unless $name;
	}

	unless ($name) {
		if ($options{kit} && ! $kit_file) {
			($name = $options{kit}) =~ s|/.*||;
		} elsif ($options{'link-dev-kit'}) {
			$name = basename($options{'link-dev-kit'});
		}
	}
	command_usage(1, "You must specify a deployment name if you don't specify a kit or a dev link target.\n")
		unless $name;

	if ($ENV{GIT_AUTHOR_NAME}) {
		$ENV{GIT_COMMITTER_NAME} ||= $ENV{GIT_AUTHOR_NAME};
	} else {
		run(
			{ onfailure => 'Please setup git: git config --global user.name "Your Name" -or- export GIT_AUTHOR_NAME="Your Name"' },
			'git config user.name'
		);
	}
	if ($ENV{GIT_AUTHOR_EMAIL}) {
		$ENV{GIT_COMMITTER_EMAIL} ||= $ENV{GIT_AUTHOR_EMAIL};
	} else {
		run(
			{ onfailure => 'Please setup git: git config --global user.email your@email.com -or- export GIT_AUTHOR_EMAIL=your@email.com' },
			'git config user.email'
		);
	}

	my $top = Genesis::Top->create('.', $name, %options, kits_path => $kit_path);
	my $vault_desc = "\n - using default safe target for the system";
	if ($top->vault) {
		$vault_desc = "\n - using vault at #C{".$top->vault->url."}";
		$vault_desc .= " #Y{(insecure)}" unless $top->vault->tls;
		$vault_desc .= " #Y{(noverify)}" if $top->vault->tls && ! $top->vault->verify;
	}
	$top->embed($ENV{GENESIS_CALLBACK_BIN} || $0);

	my $root = $top->path;
	my $human_root = humanize_path($root);
	pushd($root);
	eval {
		if ($options{'link-dev-kit'}) {
			debug("Kit: linking dev to $abs_target");
			symlink_or_fail($abs_target, "./dev");
			$kit_desc = "\n - linked to kit at #C{$abs_target}.";

		} elsif ($kit_file) {
			debug("Kit: using local kit file $kit_file");
			my $target = $top->path(".genesis/kits");
			mkdir_or_fail($target);
			my $abs_src = $kit_file =~ m#^/# ? $kit_file : abs_path($ENV{GENESIS_CALLER_DIR}."/".$kit_file);
			copy_or_fail($abs_src, $target);
			$kit_desc = "\n - using locally provided compiled kit #C{$kit_file}.";

		} elsif ($options{kit}) {
			debug("Kit: installing kit $options{kit}");
			my ($kit_name, $kit_version) = $top->download_kit($options{kit});
			$kit_desc = "\n - using the #C{$kit_name/$kit_version} kit.";

		} else {
			debug("Kit: creating empty ./dev kit directory");
			mkdir_or_fail("./dev");
			$kit_desc = "\n - with an empty development kit in #C{$human_root/dev}";
		}

		run({ onfailure => "Failed to initialize a git repository in $human_root/" },
			'git init && git add .');

		# Show a summary of what was staged
		my ($stat) = run({}, 'git diff --cached --stat');
		if ($stat && $stat =~ /\S/) {
			info "\n#G{Files staged for initial commit:}";
			for my $line (split /\n/, $stat) {
				info "  %s", $line;
			}
			info "";
		}

		my $do_commit;
		if ($options{commit}) {
			$do_commit = 1;
		} elsif ($options{'no-commit'}) {
			$do_commit = 0;
		} else {
			$do_commit = prompt_for_boolean(
				"Commit initial state? [y|n]", "y"
			);
		}

		if ($do_commit) {
			run({ onfailure => "Failed to commit initial Genesis repository in $human_root/" },
				'git commit -m "Initial Genesis Repo"');
		}
	};
	my $err = $@;
	popd;
	if ($err) {
		debug("removing incomplete Genesis deployments repository at #C{$root} due to failed creation");
		rmtree $root;
		bail $err;
	}
	info "\nInitialized empty Genesis repository in #C{%s}%s%s\n", $human_root, $vault_desc, $kit_desc;
	exit 0;
}

sub secrets_provider {
	command_usage(1) if @_ > 1; # target is optional

	my %options = %{get_options(qw(interactive clear))};
	$options{target} = shift if scalar(@_);
	bail("You can only specify one of target, -i|--interactive or -c|--clear")
		if scalar(keys %options) > 1;

	my $ui_nl = $options{interactive} ? "" : "\n";

	my $top = Genesis::Top->new('.', no_vault => 1);
	my $err;
	if (scalar(keys %options)) {
		$err = $top->set_vault(%options);
		error "$ui_nl$err\nCurrent vault was not changed.\n" if $err;
	}

	info("${ui_nl}Secrets provider for #C{%s} deployment at #M{%s}:", $top->type, $top->path);
	my %vault_info = $top->vault_status;
	if (%vault_info) {
		if ($vault_info{status} eq "unauthenticated") {
			eval {$top->vault->authenticate}; # Try to auto-authenticate
			%vault_info = $top->vault_status;
		}
		info(
			"         Type: #G{%s}\n".
			"          URL: #G{%s} %s\n".
			"  Local Alias: #%s{%s}\n".
			"       Status: #%s{%s}\n",
			"Safe/Vault", $vault_info{url}, $vault_info{security},
			$vault_info{alias_error} ? "R" : "G",
			$vault_info{alias} ? $vault_info{alias} : "$vault_info{alias_error}",
			$vault_info{status} eq "ok" ? "G" : "R",
			$vault_info{status}
		);
	} else {
		info "\n#Y{Not set - legacy mode enabled (will use current safe target on system)}\n";
	}

	exit defined($err) ? 1 : 0;
}

sub kit_provider {
	my %options;
	Genesis::Kit::Provider->parse_opts(\@_, \%options);
	%options = %{append_options(%options)};
	my $cfg_export = delete($options{'export-config'});
	bail "Option #M{--export-config} cannot be used with any other options"
		if ($cfg_export && scalar(keys(%options)));

  my $verbose = delete($options{verbose});
	if (delete($options{default})) {
		$options{'kit-provider'} = 'genesis-community';
	}
	command_usage(1) if @_ > 0;

	my $top = Genesis::Top->new('.');
	my $err;
	my $kit_provider_lookup = "current";
	if (scalar(grep {$_ =~ /^kit-provider/} keys %options)) {
		$err = $top->set_kit_provider(%options);
		if ($err) {
			error "\n#R{[ERROR]} Current kit provider was not changed - reason:\n\n$err\n";
			exit 1;
		}
		$kit_provider_lookup = "new";
	}

	if ($cfg_export) {
		output JSON::PP::encode_json({$top->kit_provider->config});
		exit 0
	}

	info(
		"\nCollecting information on %s kit provider for #C{%s} deployment at #M{%s}",
		$kit_provider_lookup, $top->type, humanize_path($top->path)
	);
	my %info;
	eval {
		%info = $top->kit_provider_info($verbose);
	};
	info("Complete.\n");

	bail "$@" if $@;

	info("         Type: #M{%s}\n", $info{type});
	info("%13s: #C{%s}", $_, $info{$_}) for (@{$info{extras} || []});
	info("\n       Status: #%s{%s}\n", $info{status} eq "ok" ? "G" : "R", $info{status});

	my $kit_list;
	if (ref($info{kits}) eq "HASH" && scalar(keys(%{$info{kits}}))) {
		my $width = (sort {$b <=> $a} map {length($_)} keys %{$info{kits}})[0];
		$kit_list = join("\n               ",
										 map {
											 sprintf("#%s{%-${width}s} [%s]", $_ eq $top->type ? 'G' : '-', $_, $info{kits}->{$_})
										} sort keys(%{$info{kits}})
								);
	} elsif (ref($info{kits}) eq "ARRAY" && scalar(@{$info{kits}})) {
		$kit_list = join("\n               ", map {sprintf("#%s{%s}", $_ eq $top->type ? 'G' : '-', $_)} @{$info{kits}});
	} elsif (ref($info{kits}) eq "" && ($info{kits} || "") =~ /^[1-9][0-9]*$/) {
		$kit_list = $info{kits} . "kit" . ($info{kits} == 1 ? "" : "s");
	} else {
		$kit_list = "#Yi{None}";
	}
	info("         Kits: %s\n\n", $kit_list) if $info{status} eq "ok";
}

sub repo_init {
	my %options = %{get_options()};
	command_usage(1) if @_;

	my $top = Genesis::Top->new('.', no_vault => 1);

	bail(
		"CI provider already configured (#C{%s}).\n".
		"Use #C{genesis repo-update} to modify the existing configuration.",
		$top->config->get('ci.provider')
	) if $top->config->has('ci.provider');

	my $cfg = _ci_wizard(\%options, $top, _empty_ci_defaults($top));
	_write_ci_config($top, $cfg);

	info(
		"\n#G{CI configuration initialized}\n".
		"  Provider : #C{%s}\n".
		"  Config   : #C{.genesis/config}\n".
		"  Scaffold : #C{.genesis/ci/}\n\n".
		"Add environment targets to #C{.genesis/ci/targets.yml}, then run\n".
		"#C{genesis pipeline-apply} to deploy the pipeline.\n",
		$cfg->{ci_provider}
	);
	exit 0;
}

sub repo_update {
	my %options = %{get_options()};
	command_usage(1) if @_;

	my $top = Genesis::Top->new('.', no_vault => 1);

	unless ($top->config->has('ci.provider')) {
		warning(
			"CI provider is not configured for this repository.\n".
			"Use #C{genesis repo-init} to set up CI from scratch."
		);
	}

	my @flag_keys = keys %options;

	if (@flag_keys) {
		# Non-interactive: apply only the provided flags, leave everything else alone
		_apply_ci_flags(\%options, $top);
	} else {
		# Bare invocation: full wizard with existing values pre-populated
		my $cfg = _ci_wizard(\%options, $top, _existing_ci_defaults($top));
		_write_ci_config($top, $cfg, update => 1);
	}

	info(
		"\n#G{CI configuration updated}\n".
		"  Provider : #C{%s}\n".
		"  Config   : #C{.genesis/config}\n".
		"  Scaffold : #C{.genesis/ci/}\n",
		$top->config->get('ci.provider') // '(none)'
	);
	exit 0;
}

### Private helpers ###########################################################

# _empty_ci_defaults - blank defaults for repo_init wizard
sub _empty_ci_defaults {
	my ($top) = @_;
	return {
		ci_provider   => 'concourse',
		git_uri       => '',
		git_branch    => 'main',
		vault_url     => '',
		pipeline_name => $top->type,
	};
}

# _existing_ci_defaults - load current values for repo_update wizard
sub _existing_ci_defaults {
	my ($top) = @_;

	my $defaults = _empty_ci_defaults($top);
	$defaults->{ci_provider} = $top->config->get('ci.provider')
		if $top->config->has('ci.provider');

	my $ci_dir = $top->path('.genesis/ci');
	if (-f "$ci_dir/integrations.yml") {
		eval {
			my $raw = slurp("$ci_dir/integrations.yml");
			# Extract vault.url: capture only within the vault: block, stopping
			# before the next top-level key (no leading spaces) to avoid matching
			# url: keys in other sections.
			if ($raw =~ /^vault:\s*\n((?:[ \t]+[^\n]*\n)*)/m) {
				my $vault_block = $1;
				$defaults->{vault_url} = $1 if $vault_block =~ /url:\s*(\S+)/;
			}
			# source_control.uri and default_branch are unique keys in our schema
			if ($raw =~ /uri:\s*(\S+)/) {
				$defaults->{git_uri} = $1;
			}
			if ($raw =~ /default_branch:\s*(\S+)/) {
				$defaults->{git_branch} = $1;
			}
		};
	}

	if (-f "$ci_dir/pipeline.yml") {
		eval {
			my $raw = slurp("$ci_dir/pipeline.yml");
			if ($raw =~ /name:\s*(\S+)/) {
				$defaults->{pipeline_name} = $1;
			}
		};
	}

	return $defaults;
}

# _ci_wizard - prompt for any config values not supplied as flags
sub _ci_wizard {
	my ($options, $top, $defaults) = @_;

	my $ci_provider = $options->{'ci-provider'} // do {
		prompt_for_choice(
			"CI provider:",
			[qw(concourse github-actions none)],
			$defaults->{ci_provider},
		);
	};

	my $pipeline_name = $options->{'pipeline-name'} // do {
		prompt_for_line(
			"Pipeline name:",
			"pipeline name",
			$defaults->{pipeline_name},
		);
	};

	my $git_uri = $options->{'git-uri'} // do {
		prompt_for_line(
			"Git repository URI (e.g. git\@github.com:org/repo.git):",
			"git uri",
			$defaults->{git_uri},
		);
	};

	my $git_branch = $options->{'git-branch'} // do {
		prompt_for_line(
			"Default branch:",
			"branch",
			$defaults->{git_branch},
		);
	};

	my $vault_url = $options->{'vault-url'} // do {
		prompt_for_line(
			"Vault URL (e.g. https://vault.example.com:8200):",
			"vault url",
			$defaults->{vault_url},
		);
	};

	return {
		ci_provider   => $ci_provider,
		pipeline_name => $pipeline_name,
		git_uri       => $git_uri,
		git_branch    => $git_branch,
		vault_url     => $vault_url,
	};
}

# _apply_ci_flags - non-interactive partial update (repo_update with flags)
sub _apply_ci_flags {
	my ($options, $top) = @_;

	unless ($top->config->has('ci.provider') || exists $options->{'ci-provider'}) {
		warning(
			"CI provider not configured and --ci-provider not given.\n".
			"Run #C{genesis repo-init} to perform initial CI setup."
		);
	}

	if (exists $options->{'ci-provider'}) {
		my $provider = $options->{'ci-provider'};
		bail(
			"Unknown CI provider '#R{%s}'. Valid values: concourse, github-actions, none.",
			$provider
		) unless grep { $_ eq $provider } qw(concourse github-actions none);
		$top->config->set('ci.provider', $provider, 1);
	}

	my $ci_dir = $top->path('.genesis/ci');
	mkdir_or_fail($ci_dir) unless -d $ci_dir;

	# Update integrations.yml in-place if any integration flags were given
	my @integration_flags = grep { exists $options->{$_} } qw(git-uri git-branch vault-url);
	if (@integration_flags && -f "$ci_dir/integrations.yml") {
		my $raw = slurp("$ci_dir/integrations.yml");
		if (exists $options->{'vault-url'}) {
			my $v = $options->{'vault-url'};
			$raw =~ s/^(\s{0,4}url:\s*)\S+/$1$v/m;
		}
		if (exists $options->{'git-uri'}) {
			my $v = $options->{'git-uri'};
			$raw =~ s/^(\s{0,4}uri:\s*)\S+/$1$v/m;
		}
		if (exists $options->{'git-branch'}) {
			my $v = $options->{'git-branch'};
			$raw =~ s/^(\s{0,4}default_branch:\s*)\S+/$1$v/m;
		}
		mkfile_or_fail("$ci_dir/integrations.yml", $raw);
	} elsif (@integration_flags) {
		# integrations.yml doesn't exist yet - need full defaults to write it
		my $defaults  = _existing_ci_defaults($top);
		$defaults->{'vault-url'}   = $options->{'vault-url'}   if exists $options->{'vault-url'};
		$defaults->{'git-uri'}     = $options->{'git-uri'}     if exists $options->{'git-uri'};
		$defaults->{'git-branch'}  = $options->{'git-branch'}  if exists $options->{'git-branch'};
		_write_integrations($ci_dir, $defaults);
	}

	# Write provider override scaffold if provider changed and file is absent
	if (exists $options->{'ci-provider'} && $options->{'ci-provider'} ne 'none') {
		_write_if_absent("$ci_dir/ci-overrides-$options->{'ci-provider'}.yml",
			_overrides_scaffold($options->{'ci-provider'}));
	}

	# Ensure other scaffold stubs exist
	_write_if_absent("$ci_dir/targets.yml",  _targets_scaffold());
	_write_if_absent("$ci_dir/resources.yml", _resources_scaffold());
}

# _write_ci_config - write config key and scaffold directory for init/full update
sub _write_ci_config {
	my ($top, $cfg) = @_;

	my $provider = $cfg->{ci_provider};

	$top->config->set('ci.provider', $provider, 1);

	my $ci_dir = $top->path('.genesis/ci');
	mkdir_or_fail($ci_dir) unless -d $ci_dir;

	# integrations.yml — always write (contains wizard-collected values)
	_write_integrations($ci_dir, $cfg);

	# Remaining scaffold files: write only if absent (preserve manual edits on update)
	_write_if_absent("$ci_dir/targets.yml",   _targets_scaffold());
	_write_if_absent("$ci_dir/resources.yml", _resources_scaffold());
	if ($provider ne 'none') {
		_write_if_absent("$ci_dir/ci-overrides-${provider}.yml",
			_overrides_scaffold($provider));
	}
}

# _write_integrations - write .genesis/ci/integrations.yml from collected config
sub _write_integrations {
	my ($ci_dir, $cfg) = @_;

	my $vault_url     = $cfg->{vault_url}   // $cfg->{'vault-url'}   // '';
	my $git_uri       = $cfg->{git_uri}     // $cfg->{'git-uri'}     // '';
	my $git_branch    = $cfg->{git_branch}  // $cfg->{'git-branch'}  // 'main';

	mkfile_or_fail("$ci_dir/integrations.yml", <<"YAML");
---
vault:
  url: $vault_url
  namespace: genesis
  auth:
    type: approle
    role_id: ((vault-role-id))
    secret_id: ((vault-secret-id))
  options:
    tls_verify: true

source_control:
  provider: github
  uri: $git_uri
  default_branch: $git_branch
  root: "."
  auth:
    type: ssh-key
    private_key: ((github-deploy-key))
  commit_author:
    name: Concourse Bot
    email: ci\@example.com
YAML
}

sub _write_if_absent {
	my ($path, $content) = @_;
	mkfile_or_fail($path, $content) unless -f $path;
}

sub _targets_scaffold {
	return <<'YAML';
---
# targets.yml - BOSH director targets for pipeline deployments.
# Add one stanza per environment. The key name must match the environment
# name used in pipeline topology declarations (genesis.pipeline.prior_env).
#
# Example:
#   sandbox:
#     name: sandbox
#     alias: us-west-1-sandbox
#     type: bosh-director
#     tags: []
#     connection:
#       url: https://bosh.sandbox.example.com:25555
#       auth:
#         type: basic
#         client_id: admin
#         client_secret: ((sandbox-bosh-password))
#       ca_cert: ((sandbox-bosh-ca))
targets: {}
YAML
}

sub _resources_scaffold {
	return <<'YAML';
---
# resources.yml - Additional CI resources.
# Add custom Concourse resource definitions or GitHub Actions inputs here.
resources: []
YAML
}

sub _overrides_scaffold {
	my ($provider) = @_;
	return <<"YAML";
---
# ci-overrides-${provider}.yml
# Spruce-merged over generated pipeline YAML after provider output.
# Supports all spruce operators: (( grab )), (( inject )), (( append )), etc.
# Leave empty or remove this file to use the default generated pipeline.
YAML
}

1;
# vim: fdm=marker:foldlevel=0:noet
