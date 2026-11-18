package Service::BOSH;

use File::Temp qw/tempfile/;

use Genesis qw/
	trace debug bail run slurp new_enough logger dump_var humanize_path dryrun
	shell_quote
/;
use Genesis::State qw/envset/;

## Class Variables {{{
my ($bosh_cmd);

#}}}

### Class Methods {{{
#
# command - get, and optionally check version, of local BOSH command {{{
sub command {
	my ($class, $min_version, $max_version) = @_;
	return $ENV{GENESIS_BOSH_COMMAND} if $ENV{GENESIS_BOSH_COMMAND};
	return $bosh_cmd if ($bosh_cmd && !$min_version && !$max_version);

	$min_version ||= '0.0.0';
	my %versions;
	foreach my $boshcmd (qw(bosh-cli bosh2 boshv2 bosh)) {
		my ($version, undef) = run({public_output => 1}, "$boshcmd -v 2>&1 | grep version | head -n1");
		trace("Version for $boshcmd: '$version'");
		next unless defined($version) && $version =~ /version (\S+?)(-.*)?$/;
		$version = $1;
		my $cmd = `/usr/bin/env bash -c 'command -v $boshcmd 2>/dev/null' 2>/dev/null`;
		$cmd = `which $boshcmd 2>/dev/null` if $? != 0;
		$cmd = "\\$boshcmd" if $? != 0;
		chomp $cmd;
		debug("#G{Version v$version} of #C{$cmd} is found on this system.");
		$versions{$version} = $cmd;
	}

	bail "#R{Missing `bosh`} - install the BOSH (v2) CLI from #B{https://github.com/cloudfoundry/bosh-cli/releases}"
		unless keys %versions;

	my $best = "0.0.0";
	for (keys %versions) {
		$best = $_ if (
			new_enough($_, $best) &&
			new_enough($_, $min_version) &&
			(! $max_version || new_enough($max_version, $_))
		)
	}

	if ($min_version && $best eq "0.0.0") {
		my $msg=sprintf(
			"BOSH CLI #c{v%s} %s is required, but this system only provides the following:",
			$min_version,
			$max_version ? "up to #Y{v$max_version}" : "or higher"
		);
		$msg .= "\n  - $versions{$_} (#Y{v$_})" for (keys %versions);
		bail $msg;
	}
	debug("Selecting #C{%s} (#G{v%s}) as BOSH cli for Genesis BOSH activities", $versions{$best}, $best);
	$bosh_cmd = $versions{$best};
}

# }}}
# set_command - override the command path {{{
sub set_command {
	my ($class, $cmd) = @_;
	$bosh_cmd = $cmd;
}

# }}}

sub has_director {
	return 0;
}

# available_stemcells - get a list of available stemcells from bosh.io {{{
sub available_stemcells {
	require Service::BOSH::Stemcell;
	my ($class, %opts) = @_;
	my ($iaas, $os, $type) = @opts{qw/iaas os type/};
	if ($opts{env}) {
		my $env = $opts{env};
		$iaas //= $env->iaas;
		$os //= $env->stemcell_os;
		$type //= $env->lookup('bosh-configs.stemcells.type', undef);
	}
	bail(
		"No IaaS specified for stemcell lookup"
	) unless $iaas;
	# Out of the box the OS is the current Ubuntu LTS. An operator overrides
	# it with --os or bosh-configs.stemcells.os; both arrive here as $os.
	$os //= Service::BOSH::Stemcell::default_stemcell_os();

	my $stemcells = Service::BOSH::Stemcell->available_stemcells(
		iaas => $iaas,
		os => $os,
		all => 1,
		type => $type,
	);

	return wantarray ? @$stemcells : $stemcells;
}
# }}}

## Instance Methods {{{

# environment_variables - retrieve BOSH environment variables for this BOSH director {{{
sub environment_variables {
	return ();
}

#}}}
# Trace redaction for bosh output {{{
#
# Much of what bosh prints carries credentials: `bosh manifest`, `bosh int`,
# configs, variables, and the diff in a deploy transcript, and a failing
# command can quote them on stderr.  Stdout is written to the trace only
# for these read-only listings, and stderr never is; everything else
# leaves a byte count.  `events` is left out because an event's context
# can carry a task's error text.  A command that cannot be identified,
# including a shell command that chains anything onto a listing or one
# with an option the parser does not know, is private, so a misreading
# errs on the safe side.
our %TRACEABLE_OUTPUT = map {$_ => 1} qw(
	deployments env errands instances locks releases stemcells tasks vms
);

# bosh's global options, split by whether they take a value.  An option's
# value is never the subcommand: `bosh -e vms manifest` runs `manifest`
# against an environment named vms.
our %BOSH_VALUE_OPTIONS = map {$_ => 1} qw(
	-e --environment -d --deployment --ca-cert --client --client-secret
	--config --column --parallel
);
our %BOSH_FLAG_OPTIONS = map {$_ => 1} qw(
	--json --tty --no-color -n --non-interactive --sha2 -v --version -h --help
);

# _subcommand - the bosh subcommand a command list runs, or '' if unknown
sub _subcommand {
	my (@cmd) = @_;
	# A shell command can pipe, chain, or substitute more output onto the
	# listing it starts with, so it can't be identified.
	return '' if @cmd && defined($cmd[0]) && !ref($cmd[0]) && $cmd[0] =~ /[|;&\$`<>()\n'"\\]/;
	my @words = (@cmd && defined($cmd[0]) && !ref($cmd[0]) && $cmd[0] =~ /\s/)
		? (split(/\s+/, $cmd[0] =~ s/^\s+//r), @cmd[1..$#cmd])
		: @cmd;
	shift @words if @words && defined($words[0]) && !ref($words[0]) && $words[0] =~ m{(?:^|/)bosh$};
	while (@words) {
		my $word = shift @words;
		return '' if !defined($word) || ref($word) || $word eq '' || $word eq '--';
		return $word unless $word =~ /^-/;
		next if $BOSH_FLAG_OPTIONS{$word};
		if ($BOSH_VALUE_OPTIONS{$word}) {
			return '' unless @words;
			shift @words;
			next;
		}
		# --option=value, and a short option with its value attached.
		next if $word =~ /^(--[a-z][a-z0-9-]*)=/ && $BOSH_VALUE_OPTIONS{$1};
		next if $word =~ /^(-[ed])./ && $BOSH_VALUE_OPTIONS{$1};
		return '';
	}
	return '';
}

# _verbose_log_level - true if bosh will write debug logging with its output
#
# Above its default of none, bosh logs whole director requests and
# responses, tokens included.
sub _verbose_log_level {
	my ($env) = @_;
	my $level = (exists($env->{BOSH_LOG_LEVEL}) ? $env->{BOSH_LOG_LEVEL} : $ENV{BOSH_LOG_LEVEL}) // '';
	return ($level ne '' && lc($level) ne 'none') ? 1 : 0;
}

# }}}
# execute - execute a bosh command {{{
sub execute {
	my ($self, @cmd) = @_;
	my %env = $self->environment_variables;

	my $opts = (ref($cmd[0]) eq 'HASH') ? shift @cmd : {};

	$env{BOSH_DEPLOYMENT} = delete($opts->{deployment}) || $self->{deployment}; # TODO: do we need this still?
	$opts->{stderr} = 0 unless (defined($opts->{stderr}) || $opts->{interactive});

	$env{$_} = $opts->{env}{$_} for (keys %{$opts->{env}||{}});
	$opts->{env} = \%env;
	unless ($ENV{GENESIS_HONOR_ENV}) {
		$opts->{env}{HTTPS_PROXY} = undef; # bosh dislikes this env var
		$opts->{env}{https_proxy} = undef; # bosh dislikes this env var
	}
	my $noninteractive = envset('BOSH_NON_INTERACTIVE') ? ' -n' : '';
	$opts->{env}{BOSH_NON_INTERACTIVE} = undef;

	# A caller that says otherwise is honoured; see %TRACEABLE_OUTPUT.
	my $verbose = _verbose_log_level($opts->{env});
	my $private = ($TRACEABLE_OUTPUT{_subcommand(@cmd)} && !$verbose) ? 0 : 1;
	$opts->{public_output} //= 1 unless $private;

	# Verbose bosh logging is the operator's own debugging switch, and it
	# writes director requests and responses, tokens included, into the
	# output.  An interactive command then shows it on the terminal only:
	# it runs without the `script` wrapper, so no transcript of it is kept
	# or handed back to be saved, and a warning says so each time.
	my $live_only = $opts->{interactive} && $verbose;
	if ($live_only) {
		print STDERR Genesis::Term::csprintf(
			"#Y{[WARNING]} BOSH_LOG_LEVEL=%s makes bosh print director requests and ".
			"responses, tokens included.  They are shown on this terminal only, and ".
			"no transcript of this bosh command is kept.\n",
			$opts->{env}{BOSH_LOG_LEVEL} // $ENV{BOSH_LOG_LEVEL}
		);
	}

	my ($fh, $file);

	my $bosh = ref($self)->command();
	if ($cmd[0] =~ m/^bosh(\s|$)/) {
		# ('bosh', 'do', 'things') or 'bosh do things'
		$cmd[0] =~ s/^bosh/$bosh$noninteractive/;

	} elsif ($cmd[0] =~ /(\||\$\{?[\@0-9])/) {
		# ('deploy "$1" | jq -r .whatever', $d)
		$cmd[0] = "$bosh$noninteractive $cmd[0]";

	} else {
		# ('deploy', $d)
		my $allow_script_wrapper = !(grep {$_ eq $cmd[0]} (qw(
			int
		)));
		unshift(@cmd, '-n') if $noninteractive;
		unshift(@cmd, $bosh);

		# Capture output if interactive using script command
		if ($opts->{interactive} && $allow_script_wrapper && !$live_only) {
			my $OS = "$^O";
			($fh, $file) = tempfile('bosh-output-XXXXXXXX', TMPDIR => 1, UNLINK => 1);

			if ($OS eq 'darwin') {
				unshift(@cmd, "script", "-q", "$file");
			} elsif ($OS eq 'linux') {
				# `script -c` re-parses its argument with a shell, so the
				# argument list must be flattened with shell_quote: naive
				# joining lets values containing shell metacharacters split
				# into separate arguments or execute as injected commands.
				# shell_command carries wrapped arguments through as values.
				@cmd = ('script', '-qe', $file, '-c', Genesis::shell_command(@cmd));
			}
		}
	}

	dump_var("bosh command" => [map {Genesis::traced_arg($_)} @cmd]);
	my @results = run($opts, @cmd);

	if ($opts->{interactive} && $file) {
		$results[0] = slurp($file);
		if ($results[0] =~ s/\nScript done.*\[COMMAND_EXIT_CODE="(.*)"]$//m) {
			$results[1] = $1;  # Linux stores command exit code in the script output
		}
		$results[0] =~ s/^Script [^\n]+\n//m; # remove script header (linux)
		$results[0] =~ s/^\^D[\x08]*//;       # remove macOS script ^D prefix + backspaces
		if (($opts->{public_output} || $opts->{public}) && !$opts->{redact}) {
			logger->dump_var("bosh results" => \@results);
		} else {
			trace("[%sb of redacted bosh output omitted from debug, exit code %s]",
				length($results[0] // ''), $results[1] // 'unknown');
		}
	}
	return !$results[1] if $opts->{passfail};
	return wantarray ? @results : $results[1];
}

# }}}

# dryrun_of - execute a bosh command in dry-run mode {{{
sub dryrun_of {
	my ($self, @cmd) = @_;
	my $opts;
	my $execute = 0;
	my $exec_msg = "";
	my $interactive = undef;
	if (ref($cmd[0]) eq 'HASH') {
		$opts = shift @cmd;
		$execute = delete($opts->{execute}) || 0;
		$interactive = delete($opts->{interactive});
		if (defined($opts->{exec_msg})) {
			$exec_msg = " ".delete($opts->{exec_msg});
		}
	}
	$interactive = 1 if $execute && !defined($interactive);

	my $command = join(' ', map {$_ =~ /\s/ ? "'$_'" : $_} (humanize_path(scalar($self->command)), @cmd));
	if (ref($self)->has_director) {
		dryrun(
			"\nwould execute #G{%s} on #M{%s} BOSH director%s",
			$command,
			$self->{alias} || $self->{host},
			$execute ? ", resulting in$exec_msg:" : "."
		);
	} else {
		dryrun(
			"\nwould execute #G{%s}%s",
			$command,
			$execute ? ", resulting in$exec_msg:" : "."
		);
	}
	return 1 unless $execute;
	$execute = [qw/--dry-run/] unless ref($execute) eq 'ARRAY';
	@cmd = (@cmd, @$execute);
	return $self->execute({%$opts, interactive => $interactive}, @cmd);
}
# }}}
# }}}
# }}}
1
# vim: fdm=marker:foldlevel=1:noet
