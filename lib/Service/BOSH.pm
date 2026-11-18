package Service::BOSH;

use IO::Handle;

use Genesis qw/
	trace debug info bail run slurp new_enough logger dump_var humanize_path dryrun
	shell_quote
/;
use Genesis::Term ();
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

# _logging_settings - what the operator set for bosh's own debug logging
#
# bosh's debug logging writes whole director requests and responses,
# tokens included, to its output or to BOSH_LOG_PATH, so Genesis turns it
# off for every bosh command it runs.  Returns the names of the settings
# that would have turned it on, so the operator can be told once.
our $WARNED_LOGGING = 0;
sub _logging_settings {
	my ($env) = @_;
	my $get = sub { exists($env->{$_[0]}) ? $env->{$_[0]} : $ENV{$_[0]} };
	my @set;
	my $level = $get->('BOSH_LOG_LEVEL') // '';
	push @set, 'BOSH_LOG_LEVEL' if $level ne '' && lc($level) ne 'none';
	push @set, 'BOSH_LOG_PATH' if ($get->('BOSH_LOG_PATH') // '') ne '';
	return @set;
}

# }}}
# managed_environment - settle the environment every bosh Genesis starts gets {{{
#
# Takes the environment a bosh command is about to run with, as a hash in
# which an undef value unsets the variable, and changes it in place.
# bosh's debug logging writes director requests and responses, tokens
# included, to its output or to a log file, where a CI log or a saved
# transcript would keep them, so it is off for every bosh command Genesis
# starts, hooks included.  bosh also mishandles HTTPS_PROXY, which is
# dropped unless GENESIS_HONOR_ENV says to keep the caller's environment.
sub managed_environment {
	my ($env) = @_;
	if (my @set = _logging_settings($env)) {
		print STDERR Genesis::Term::csprintf(
			"#Y{[WARNING]} Ignoring %s for the bosh commands Genesis runs: bosh's debug ".
			"logging writes director requests and responses, tokens included.\n",
			join(' and ', @set)
		) unless $WARNED_LOGGING++;
	}
	$env->{BOSH_LOG_LEVEL} = 'none';
	$env->{BOSH_LOG_PATH} = undef;
	unless ($ENV{GENESIS_HONOR_ENV}) {
		$env->{HTTPS_PROXY} = undef; # bosh dislikes this env var
		$env->{https_proxy} = undef; # bosh dislikes this env var
	}
	return $env;
}

# }}}
# exec_managed - replace this process with a bosh command in the managed environment {{{
#
# The launcher for bosh commands that Genesis does not run itself, such as
# the bosh a hook calls when there is no environment file to go through.
# The arguments are the command and its arguments exactly as they are to
# be run, starting with the bosh executable; nothing is traced, and none
# of them is reinterpreted by a shell.
sub exec_managed {
	my (@argv) = @_;
	unless (@argv) {
		print STDERR "Service::BOSH::exec_managed was given no command to run\n";
		exit 2;
	}
	my %env = %ENV;
	managed_environment(\%env);
	for (keys %env) {
		if (defined($env{$_})) {$ENV{$_} = $env{$_}} else {delete $ENV{$_}}
	}
	{ no warnings 'exec'; exec {$argv[0]} @argv; }
	printf STDERR "Could not run %s: %s\n", $argv[0], $!;
	exit 127;
}

# }}}
# execute - execute a bosh command {{{
sub execute {
	my ($self, @cmd) = @_;
	my %env = $self->environment_variables;

	# The caller's hash is copied, since what follows changes it, and a
	# caller can pass one hash to several calls.
	my $opts = (ref($cmd[0]) eq 'HASH') ? {%{shift @cmd}} : {};

	# passfail is answered here, from the exit code; given to run(), it
	# would replace the exit code with a boolean that execute() never reads.
	my $passfail = delete($opts->{passfail});

	$env{BOSH_DEPLOYMENT} = delete($opts->{deployment}) || $self->{deployment}; # TODO: do we need this still?
	$opts->{stderr} = 0 unless (defined($opts->{stderr}) || $opts->{interactive});

	$env{$_} = $opts->{env}{$_} for (keys %{$opts->{env}||{}});
	$opts->{env} = \%env;
	my $noninteractive = envset('BOSH_NON_INTERACTIVE') ? ' -n' : '';
	$opts->{env}{BOSH_NON_INTERACTIVE} = undef;
	managed_environment($opts->{env});

	# A caller that says otherwise is honoured; see %TRACEABLE_OUTPUT.
	$opts->{public_output} //= 1 if $TRACEABLE_OUTPUT{_subcommand(@cmd)};

	my $watch;

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

		# An interactive command runs on a pseudo-terminal, through script(1),
		# so that bosh prompts and shows progress as it would for an operator.
		# What it prints is read from the pipe, in memory, and no typescript
		# is written.  It merges bosh's stdout and stderr, and either can
		# quote a credential, so none of it is traced, whatever the command.
		#
		# A passthrough command is one whose output the operator asked for,
		# such as `genesis <env> bosh vms`.  Off a terminal, it needs no
		# pseudo-terminal: bosh writes to the operator's stdout itself, as it
		# would if run by hand, and Genesis neither reads nor keeps it.
		my $direct = delete($opts->{passthrough}) && !-t STDOUT;
		if ($opts->{interactive} && $allow_script_wrapper && !$direct) {
			@cmd = Genesis::pty_command(@cmd);
			$watch = _interactive_watch();
			$opts->{stream}    = $watch->{chunk};
			$opts->{on_signal} = $watch->{signal};
			delete @{$opts}{qw/public public_output public_stderr/};
		}
	}

	dump_var("bosh command" => [map {Genesis::traced_arg($_)} @cmd]);
	delete $self->{last_interactive_status};
	my @results = run($opts, @cmd);

	if ($watch) {
		my $status = $self->{last_interactive_status} = $watch->{finish}->($results[1]);
		$results[0] =~ s/^\^D[\x08]*// if defined($results[0]); # macOS script(1) echoes the EOF it sends
		$results[2] = undef; # script(1)'s own stderr, which is not bosh's
		trace("bosh tasks: %s; exit code %s%s",
			(join(', ', map {"$_->{id} ".($_->{state} // 'with no final state')} @{$status->{tasks}}) || 'none'),
			$results[1] // 'unknown',
			$status->{interrupted} ? '; interrupted' : '');
	}
	return !$results[1] if $passfail;
	return wantarray ? @results : $results[1];
}

# }}}
# last_interactive_status - how the last interactive bosh command ended {{{
#
# The tasks it named, each with the final state bosh reported for it, if
# any, its exit code, and whether it was interrupted, all taken from what
# bosh printed and how it ended, as they happened.  A task with no final
# state may still be running on the director.
sub last_interactive_status {
	return $_[0]->{last_interactive_status};
}

# }}}
# _interactive_watch - follow an interactive bosh command's output {{{
#
# On a terminal, what bosh prints is passed straight to it and to nothing
# else.  Anywhere else, such as a CI log, it is not shown, since a log
# would keep any credential it quotes; Genesis says instead when bosh
# starts a task, how each task ends, and when bosh asks whether to
# continue.  Either way, the tasks bosh names and the final state it
# reports for each are kept.
sub _interactive_watch {
	my $tty = -t STDOUT;
	my $raw;
	if ($tty) {
		STDOUT->flush;
		STDERR->flush;
		open($raw, '>&', \*STDOUT) or undef($raw);
		binmode($raw) if $raw;
	}
	my %status = (tasks => [], signal => undef);
	my %task;
	my ($line, $asked) = ('', 0);
	my $prompt = qr/Continue\?\s*\[yN\]:?\s*/;
	my $ask = sub {
		info("[[  - >>bosh is asking whether to continue; answer #C{y} or #C{n}") unless $tty || $asked++;
	};
	my $seen = sub {
		my ($text) = @_;
		$text = Genesis::Term::decolorize($text) =~ s/\r//gr =~ s/\s+\z//r;
		return unless $text =~ /^Task (\d{1,12})(?: (done|error|cancelled|timeout))?$/;
		my ($id, $state) = ($1, $2);
		unless ($task{$id}) {
			push @{$status{tasks}}, ($task{$id} = {id => $id});
			info("[[  - >>bosh started task #C{%s}", $id) unless $tty;
		}
		if ($state && !$task{$id}{state}) {
			$task{$id}{state} = $state;
			info("[[  - >>bosh task #C{%s} ended: #%s{%s}", $id, $state eq 'done' ? 'G' : 'R', $state) unless $tty;
		}
	};
	return {
		chunk => sub {
			my ($data) = @_;
			if ($raw) {
				syswrite($raw, $data);
			} elsif ($tty) {
				print STDOUT $data;
			}
			$line .= $data;
			while ($line =~ s/\A([^\n]*)\n//) {
				my $done = $1;
				# The answer can come back in the same read as the question.
				$ask->() if Genesis::Term::decolorize($done) =~ $prompt;
				$seen->($done);
				$asked = 0;
			}
			# bosh's question has no newline until it is answered.
			$ask->() if Genesis::Term::decolorize($line) =~ /$prompt\z/;
			$line = substr($line, -4096) if length($line) > 65536;
		},
		signal => sub { $status{signal} //= $_[0] },
		finish => sub {
			my ($rc) = @_;
			$seen->($line) if length($line);
			close($raw) if $raw;
			$status{rc} = $rc;
			$status{interrupted} = (defined($status{signal}) || _interrupt_exit($rc)) ? 1 : 0;
			return \%status;
		},
	};
}

# }}}
# _interrupt_exit - whether an exit code is that of a command stopped by a signal {{{
#
# util-linux script(1) and a shell report a command killed by a signal as
# 128 plus its number.  macOS script(1) exits with the signal's number,
# so there INT and TERM are 2 and 15; HUP would be 1, which is also how
# bosh reports any failure, so it is not counted.
sub _interrupt_exit {
	my ($rc) = @_;
	return 0 unless defined($rc) && $rc =~ /\A\d+\z/;
	return 1 if $rc > 128 && $rc < 160;
	return 1 if $^O eq 'darwin' && ($rc == 2 || $rc == 15);
	return 0;
}

# }}}

# dryrun_of - execute a bosh command in dry-run mode {{{
sub dryrun_of {
	my ($self, @cmd) = @_;
	my $opts = {};
	my $execute = 0;
	my $exec_msg = "";
	my $interactive = undef;
	if (ref($cmd[0]) eq 'HASH') {
		$opts = {%{shift @cmd}}; # the caller's hash is left as it was
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
