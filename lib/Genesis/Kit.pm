package Genesis::Kit;
use strict;
use warnings;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::State;
use Genesis::Helpers;
use Genesis::Hook (); # load_failure, for kit modules that fail to load

# Ignore redefinition warnings for Addon hooks
$SIG{__WARN__} = sub {
	my $msg = shift;
	return if ($msg =~ /redefine/ && $msg =~ /Hook\/Addon.pm/);
	warn $msg;
};

### Class Methods {{{

# new - abstract class only, expects derived class to specify new body {{{
sub new {
	my ($class,$provider) = @_;
	bug "Attempt to initialize abstract class Genesis::Kit"
		if ($class eq __PACKAGE__);
}
# }}}

sub known_hooks {
	# Returns a list of known hooks that can be used in the kit.
	return qw/
		new feature blueprint info check pre-deploy post-deploy terminate
		edit shell addon
		cloud-config cpi-config features runtime-config
	/;
}
# }}}

### Instance Methods {{{

# path - {{{
sub path {
	my ($self, $path) = @_;
	$self->extract;
	bug("self->extract did not set self->{root}!!")
		unless $self->{root};

	return $self->{root} unless $path;

	$path =~ s|^/+||;
	return "$self->{root}/$path";
}

# }}}
# glob - {{{
sub glob {
	my ($self, $glob, $absolute) = @_;
	$glob =~ s|^/+||;

	$self->extract;
	bug("self->extract did not set self->{root}!!")
		unless $self->{root};

	if ($absolute) {
		return glob "$self->{root}/$glob";
	}

	# do a relative glob by popping into the root
	# and processing the glob from there.
	#
	pushd $self->{root};
	my @l = glob $glob;
	popd;
	return @l;
}

# }}}
# has_hook - {{{
sub has_hook {
	my ($self, $hook, %opts) = @_;

	if ($hook eq 'cloud-config') {
		$hook = "cloud-config-$opts{purpose}" if ($opts{purpose});
	}
	if ($hook eq 'addon') {
		my $script = $opts{script} || '';
		return $self->{__hook_check}{$hook}{$script} if exists($self->{__hook_check}{$hook}{$script});
		my $filename = $self->get_addon_hook_file($script);
		return $self->{__hook_check}{$hook}{$script} = $filename;
	}

	return $self->{__hook_check}{$hook} if exists($self->{__hook_check}{$hook});
	trace("checking the kit for a(n) '$hook' hook");
	my $hook_path = $self->path("hooks/$hook");
	my @allowed_exts = ('','.sh');
	push @allowed_exts, '.pm' unless envset('GENESIS_NO_MODULE_HOOKS');
	for my $ext (@allowed_exts) {
		$self->{__hook_check}{$hook} = "$hook_path$ext" if (-f "$hook_path$ext");
	}
	return $self->{__hook_check}{$hook};
}

# }}}
# get_addon_hook_file	- {{{

sub get_addon_hook_file {
	my ($self, $script) = @_;
	return $self->{__addon_for_script_hook}{$script}
		if exists($self->{__addon_for_script_hook}{$script});

	# Special case for the addon hook help/list/blank script
	return '@Genesis::Hook::Addon' if $script =~ /^(list|help|)$/ && !envset('GENESIS_NO_MODULE_HOOKS');
	# Do  we have an explicit script using long or short name?
	my @files =  glob($self->path('hooks/addon*'));
	my @scripts = grep {/(\/addon-$script(~.*)?|~$script)(\.pm)?$/} @files;
	@scripts = grep {/\/addon(\.pm)?$/} @files unless @scripts;

	# sort the scripts by length, so that the longest name is first unless $GENESIS_NO_MODULE_HOOKS is set, in which case sorter first.
	@scripts = sort {
	 length($a) <=> length($b) * (envset('GENESIS_NO_MODULE_HOOKS') ? -1 : 1)
	} @scripts;

	return $self->{__addon_for_script_hook}{$script} = $scripts[0] if @scripts;
}

# }}}
# get_hook_module - {{{
sub get_hook_module {
	my ($self, $hook_file) = @_;
	$hook_file = $self->path($hook_file) unless $hook_file =~ m{^/};
	open my $fh, '<', $hook_file;
	my $line = <$fh>;
	$line = <$fh> while ($line =~/^\s*(#.*)?$/);
	close $fh;

	if ($line =~ /^package (Genesis::Hook::[^;\s]*)/) {
		return $1;
	}
	return undef;
}

# }}}
# run_hook - {{{
# _xtrace_hook_file - a copy of a Bash hook that traces to the terminal {{{
#
# An xtrace shows every value a hook handles, credentials included, so it
# goes to the controlling terminal through BASH_XTRACEFD and never to the
# hook's stderr, which a caller or a CI log can capture.  A hook that has
# no terminal, or whose bash predates BASH_XTRACEFD, runs untraced.
sub _xtrace_hook_file {
	my ($hook_file) = @_;
	open my $in, '<', $hook_file or return;
	my $script = do {local $/; <$in>};
	close $in;
	return unless $script =~ s/\A(#!\s*\/bin\/bash(?:[ \t][^\n]*)?\n)//;
	my $shebang = $1;
	my $traced = "$hook_file-trace";
	mkfile_or_fail($traced, 0755, $shebang . <<'EOF' . $script);
if [[ ${BASH_VERSINFO[0]} -gt 4 || ( ${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -ge 1 ) ]] \
  && { exec {__genesis_xtrace_fd}>/dev/tty; } 2>/dev/null ; then
  BASH_XTRACEFD=$__genesis_xtrace_fd
  set -x
else
  echo >&2 "GENESIS_HOOK_XTRACE: no terminal for the trace (or bash < 4.1), so this hook runs untraced."
fi
EOF
	return $traced;
}

# }}}
# Bash hooks that run without a terminal and whose stdout Genesis parses.
# Their stderr is captured in memory and shown only on a terminal.  The
# runtime-config and terminate hooks can prompt, so theirs is left alone.
our @CAPTURED_STDERR_HOOKS = qw/blueprint features cloud-config cpi-config/;

sub run_hook {

	# FIXME: run_hook should always return a scalar (simple or reference), not an array or hash.
	# TODO: Refactor method into smaller, more focused methods per hook type and generalized hook execution support methods
	my ($self, $hook, %opts) = @_;

	my $is_shell=($hook eq 'shell');
	my $is_edit=($hook eq 'edit');
	if ($is_shell) {
		$hook=$opts{hook}||'shell';
	} elsif ($is_edit) {
		$opts{editor} ||= $ENV{EDITOR}||'vim';
	} elsif ($hook ne 'addon' && !$self->has_hook($hook)) {
		# Addon is a special case, it can be missing
		bail("No '$hook' hook script found")
	}

	trace ("preparing to run the '$hook' kit hook");
	local %ENV = %ENV;

	$ENV{GENESIS_KIT_ID}      = $self->id;
	$ENV{GENESIS_KIT_NAME}    = $self->name;
	$ENV{GENESIS_KIT_VERSION} = $self->version;
	$ENV{GENESIS_KIT_PATH}    = $self->path;
	$ENV{GENESIS_KIT_HOOK}    = $hook;

	# TODO: Remove secrets hooks

	bug("Unrecognized hook '$hook'\n") unless grep {
		$_ eq $hook
	} known_hooks();

	if ($opts{env}) {
		my %env_vars = $opts{env}->get_environment_variables($hook);
		$ENV{$_} = $env_vars{$_} for (keys %env_vars);
		trace ('got env info');
		if ($opts{extra_vars}) {
			trace ('got extra env info');
			for (keys %{$opts{extra_vars}}) {
				trace(
					"Overwriting env var #M{%s} with %s (was %s)",
					$_, Genesis::_traced_env_value($_, $opts{extra_vars}{$_}),
					Genesis::_traced_env_value($_, $ENV{$_})
				) if exists($ENV{$_});
				$ENV{$_} = $opts{extra_vars}{$_}
			}
		}
	} else {
		bug("The 'env' option to run_hook is required for the '$hook' hook!!")
			if (grep { $_ eq $hook } qw/new secrets info addon check blueprint pre-deploy post-deploy cloud-config cpi-config features terminate/);
	}

	my (@args, %module_options);
	if ($hook eq 'new') {
		$ENV{GENESIS_MIN_VERSION} = (reverse sort by_semver(
			$ENV{GENESIS_MIN_VERSION}||'0.0.0', $self->genesis_version_min
		))[0];

		@args = (
			$ENV{GENESIS_ROOT},           # deprecated in 2.6.13!
			$ENV{GENESIS_ENVIRONMENT},    # deprecated in 2.6.13!
			$ENV{GENESIS_VAULT_PREFIX},   # deprecated in 2.6.13!
		) unless $self->feature_compatibility('2.6.13');

	} elsif ($hook eq 'secrets') {
		$ENV{GENESIS_SECRET_ACTION} = $opts{action};
		$ENV{GENESIS_SECRETS_DATAFILE} = $opts{env}->workpath("secrets");

	} elsif ($hook eq 'addon') {
		$ENV{GENESIS_ADDON_SCRIPT} = $opts{script};
		my $args = $opts{args} || [];
		my @want_help = delete_from_array($args, qr/^(?:-h|--help)$/);
		push @want_help, 'list' if !$opts{script} || $opts{script} =~ /^(list|help)$/;
		# A bash addon gets the operator's arguments exactly, and any of them
		# can be a credential, so each is wrapped to be traced as its size.
		@args = map {ref($_) ? $_ : {redact => $_}} @$args;
		%module_options = (
			script => $opts{script},
			args => $args,
			help => scalar(@want_help) ? 1 : 0,
		);

	} elsif ($hook eq 'cloud-config') {
		$ENV{GENESIS_CLOUD_CONFIG_SUBTYPE} = $opts{purpose};
		# TODO: add support for multiple cpi boshes
		%module_options = (purpose => $opts{purpose});

	} elsif ($hook eq 'cpi-config') {
		%module_options = (
			credhub_prefix => $opts{credhub_prefix},
			self_upload    => $opts{self_upload}, # the config goes to the director being deployed
		);
		# TODO: do we need anything other than env and kit?

	} elsif ($hook eq 'terminate') {
		%module_options = (
			mode => $opts{mode},
			dryrun => $opts{dryrun}//0,
			force => $opts{force}//0,
			noprompt => $opts{noprompt}//0,
		);

	} elsif ($hook eq 'check') {
		# Nothing special needed

	} elsif ($hook eq 'pre-deploy') {
		$ENV{GENESIS_PREDEPLOY_DATAFILE} = $opts{env}->workpath("data");
		$ENV{GENESIS_MANIFEST_FILE} = $opts{manifest};
		$ENV{GENESIS_BOSHVARS_FILE} = $opts{vars_file};

	} elsif ($hook eq 'post-deploy') {
		$ENV{GENESIS_DEPLOY_RC} = defined $opts{rc} ? $opts{rc} : 255;
		my $fn = $opts{env}->workpath("data");
		mkfile_or_fail($fn, $opts{data}) if ($opts{data}); #FIXME: should be a json file
		$ENV{GENESIS_PREDEPLOY_DATAFILE} = $fn;
		$module_options{rc} = $ENV{GENESIS_DEPLOY_RC};
		$module_options{data} = $opts{data}//undef;
		$module_options{interactive} = $opts{interactive} if ($opts{interactive});
		$module_options{flags} = $opts{flags} if ($opts{flags});

	} elsif ($hook eq 'features') {
		bug("The 'features' option to run_hook is required for the '$hook' hook!!")
			unless $opts{features};
		$module_options{features} = $opts{features};
		$ENV{GENESIS_REQUESTED_FEATURES} = join(" ", @{ $opts{features} });

	} elsif ($hook eq 'runtime-config') {
		%module_options = (
			args => $opts{args} || [], # These are the runtime's to build (or remove), empty means all
			interactive => $opts{interactive} || 0, # whether to run the hook interactively or not
			dryrun => $opts{dryrun} || 0, # whether to run the hook in dry-run mode
			remove => $opts{remove} || 0, # whether to remove the runtime configs
			print => $opts{print} || 0, # whether to show the runtime configs
			collect => $opts{collect} || 0, # whether to return the synthesized runtime configs instead of acting on them
		);
		@args = ref($opts{args}) eq 'ARRAY' ? $opts{args}->@*
		      : ref($opts{args}) eq 'HASH'  ? $opts{args}->%*
		      : $opts{args} ? ($opts{args}) : ();
	}

	# Detect Perl-based hooks and psuedo-hooks
	my ($hook_name,$hook_file,$hook_module) = ($hook,undef,undef);
	if ($is_shell) {
		@args = ();
		$hook_file =
		$hook_name = $opts{shell} || '/bin/bash';

	} elsif ($is_edit) {
		@args = ();
		$hook_file = $opts{env}->workpath("edit-env");
		mkfile_or_fail($hook_file, <<EOF);
#/bin/bash
set -ue
offer_environment_editor true
exit 0
EOF
		chmod 0755, $hook_file;
		$ENV{EDITOR}=$opts{editor};

	} else {
		if ($hook eq 'addon') {
			my $script = $module_options{script} || '';
			$hook_file = $self->get_addon_hook_file($script) // '';

			# Special case for the addon hook help/list/blank script
			if ($hook_file =~ s/^@// && $script =~ /^(list|help|)$/) {
				$hook_module = $hook_file;
				$hook_file   = $ENV{GENESIS_LIB}.'/'.($hook_file =~ s{::}{/}rg).'.pm';
				$hook_name   = $module_options{label} = "addon help";

			# named addon perl script
			} elsif ($hook_file =~ m{/addon-([^~]*)(?:~(.*))?(\.pm)?$}) {
				my $addon_label = $2 ? "$1/$2" : $1;
				$hook_name = "hook/addon '$addon_label'";
				info(
					"[1ARunning #G{%s} addon for #C{%s} #M{%s} deployment",
					$addon_label =~ s/\.pm$//r, $opts{env}->name, $self->id
				);

			# Check if there's a addon.pm perl module
			} elsif ($hook_file =~ m{hooks/addon.pm$}) {
				$hook_name = "hook/addon '$script'";

			} else {
				$hook_file = $self->path("hooks/addon");
				$hook_name = "hook/addon '$opts{script}'";
			}

			bail(
				"Could not find addon hook for '%s' script in kit %s",
				$opts{script}, $self->id
			) unless -f $hook_file || $hook_module;

		} elsif ($hook eq 'cloud-config') {
			if ($ENV{GENESIS_CLOUD_CONFIG_SUBTYPE}) {
				$hook_file = $self->path("hooks/cloud-config-$ENV{GENESIS_CLOUD_CONFIG_SUBTYPE}.pm");
				if (! -f $hook_file) {
					$self->kit_bug(
						"Could not find cloud-config hook for '%s' support in kit %s",
						$ENV{GENESIS_CLOUD_CONFIG_SUBTYPE}, $self->id
					);
				}
				$hook_name = "hook/cloud-config ($ENV{GENESIS_CLOUD_CONFIG_SUBTYPE} support)";
			} else {
				$hook_file = $self->path("hooks/cloud-config.pm");
				$hook_name = "hook/cloud-config";
			}
		} else {
			$hook_file = $self->path("hooks/${hook}.pm");
			$hook_name = "hook/$hook";
		}

		$hook_module //= $self->get_hook_module($hook_file)
			if (-f $hook_file && !envset('GENESIS_NO_MODULE_HOOKS'));

		unless ($hook_module) {
			$hook_file = $self->path("hooks/$hook");
			if (envset('GENESIS_HOOK_XTRACE')) {
				my $traced = _xtrace_hook_file($hook_file);
				if ($traced) {
					warning(
						"GENESIS_HOOK_XTRACE is set: #C{%s} traces each command it runs, with ".
						"its values, to this terminal only.",
						$hook_name
					);
					($hook_file, $hook_name) = ($traced, "$hook_name-trace");
				}
			}
			chmod 0755, $hook_file;
		}
	}

	debug ("Running #C{$hook_name} hook now in ".$self->path);
	if ($hook_module) {
		$module_options{file} = $hook_file;
		$module_options{label} //= $hook_name =~ s/^hook\/addon '([^']*?)(?:\.pm)?'.*/$1/r =~ s{/}{|}r;
		eval {require $hook_file unless $hook_module->can('init')};
		bail(
			"Could not load Perl module %s to run hook %s in kit %s: %s",
			$hook_file, $hook_name, $self->id, Genesis::Hook::load_failure($@)
		) if $@;

		# Don't cache hooks that have side effects, just ones that are idempotent
		my $hook_obj = $hook_module->init(env => $opts{env}, kit => $self, %module_options);
		if ($hook_obj->can("completed") && $hook_obj->completed) {
			trace("Using cached results for '%s' hook for env %s", $hook, $opts{env}->name);
			return $hook_obj->results();
		}

		# TODO: wrap in an eval, give better error messages
		my $ok = $module_options{help} && $hook_obj->can('help')
			? $hook_obj->help()
			: $hook_obj->perform();

		bail(
			"Could not run '%s' hook successfully!",
			$hook
		) unless $ok;
		return $hook_obj->results();
	}

	$ENV{GENESIS_IS_HELPING_YOU} = 'yes';
	my $interactive = ($is_shell || $is_edit || scalar($hook =~ m/^(addon|new|info|check|secrets|post-deploy|pre-deploy)$/)) ? 1 : 0;
	# A hook whose stdout Genesis parses has its stderr kept in memory, too,
	# since what it prints there can quote the values it handled.  It is
	# shown afterward as private detail, which only a terminal displays.
	my $captured = !$interactive && grep {$_ eq $hook} @CAPTURED_STDERR_HOOKS;
	my ($out, $rc, $err) = run({
			interactive => $interactive, stderr => ($captured ? 0 : undef), eval_var_args => $opts{eval_var_args}
		},
		'cd "$1"; source .helper; hook=$2; shift 2; $hook "$@"',
		$self->path, $hook_file, @args
	);

	exit $rc if $is_shell;
	_show_hook_stderr($hook, $err) if $captured;

	# The hook's stdout is for Genesis to parse and can carry credential
	# values, so a failure is described by how the hook ended alone.
	my $ended = _hook_ended($rc);

	if ($hook eq 'new') {
		bail(
			"Could not create new env #C{%s} (in %s): 'new' hook %s",
			$ENV{GENESIS_ENVIRONMENT}, humanize_path($ENV{GENESIS_ROOT}), $ended,
		)	unless ($rc == 0);

		bail(
			"Could not create new env #C{%s} (in %s): 'new' hook did not create #M{%1\$s}",
			$ENV{GENESIS_ENVIRONMENT}, humanize_path($ENV{GENESIS_ROOT})
		)	unless -f sprintf("%s/%s.yml", $ENV{GENESIS_ROOT}, $ENV{GENESIS_ENVIRONMENT});

		return 1;
	}

	if ($hook eq 'blueprint') {
		bail(
			"Could not determine which YAML files to merge: 'blueprint' hook %s (%s)",
			$ended, Genesis::failure_summary($out, $err)
		) if ($rc != 0);

		$out =~ s/^\s+//;
		my @manifests = split(/\s+/, $out);
		bail(
			"Could not determine which YAML files to merge: 'blueprint' specified no files"
		) unless @manifests;
		return \@manifests;
	}

	if (grep { $_ eq $hook}  qw/features/) {
		bail(
			"Could not run feature hook in kit %s: 'features' hook %s (%s)",
			$self->id, $ended, Genesis::failure_summary($out, $err)
		) unless $rc == 0;
		$out =~ s/^\s+//;
		return [split(/\s+/, $out)];
	}

	if ($hook eq 'pre-deploy') {
		bail(
			"Cannot continue with deployment: 'pre-deploy' hook for #C{%s} environment %s.",
			$ENV{GENESIS_ENVIRONMENT}, $ended,
		) unless ($rc == 0);
		my $contents;
		my $fn = $opts{env}->workpath("data");
		if ( -f $fn ) {
			$contents = slurp($fn) if -s $fn;
			unlink $fn;
		}
		return (($rc == 0 ? 1 : 0), $contents);
	}

	if ($hook eq 'post-deploy') {
		unlink $opts{env}->workpath("data")
			if -f $opts{env}->workpath("data");
	}

	return ($rc == 0 ? 1 : 0) if (
		$hook eq 'addon' ||
		$hook eq 'check' ||
		($hook eq 'secrets' && $opts{action} eq 'check')
	);

	if ($rc != 0) {
		if (grep {defined && length} ($out, $err)) {
			bail(
				"Could not run '%s' hook successfully: it %s (%s)",
				$hook, $ended, Genesis::failure_summary($out, $err)
			);
		} else {
			bail("Could not run '%s' hook successfully: it %s", $hook, $ended);
		}
	}
	return 1;
}

# }}}
# _show_hook_stderr - show what a captured hook printed on stderr, privately {{{
#
# A terminal shows it as the hook printed it.  Anywhere else, such as a CI
# log, a note says how much was withheld, and a failed hook is described
# by its kind of failure.
sub _show_hook_stderr {
	my ($hook, $err) = @_;
	return unless defined($err) && $err =~ /\S/;
	info({private => 1, raw => 1}, "%s", $err =~ s/\s+\z//r);
	return 1;
}


# }}}
# _hook_ended - how a Bash hook ended, for a failure message {{{
#
# A hook killed by a signal ends its shell with 128 plus the signal, and
# run() reports a killed shell the same way, so a status in that range is
# named as the signal it stands for.
sub _hook_ended {
	my ($rc) = @_;
	return "ended with no exit status" unless defined($rc) && $rc =~ /^\d+$/;
	return sprintf("ended with status %d, as it does when killed by signal %d", $rc, $rc - 128)
		if $rc > 128 && $rc < 160;
	return "exited $rc";
}

# }}}
# metadata - {{{
sub metadata {
	my ($self,@keys) = @_;
	if (! $self->{__metadata}) {
		if (! -f $self->path('kit.yml')) {
			warning({level => 'debug'},
				"Kit %s is missing it's kit.yml file -- cannot load metadata",
				$self->name
			);
			return {}
		}
		my @kit_files = ($self->path('kit.yml'));
		if ($ENV{PREVIOUS_ENV} && -f ".genesis/cached/$ENV{PREVIOUS_ENV}/kit-overrides.yml") {
			push @kit_files, ".genesis/cached/$ENV{PREVIOUS_ENV}/kit-overrides.yml";
		} elsif ( -f "./kit-overrides.yml" ) {
			push @kit_files, "./kit-overrides.yml";
		}
		if ($self->{__overrides} && ref($self->{__overrides}) eq 'ARRAY') {
			push @kit_files, @{$self->{__overrides}};
		}
		$self->{__metadata} = read_json_from(run(
				{onfailure => "#R{[ERROR] Could not read kit metadata"},
				'spruce merge --go-patch --multi-doc "$@" | spruce json',
				@kit_files
		));

		# Sanitize use_create_env to only allow 'yes', 'no', 'allowed', or booleans

		if (exists $self->{__metadata}{use_create_env}) {
			my $uce = $self->{__metadata}{use_create_env};
			if (ref($uce) eq 'JSON::PP::Boolean') {
				# JSON boolean: true -> 'yes', false -> 'no'
				$self->{__metadata}{use_create_env} = $uce ? 'yes' : 'no';
			} elsif (ref($uce)) {
				kit_bug(
					"Invalid use_create_env type '#C{%s}' in kit metadata.\n".
					"Expected string or boolean, got %s",
					$uce, ref($uce)
				);
			} else {
				# String value: normalize to 'yes', 'no', or 'allow'
				my $val = lc($uce // '');
				$self->{__metadata}{use_create_env} = {
					'yes' => 'yes', 'true'  => 'yes', '1' => 'yes',
					'no'  => 'no',  'false' => 'no',  '0' => 'no',
					'allow' => 'allow'
				}->{$val};
				$self->kit_bug(
					"Invalid use_create_env value '#C{%s}' in kit metadata.\n".
					"Valid values are: #Y{yes}, #Y{no}, #Y{allow}, #Y{true}, or #Y{false}",
					$uce
				) unless $self->{__metadata}{use_create_env};
			}
		} elsif (new_enough($self->{__metadata}{genesis_version_min}//'0.0.0', "2.8.0")) {
			# Default to 'allow' for 2.8.0+ kits
			$self->{__metadata}{use_create_env} = 'allow';
		}
		# Legacy kits (pre-2.8.0) should not have use_create_env set
	}
	return $self->{__metadata} unless @keys;
	return $self->{__metadata}->{$keys[0]} if @keys == 1;
	return get_opts($self->{__metadata}, @keys);
}

# }}}
# apply_env_overrides - apply environment-specific override files to the kit {{{
sub apply_env_overrides {
	my ($self, @overrides) = @_;
	$self->{__overrides} = [@overrides];
	# Clear the loaded metadata
	$self->{__metadata} = undef;
}

# }}}
# env_override_files - return the list of environment kit overrides {{{
sub env_override_files {
	return @{$_[0]->{__overrides} || []};
}

# }}}
# secrets_store - what secrets_store does this kit use ('vault','credhub') {{{
sub secrets_store {
	my ($self) = @_;
	$self->metadata->{secrets_store} ? $self->metadata->{secrets_store} : 'vault';
}

# }}}
# uses_credhub - does this kit use credhub instead of vault {{{
sub uses_credhub { return $_[0]->secrets_store eq "credhub"; }

# }}}

# provided_configs - what configs this kit provides to BOSH, by hook presence rather than hook output {{{
sub provided_configs {
	my ($self) = @_;

	# FUTURE: when a kit may provide several configs of a type, return
	#         <type>:<purpose> per file rather than a bare type.
	# TBD:    conditional configs -- a hook that decides at runtime it has
	#         nothing to contribute still gets an empty config uploaded.
	my @configs = ();
	push(@configs, 'cloud') if $self->has_hook('cloud-config');
	push(@configs, 'runtime') if $self->has_hook('runtime-config');
	return @configs;
}

# }}}
# required_configs - what configs does this kit require from BOSH? {{{
sub required_configs {
	my ($self,@hooks) = @_;

	# Cloud-config hook never requires a cloud config or runtime config
	if (@hooks == 1 && $hooks[0] eq 'cloud-config') {
		return ();
	}

	my $required_configs = $self->metadata->{required_configs};
	unless ($required_configs) {
		return ('cloud') if (grep {$_ eq 'manifest'} @hooks); # Erroneous, should be blueprint - need to fix in callers
		return ('cloud') if (grep {$_ eq 'blueprint'} @hooks);
		return ('cloud') if (grep {$_ eq 'check'} @hooks) && !$ENV{GENESIS_CONFIG_NO_CHECK};
		return ();
	}
	return @{$required_configs} if ref($required_configs) eq 'ARRAY';

	my @configs;
	for my $config (keys %{$required_configs}) {
		if (ref($required_configs->{$config}) eq 'ARRAY') {
			my $needed;
			if (@hooks) {
				for my $hook (@{$required_configs->{$config}}) {
					$needed = scalar(grep {$_ eq $hook} @hooks);
					last if $needed;
				}
			} else {
				$needed = 1;
			};
			push(@configs, $config) if $needed;
		} else {
			push(@configs, $config) if $required_configs->{$config};
		}
	}
	return @configs;
}

# }}}
# required_connectivity - what connectivity does this kit require to do its job? {{{
sub required_connectivity {
	my ($self,@hooks) = @_;
	@hooks = grep {$_} @hooks;
	my $required_conns = $self->metadata->{required_connectivity};
	return () unless ($required_conns);
	return @{$required_conns} if ref($required_conns) eq 'ARRAY';

	my @conns;
	for my $conn (keys %{$required_conns}) {
		if (ref($required_conns->{$conn}) eq 'ARRAY') {
			my $needed;
			if (@hooks) {
				for my $hook (@{$required_conns->{$conn}}) {
					$needed = scalar(grep {$_ eq $hook} @hooks);
					last if $needed;
				}
			} else {
				$needed = 1;
			};
			push(@conns, $conn) if $needed;
		} else {
			push(@conns, $conn) if $required_conns->{$conn};
		}
	}
	return @conns;
}

# }}}
# feature_compatibility - {{{
sub feature_compatibility {
	# Assume feature compatibility with specified min genesis version.
	my ($self,$version) = @_;
	my $id = $self->id;
	my $kit_min = $self->genesis_version_min();

	bug("Invalid base version provided to Genesis::Kit::feature_compatibility") unless semver($version);
	trace("Comparing %s kit min to %s feature base", $kit_min, $version);
	return new_enough($kit_min,$version);
}

# }}}
# genesis_version_min -- minimum version of genesis required to be used for this kit {{{
sub genesis_version_min {
	return $_[0]->_memoize('__genesis_version_min',sub{
		my ($self) = @_;
		my $kit_min = $self->metadata->{genesis_version_min};
		dump_var kit_min_version => $kit_min || "undefined";
		dump_var kit_metadata =>$self->metadata;
		$kit_min = '0.0.0' unless ($kit_min && semver($kit_min));
		return $kit_min;
	})
}

# }}}
# check_prereqs - check that the {{{
sub check_prereqs {
	my ($self,$env) = @_;
	my $id = $self->id;

	my $ok = 1;
	my $min = $self->metadata->{genesis_version_min};
	if ($min && semver($min)) {
		if (!semver($Genesis::VERSION)) {
			warning(
				"#Y{Using a development version of Genesis.}\n".
				"\n".
				"Cannot determine if it meets or exceeds the minimum version ".
				"requirement (v$min) for $id."
			)	unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION');
		} elsif (!new_enough($Genesis::VERSION, $min)) {
			error(
				"$id requires Genesis version $min, but this Genesis is version ".
				"$Genesis::VERSION.\n".
				"\n".
				"Please upgrade Genesis.  Don't forget to run \`genesis embed\` ".
				"afterward, to update the version embedded in your deployment ".
				"repository."
			);
			$ok = 0
		}
	}

	if ($self->has_hook('prereqs')) {
		my ($out,$rc) = run_hook('prereqs',env => $env);
		if ($rc > 0) {
			error("Prerequisite check for kit #C{$id} failed with exit code $rc");
			$ok = 0;
		}
	}

	return $ok;
}

# }}}
# source_yaml_files - list the yaml files that will be merged in order for manifest {{{
sub source_yaml_files {
	my ($self, $env, $absolute) = @_;

	bail(
		"Kit %s is not supported by Genesis %s (no hooks/blueprint script).  ".
		"Check for newer version of this kit.",
		$self->id, $Genesis::VERSION
	) unless ($self->has_hook('blueprint'));

	my $files_ref = $self->run_hook('blueprint', env => $env);
	bail(
		"Kit %s blueprint hook did not return a list of files to merge",
		$self->id
	) unless $files_ref && ref($files_ref) eq 'ARRAY';
	my @files = @$files_ref;
	if ($absolute) {
		my $env_path = $env->path();
		@files = map { $_ =~ qr(^$env_path) ? $_ : $self->path($_) } @files;
	}
	return @files;
}
# }}}
# dereferenced_metadata - fill in kit metadata with source parameters {{{
sub dereferenced_metadata {
	my ($self, $lookup, $fatal) = @_;
	unless (defined($self->{__deref_metadata})) {
		$self->{__deref_cache} = {};
		$self->{__deref_metadata} = $self->_deref_metadata($self->metadata,$lookup);
	}
	if ($fatal && scalar @{$self->{__deref_miss}||[]}) {
		bail "Could not dereference the following values specified in the metadata:\n  - ".
		     join("\n  - ", @{$self->{__deref_miss}});
	}
	$self->{__deref_metadata};
}

# }}}
# requires_iaas - does this kit require iaas to be declared in the environment {{{
sub requires_iaas {
	my ($self, $env) = @_;
	return $self->metadata->{requires_iaas};
}
# }}}
# requires_scale - does this kit require scale to be declared in the environment {{{
sub requires_scale {
	my ($self, $env) = @_;
	return $self->metadata->{requires_scale};
}
# }}}
# services - what services does this kit provide? {{{
sub services {
	my ($self) = @_;
	my $services = $self->metadata->{services};
	return () unless $services;
	return @{$services} if ref($services) eq 'ARRAY';
	return ($services);
}

# }}}
# provides_service - does this kit provide the named service? {{{
sub provides_service {
	my ($self, $service) = @_;

	# Check explicit services declaration first
	my @declared = $self->services;
	if (@declared) {
		return scalar grep { $_ eq $service } @declared;
	}

	# Backward compatibility: infer from kit name and metadata
	if ($service eq 'vault') {
		return ($self->metadata->{name} || '') eq 'vault';
	}
	if ($service eq 'director') {
		return 1 if ($self->id || '') =~ /^bosh\//;
		return $self->metadata->{is_bosh_director} ? 1 : 0;
	}

	return 0;
}

# }}}
# }}}

### Private Methods {{{

# _deref_metadata - recursively dereference metadata structure {{{
sub _deref_metadata {
	my ($self,$metadata, $lookup) = @_;
	if (ref $metadata eq 'ARRAY') {
		# Have to strip out maybe's
		my @results;
		for (@$metadata) {
			eval {push @results, $self->_deref_metadata($_,$lookup)};
			die $@ if ($@ && $@ ne "metadata not found\n");
		}
		return [@results];
	} elsif (ref $metadata eq 'HASH') {
		my %h = ();
		for (keys %$metadata) {
			eval {$h{$_} = $self->_deref_metadata($metadata->{$_},$lookup)};
			die $@ if ($@ && $@ ne "metadata not found\n");
		}
		return \%h;
	} elsif (ref(\$metadata) eq 'SCALAR' && defined($metadata)) {
		$metadata =~ s/\$\{(.*?)(?:\|\|(.*?))?\}/$self->_dereference_param($lookup, $1, $2)/ge;
		return $metadata;
	} else {
		return $metadata;
	}
}

# }}}
# _dereference_param - derefernce a referenced parameter {{{
sub _dereference_param {
	my ($self,$lookup,$key,$default) = @_;
	my $maybe = $key =~ s/^maybe:// ? 1 : 0;
	trace "Dereferencing kit param: %s [default: %s]", $key, defined($default) ? $default : 'null';
	if (defined(($self->{__deref_cache}||{})->{$key})) {
		trace "Genesis::Kit->_dereference_param: cache hit '%s'=>'%s'", $key, $self->{__deref_cache}{$key};
		return $self->{__deref_cache}{$key};
	}
	$default = bless({},"missing_value") if $maybe;

	my $val = $lookup->($key, $default);
	die "metadata not found\n" if (ref($val) eq "missing_value");
	while (defined($val) && $val =~ /\(\( grab \s*(\S*?)(?:\s*\|\|\s*(.*?))?\s*\)\)/) {
		$key = $1;
		my $remainder = $2;
		if ($remainder && $remainder =~ /^"([^"]*)"$/) {
			$default = $1;
			$remainder = "";
		} else {
			$default = undef;
		}
		trace "Dereferencing kit param [intermediary]: %s [default: %s]", $key, defined($default) ? $default : 'null';
		$val = $lookup->($key, $default);
		$val = "(( grab $remainder ))" if $remainder && !$val;
	}
	if (!defined($val)) {
		push @{($self->{__deref_miss}||=[])}, $key;
		return "\${$key}"
	}
	if (defined($val) && $val =~ /\(\( vault /) {
		my $hint = ($val =~ /ocfp/)
			? "\n\n        Ensure OCFP vault configuration data has been populated.\n".
			  "        Run: ocfp vault populate --bloc <bloc-name>"
			: "";
		bail(
			"Cannot dereference kit parameter '%s' to a value because it has an unresolved\n".
			"        vault lookup:\n[[  >>%s%s",
			$key, $val, $hint
		);
	}
	trace "Dereference: got %s", $val;
	($self->{__deref_cache}||={})->{$key} = $val;
	return $val; # TODO: maybe change unquoted ~ to undef, and remove quotes from default
}

# }}}

# is_dev - return true if this is a dev kit {{{
sub is_dev {
	return 0;
}
# }}}
# }}}

1;

# vim: fdm=marker:foldlevel=1:noet
