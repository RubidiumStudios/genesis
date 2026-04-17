package Genesis::Commands::Repo;

use strict;
use warnings;

use Genesis;
use Genesis::Commands;
use Genesis::Term qw/in_controlling_terminal/;
use Genesis::Top;
use Genesis::UI;

use Cwd qw/getcwd abs_path/;
use File::Basename qw/basename dirname/;
use File::Path qw/rmtree/;
use JSON::PP qw/encode_json/;

# ==============================================================================
# repo-init (replaces init)
# ==============================================================================

sub repo_init {
	_repo_init_validate();
	_repo_init_report(scalar _repo_init_execute());
	exit 0;
}

# -- Phase 1: Validation (parse + validate + gather + prompt) ------------------
#
# Order within validation:
#   1. Parse options and derive values (fast, no side effects)
#   2. Check invalid option combinations (fast bail)
#   3. Gather data: validate local sources, detect git repo (no network)
#   4. Subdir preflight: dirty check, control-branch check
#   5. Check destructive prerequisites (existing directory, before network)
#   6. Validate remote kit availability (network calls)
#   7. Prompt for missing info (vault, CI provider wizard)
#   8. Store derived values and summarize intent
#
sub _repo_init_validate {
	# Passthrough options (e.g. --kit-provider-*) have already been
	# parsed by the framework's extended_handlers and are available in
	# get_options()->{kit_provider}.  @args from get_args()
	# contains only true positional arguments.
	my %opts = %{get_options()};
	my @args = get_args();

	# --- 1. Parse and derive ---

	my $name = $args[0];
	my $kit_file;

	# Check if kit is a local file path
	if ($opts{kit} && $opts{kit} =~ m#(?:.*/)?([^/]+)-\d+\.\d+\.\d+(?:-rc\.?\d+)?\.t(?:ar\.)?gz#) {
		$kit_file = $opts{kit};
		$name = $1 unless $name;
	}

	# Derive name from kit or link-dev-kit if not specified
	unless ($name) {
		if ($opts{kit} && !$kit_file) {
			($name = $opts{kit}) =~ s|/.*||;
		} elsif ($opts{'link-dev-kit'}) {
			$name = basename($opts{'link-dev-kit'});
		}
	}

	my $dir = $opts{directory} || $name;
	my $parent_dir = abs_path(getcwd());
	my $target_path = "$parent_dir/$dir";

	# --- 2. Check invalid option combinations ---

	bail(
		"You must specify a deployment name, a kit (-k), or a dev link target (-l)."
	) unless $name;

	bail(
		"You can only specify one of kit (-k) or link to a kit (-l)."
	) if $opts{kit} && $opts{'link-dev-kit'};

	bail(
		"Cannot specify both --vault and --skip-vault."
	) if $opts{vault} && $opts{'skip-vault'};

	# CI provider options (--ci-provider, --ci-target, etc.) have been
	# parsed by the framework's extended_handlers into the ci_provider
	# slot.  We extract the opts hash here for quick flag checks (e.g.
	# branch validation), but defer building the actual provider object
	# until step 6 (after directory/kit validation passes) so the
	# interactive wizard doesn't run if we're going to bail anyway.
	my %ci_provider_opts = %{$opts{ci_provider} // {}};

	# --- 3. Gather data: validate local sources, detect git repo ---

	# Validate local kit sources exist
	if ($kit_file) {
		bail("Local compiled kit file '%s' not found.", $kit_file)
			unless -f $kit_file;
	}
	if ($opts{'link-dev-kit'}) {
		bail("Dev kit link target '%s' not found.", $opts{'link-dev-kit'})
			unless -e $opts{'link-dev-kit'};
	}

	# Check git author config
	if ($ENV{GIT_AUTHOR_NAME}) {
		$ENV{GIT_COMMITTER_NAME} ||= $ENV{GIT_AUTHOR_NAME};
	} else {
		run({ onfailure => 'Please setup git: git config --global user.name "Your Name"' },
			'git config user.name');
	}
	if ($ENV{GIT_AUTHOR_EMAIL}) {
		$ENV{GIT_COMMITTER_EMAIL} ||= $ENV{GIT_AUTHOR_EMAIL};
	} else {
		run({ onfailure => 'Please setup git: git config --global user.email your@email.com' },
			'git config user.email');
	}

	# Guardrail: forbid creating a new Genesis repo inside (or under) an
	# existing one.  Nested Genesis repos are never correct in this
	# ecosystem -- pipeline tooling, kit discovery, and .genesis/config
	# resolution all assume a single enclosing deployment root.
	if (my $enclosing = _find_enclosing_genesis_repo()) {
		bail(
			"Cannot create a new Genesis deployment repository inside an ".
			"existing one.\n  Enclosing deployment repo: #C{%s}",
			humanize_path($enclosing)
		);
	}

	# Auto-detect whether we're inside an existing (non-Genesis) git
	# worktree.  If so, the new repo is created as a subdirectory with no
	# separate .git -- it will share history with the surrounding repo.
	# This is reported in the plan below so the user can notice an
	# unexpected enclosure.
	my $use_subdir = run({ passfail => 1 }, 'git rev-parse --is-inside-work-tree 2>/dev/null') ? 1 : 0;

	# In subdir mode, require the enclosing repo to have no staged or
	# unstaged changes to tracked files.  Untracked files are fine.
	# This means that if execution fails and we need to roll back the
	# index, we can do so without risking the user's in-progress work.
	# #C{-F|--force} bypasses this check for users who understand the
	# risk (e.g. scripted environments, known-safe index).
	if ($use_subdir && !$opts{force}) {
		my ($dirty) = run({}, 'git status --porcelain --untracked-files=no');
		if (defined($dirty) && $dirty =~ /\S/) {
			bail(
				"Cannot create a Genesis deployment repository inside an ".
				"enclosing git repository that has uncommitted changes to ".
				"tracked files.\n".
				"  Please commit, stash, or discard the following first, ".
				"or rerun with #C{-F|--force} to bypass this check:\n\n%s\n",
				$dirty
			);
		}
	}

	# In subdir mode AND when a CI provider is being configured,
	# require the enclosing repo to be on the CI control branch.
	# Genesis pipeline tooling treats this branch as the single source
	# of truth from which environment branches are cut
	# (#C{genesis new}) and against which deploys are validated
	# (#C{genesis deploy}).  We do not rename or create branches in
	# the enclosing repo -- the user must set this up themselves.  No
	# #C{--force} bypass: this is a topology requirement, not a safety
	# check.
	#
	# Without #C{--ci-provider}, no pipeline topology is being
	# established, so the branch name is irrelevant at this point.
	my $control_branch = Genesis::Top::DEFAULT_CONTROL_BRANCH();
	if ($use_subdir && $ci_provider_opts{'ci-provider'}) {
		my ($branch) = run({}, 'git rev-parse --abbrev-ref HEAD');
		chomp $branch if defined $branch;
		if (!defined($branch) || $branch ne $control_branch) {
			bail(
				"Configuring a CI provider requires the enclosing git ".
				"repository to be on a branch named #C{%s}, but it is ".
				"currently on #C{%s}.\n".
				"  Please switch to the #C{%s} branch before running ".
				"#C{repo-init --ci-provider ...}:\n\n".
				"    git checkout %s\n\n".
				"  or, if it doesn't exist yet:\n\n".
				"    git checkout -b %s\n",
				$control_branch,
				$branch // '<detached HEAD>',
				$control_branch,
				$control_branch,
				$control_branch
			);
		}
	}

	# --- 4. Check destructive prerequisites (before expensive network calls) ---

	my $replace_existing = 0;
	if (-e $target_path) {
		if ($opts{force}) {
			$replace_existing = 1;
		} elsif (in_controlling_terminal && Genesis::UI::prompt_for_boolean(
			"Directory #C{$dir} already exists. Replace it? [y|n] ", 0
		)) {
			$replace_existing = 1;
		} else {
			bail("Cannot create repository: directory #C{$dir} already exists. Use -F to force replacement.");
		}
	}

	# --- 5. Validate remote kit availability (network, after directory check) ---

	my ($resolved_kit_name, $resolved_kit_version, $kit_provider);
	if ($opts{kit} && !$kit_file) {
		($resolved_kit_name, $resolved_kit_version) = split('/', $opts{kit}, 2);

		# Kit provider options were parsed by the framework's
		# extended_handlers into the kit_provider slot.
		my %provider_opts = %{$opts{kit_provider} // {}};
		$kit_provider = eval { Genesis::Kit::Provider->init(%provider_opts) };
		bail("Could not initialize kit provider: %s", $@) if $@;

		if ($resolved_kit_version && $resolved_kit_version ne 'latest') {
			my @versions = eval { $kit_provider->kit_versions($resolved_kit_name) };
			my $exists = grep { $_->{version} eq $resolved_kit_version } @versions;
			bail("Kit '%s/%s' not found from %s.",
				$resolved_kit_name, $resolved_kit_version, $kit_provider->label) unless $exists;
		} else {
			$resolved_kit_version = eval { $kit_provider->latest_version_of($resolved_kit_name) };
			bail("Kit '%s' not found or no versions available from %s.",
				$resolved_kit_name, $kit_provider->label) unless $resolved_kit_version;
		}
	}

	# --- 6. Prompt for missing info ---
	#
	# Interactive steps are deferred until here so we don't waste the
	# user's time if validation is going to bail (directory exists,
	# kit not found, wrong branch, etc.).

	my $vault_target;
	if ($opts{'skip-vault'}) {
		# explicitly skipped
	} elsif ($opts{vault}) {
		$vault_target = $opts{vault};
	} else {
		my $vault = _select_vault_target();
		$vault_target = $vault->{name} if $vault;
	}

	# Build the CI provider object now that all preflight checks have
	# passed.  If required flags (--ci-target, etc.) were omitted and
	# we have a controlling terminal, fall back to the interactive
	# wizard to collect them.
	my $ci_provider_obj;
	if ($ci_provider_opts{'ci-provider'}) {
		$ci_provider_obj = eval { Genesis::CI::Provider->init(%ci_provider_opts) };
		if ($@) {
			if (in_controlling_terminal) {
				$ci_provider_obj = eval {
					Genesis::CI::Provider->new(type => $ci_provider_opts{'ci-provider'})
						->interactive_wizard(undef);
				};
				bail("CI provider wizard failed: %s", $@) if $@;
			} else {
				bail("Could not initialize CI provider: %s", $@);
			}
		}
	}

	# --- 7. Store derived values and summarize intent ---

	option_defaults(
		_name                 => $name,
		_dir                  => $dir,
		_parent_dir           => $parent_dir,
		_target_path          => $target_path,
		_kit_file             => $kit_file,
		_kit_provider         => $kit_provider,
		_ci_provider_obj      => $ci_provider_obj,
		_use_subdir           => $use_subdir,
		_vault_target         => $vault_target,
		_replace_existing     => $replace_existing,
		_resolved_kit_name    => $resolved_kit_name,
		_resolved_kit_version => $resolved_kit_version,
	);

	my @plan;
	if ($resolved_kit_name) {
		push @plan, "kit: #C{$resolved_kit_name/$resolved_kit_version}";
	} elsif ($kit_file) {
		push @plan, "kit: #C{$kit_file} (local)";
	} elsif ($opts{'link-dev-kit'}) {
		push @plan, "kit: dev link to #C{$opts{'link-dev-kit'}}";
	} else {
		push @plan, "kit: #Yi{empty dev directory}";
	}
	push @plan, "vault: #C{$vault_target}" if $vault_target;
	push @plan, "vault: #Yi{deferred}" unless $vault_target;
	push @plan, "ci provider: #C{" . $ci_provider_obj->label . "}" if $ci_provider_obj;
	push @plan, "subdirectory of enclosing git repo: #C{yes} (no separate .git, auto-detected)" if $use_subdir;
	info "\nCreating #C{%s} deployment repository in #M{%s/}:", $name, $dir;
	info "  %s", $_ for @plan;
	info "";

	return 1;
}

# -- Phase 2: Execution -------------------------------------------------------
#
# All validation is complete. This phase only does work — no prompts, no bails
# on user input. Failures here are unexpected errors.
#
sub _repo_init_execute {
	my (
		# Derived and validated values from validation phase (prefixed with _)
		$name,             # derived name of the deployment/repo
		$dir,              # target directory name (derived from name or specified by user)
		$parent_dir,       # parent directory where repo will be created (usually cwd)
		$target_path,      # full path to the target directory ($parent_dir/$dir)
		$kit_file,         # optional local kit file to copy into the repo
		$kit_spec,         # optional remote kit name[/version] to download
		$kit_provider,     # optional pre-built kit provider (from validation, with cached versions)
		$use_subdir,       # whether to create the repo as a subdirectory of an existing git repo
		$vault_target,     # vault target to configure, or undef to skip vault
		$replace_existing, # whether to remove existing target directory if it exists
		$linked_dev_kit,   # optional path to a local dev kit to link into the repo
		$ci_provider_obj,  # optional Genesis::CI::Provider object (from validation)

		# User provided options (validated but not altered)
		$directory,        # optional custom directory name override
		$kits_path,        # optional custom kits path
		$no_commit,        # skip the initial commit (stage only)
		$reason,           # optional commit message override
	) = get_options()->@{qw/
		_name _dir _parent_dir _target_path _kit_file kit _kit_provider _use_subdir _vault_target
		_replace_existing link-dev-kit _ci_provider_obj directory kits-path no-commit reason
	/};

	# Remove existing directory if validation approved it
	if ($replace_existing && -e $target_path) {
		info "Removing existing directory #C{%s}...", $dir;
		rmtree $target_path;
	}

	# Resolve link-dev-kit to absolute path before we potentially chdir
	my $abs_dev_target;
	if ($linked_dev_kit) {
		$abs_dev_target = abs_path($linked_dev_kit);
	}

	# Build create options for Top->create
	my %create_opts;
	if ($vault_target) {
		$create_opts{vault} = $vault_target;
	} else {
		$create_opts{skip_vault} = 1;
	}
	$create_opts{directory} = $directory if $directory;

	# Kits path handling
	my $kit_path;
	if (defined $kits_path) {
		$kit_path = abs_path($kits_path // $ENV{HOME}.'/.genesis/kits');
		mkdir_or_fail($kit_path) unless -d $kit_path;
	}

	# Create the repo via Top->create (pass kit_provider if we already built one)
	$create_opts{kit_provider} = $kit_provider if $kit_provider;
	my $top = Genesis::Top->create($parent_dir, $name, %create_opts, kits_path => $kit_path);
	$top->embed($ENV{GENESIS_CALLBACK_BIN} || $0) if $ci_provider_obj;

	my $root = $top->path;
	my $human_root = humanize_path($root);
	my $kit_desc = "";

	pushd($root);
	eval {
		# Kit setup
		if ($abs_dev_target) {
			symlink_or_fail($abs_dev_target, "./dev");
			$kit_desc = "linked to kit at #C{$abs_dev_target}";
		} elsif ($kit_file) {
			my $target = $top->path(".genesis/kits");
			mkdir_or_fail($target);
			my $abs_src = $kit_file =~ m#^/# ? $kit_file : abs_path($ENV{GENESIS_CALLER_DIR}."/".$kit_file);
			copy_or_fail($abs_src, $target);
			$kit_desc = "using locally provided compiled kit #C{$kit_file}";
		} elsif ($kit_spec) {
			my ($kit_name, $kit_version) = $top->download_kit($kit_spec);
			$kit_desc = "using the #C{$kit_name/$kit_version} kit";
		} else {
			mkdir_or_fail("./dev");
			$kit_desc = "with an empty development kit in #C{$human_root/dev}";
		}

		# CI provider scaffold
		if ($ci_provider_obj) {
			_create_ci_scaffold($top, $ci_provider_obj);
		}

		# Only create a new .git when we're not already sitting inside
		# an enclosing git worktree; in subdir mode we share the
		# parent's .git and just stage into its index.  In standalone
		# mode, if the user is establishing pipeline topology
		# (--ci-provider given), force the initial branch name to the
		# control branch so the initial commit lands there instead of
		# on whatever git's init.defaultBranch happens to be.  When
		# no CI provider is being configured, let git choose its
		# default branch -- pipeline topology is not relevant yet.
		# #C{git symbolic-ref HEAD} works on all git versions, unlike
		# #C{git init -b} which requires >= 2.28.
		unless ($use_subdir) {
			if ($ci_provider_obj) {
				my $branch = Genesis::Top::DEFAULT_CONTROL_BRANCH();
				run({ onfailure => "Failed to initialize git in $human_root/" },
					"git init && git symbolic-ref HEAD refs/heads/$branch");
			} else {
				run({ onfailure => "Failed to initialize git in $human_root/" },
					'git init');
			}
		}
		run({ onfailure => "Failed to stage repository in $human_root/" },
			'git add .');

		# Show a summary of what we just staged so the user can see
		# exactly what the initial commit (or leftover stage) contains.
		my ($stat) = run({}, 'git diff --cached --stat -- .');
		if ($stat && $stat =~ /\S/) {
			info "\n#G{Files staged for initial commit:}";
			info "  %s", $_ for split /\n/, $stat;
			info "";
		}

		# Commit unless the user explicitly opted out.  In subdir mode
		# we scope the commit with a pathspec ('-- .') so any unrelated
		# changes already staged in the enclosing repo are not bundled
		# into this commit.
		if ($no_commit) {
			info "Skipping initial commit (#C{--no-commit} set); files remain staged.";
		} else {
			my $message = $reason || "Initial Genesis repo for $name";
			my @cmd = ('git', 'commit', '-m', $message);
			push @cmd, '--', '.' if $use_subdir;
			run({ onfailure => "Failed to commit initial repository in $human_root/" }, @cmd);

			# Report the commit that was just made so the user has a
			# clear record of what was recorded (and, in subdir mode,
			# where in the enclosing repo's history to find it).
			my ($sha) = run({}, 'git rev-parse --short HEAD');
			chomp $sha if defined $sha;
			info "#G{Committed} #C{%s} -- %s", $sha // '<unknown>', $message;
		}
	};
	my $err = $@;
	eval { popd };  # always restore cwd; swallow errors to not mask $err

	# On failure, return only what the report phase needs to clean up
	# and bail -- the $top object may be in a partial state and its
	# accessors (vault, etc.) are not safe to call.
	if ($err) {
		return {
			error        => $err,
			root         => $root,
			human_root   => $human_root,
			target_path  => $target_path,
			parent_dir   => $parent_dir,
			use_subdir   => $use_subdir,
		};
	}

	# Success: the repository is created and (if requested) committed.
	# Resolving the vault URL for the report is not part of the
	# command's core purpose -- if it trips a runtime error, warn the
	# user but do NOT fail the command (the repo is already on disk).
	my %result = (
		error         => undef,
		root          => $root,
		human_root    => $human_root,
		name          => $name,
		kit_desc      => $kit_desc,
		ci_provider   => $ci_provider_obj ? $ci_provider_obj->label : undef,
		vault_skipped => $vault_target ? 0 : 1,
		vault         => $vault_target,
		submodule     => $use_subdir,
	);
	eval {
		$result{vault} = $vault_target
			? ($top->vault ? $top->vault->url : $vault_target)
			: undef;
	};
	if (my $housekeeping_err = $@) {
		warning(
			"Repository was created successfully, but a post-commit ".
			"housekeeping step failed (non-fatal):\n%s",
			$housekeeping_err
		);
	}
	return \%result;
}

# -- Phase 3: Report ----------------------------------------------------------
#
# Handles both success and failure.  On failure, cleans up any partial
# initialization (removing the new directory and, in subdir mode,
# unstaging from the enclosing repo's index) before bailing with an
# appropriate message.  On success, prints the summary.
#
sub _repo_init_report {
	my ($result) = @_;

	if ($result->{error}) {
		debug(
			"removing incomplete Genesis repository at #C{%s} due to failed creation",
			$result->{root}
		);
		# In subdir mode, unstage anything we added to the enclosing
		# repo's index before deleting the directory so the parent
		# repo's working state is left clean.  This is safe because
		# validation ensured the parent repo had no other tracked
		# changes (or the user passed --force); the pathspec scopes
		# the reset strictly to what we just staged.
		if ($result->{use_subdir}) {
			eval {
				run({ dir => $result->{parent_dir} },
					'git', 'reset', 'HEAD', '--', $result->{target_path});
			};
		}
		rmtree $result->{root} if -e $result->{root};
		bail(
			"Failed to create Genesis repository at #C{%s}:\n%s",
			$result->{human_root}, $result->{error}
		);
	}

	success "\nGenesis repository #C{%s} created successfully.\n", $result->{name};
}

# -- Helpers -------------------------------------------------------------------

# Walk upward from the current working directory looking for an
# enclosing Genesis deployment repository.  Returns the absolute path
# of the enclosing repo if found, otherwise undef.
#
# The global #C{in_repo_dir()} helper only checks cwd, and almost every
# consumer downstream uses #C{Genesis::Top->new('.')} which assumes
# cwd IS the repo root -- so teaching the global helper to walk up
# would ripple.  This variant is scoped to #C{repo-init}'s guardrail
# against creating a nested deployment repo.
sub _find_enclosing_genesis_repo {
	my $dir = abs_path(getcwd());
	while (defined($dir) && length($dir) > 1) {
		return $dir if Genesis::Top->is_repo($dir);
		my $parent = dirname($dir);
		last if $parent eq $dir;
		$dir = $parent;
	}
	return undef;
}

sub _select_vault_target {
	my $configure = Genesis::UI::prompt_for_boolean(
		"Would you like to configure a secrets vault now? [y|n] ", 1
	);
	return undef unless $configure;

	require Service::Vault::Remote;
	my $vault = eval { Service::Vault::Remote->target(undef) };
	return $vault;
}

sub _create_ci_scaffold {
	my ($top, $provider) = @_;

	# $provider may be a Genesis::CI::Provider object or a plain string (legacy).
	my %provider_cfg = ref($provider) ? $provider->config() : (type => $provider);

	$top->config->set('ci', {
		enabled  => Genesis::Config::TRUE,
		provider => \%provider_cfg,
		pipeline => {
			name => $top->config->get('deployment_type'),
		},
	});
	$top->config->save;

	my $ci_dir = $top->path(".genesis/ci");
	mkdir_or_fail($ci_dir);
	mkfile_or_fail("$ci_dir/.keep", "");
}


# ==============================================================================
# Legacy init (preserved for backward compatibility, aliased to repo-init)
# ==============================================================================

sub init {
	my %options;
	Genesis::Kit::Provider->parse_opts(\@_, \%options);
	append_options(%options);
	%options = %{get_options()};

	command_usage(1) if @_ > 1;
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

# ==============================================================================
# Other repo commands
# ==============================================================================

sub secrets_provider {
	command_usage(1) if @_ > 1;

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
			eval {$top->vault->authenticate};
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

# PARKED: this is Tristan's CI-only repo-init handler from the upstream
# merge.  It conflicts with our phased repo-init at the top of this file
# (both registered under the same command name, causing Perl to redefine
# our sub).  Renamed to repo_configure_ci as a parking slot until the
# folding meeting resolves how his CI-scaffold logic merges into our
# _create_ci_scaffold.  Not currently dispatched by any command.
sub repo_configure_ci {
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
		_write_ci_config($top, $cfg);
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

# _empty_ci_defaults - blank defaults for repo_configure_ci wizard
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
