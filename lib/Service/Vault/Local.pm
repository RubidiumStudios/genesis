package Service::Vault::Local;

use strict;
use warnings;

use Genesis;
use Fcntl qw/:flock/;
use File::Spec ();
use IO::Socket::IP ();

use base 'Service::Vault';

my $local_vaults = {};

# vault takes <port> for its API listener and <port>+1 for its cluster
# listener.  It survives <port>+1 being unavailable -- a memory-backed vault
# has no use for the cluster listener -- so this is about not handing out
# overlapping pairs when several vaults are allocated in quick succession,
# not about keeping the server alive.
use constant VAULT_CLUSTER_PORT_OFFSET => 1;

# Mirrors safe's own default scan range, so a genesis-started local vault sits
# in the band an operator would think to look in.  The port *within* the band
# is arbitrary -- see _shuffled_ports -- so do not expect 8201.
use constant LOCAL_VAULT_PORT_MIN => 8201;
use constant LOCAL_VAULT_PORT_MAX => 8999;

### Class Methods {{{

# create - create a local memory-backed vault, then return a Service::Vault pointer to it. {{{
sub create {
	my ($class, $name) = @_;

	# Start local vault in the background
	my $alias = _generate_alias($name);
	my $logfile = workdir."/$alias.out";
	return $local_vaults->{$alias} if $local_vaults->{$alias};

	trace "Looking for existing safe $alias";
	my $safe_process = _get_safe_process($alias,0.25);

	# Held from before the port is chosen until the vault answers below, so
	# that no other genesis can pick the same port or rewrite ~/.saferc while
	# safe is mid-startup.  Undef -- and so no lock -- on the rebind path.
	my $startup_lock;

	# The target to put back as current once the new vault has settled, or
	# undef when there was nothing to restore.
	my $restore_default;

	unless ($safe_process) {
		$startup_lock = _lock_local_vault_startup();
		debug "Starting background local safe $alias";
		my $default_vault = $class->default;
		my $port = _find_free_port();
		debug "Starting local vault $alias on port $port";
		run("safe local -m --as '$alias' --port $port &>$logfile &");
		trace "Looking for new process";
		$safe_process = _get_safe_process($alias,1);
		bail(
			"Could not start local memory-backed vault:\n%s",
			slurp($logfile)
		) unless $safe_process;
		# Deliberately NOT restoring the default target here: see the
		# restore below, after the vault has settled.
		$restore_default = $default_vault;
	}

	my $vault_process = _get_vault_process($safe_process->{pid}, 1);
	bail(
		"Could not start local memory-backed vault:\n%s",
		slurp($logfile)
	) unless $vault_process && $vault_process->{ppid} == $safe_process->{pid};

	# Restore default vault target?

	# Polled, not read once: safe registers the target in ~/.saferc a moment
	# after the server process itself is up, so a single read races the writer
	# and comes back empty.  That reaches read_json_from as '' and dies with
	# "malformed JSON string, neither array, object, number, string or atom, at
	# character offset 0", which names nothing an operator can act on.
	my $vault_info = _lookup_vault_target($alias, 100);
	bail(
		"Failed to find vault alias after starting local vault."
	)	unless ($vault_info && ref($vault_info) eq 'HASH' && $vault_info->{url});

	my $vault = $class->SUPER::new(
		@{$vault_info}{qw(url name verify namespace strongbox mount)}
	);
	$vault->{logfile}   = $logfile;
	$vault->{safe_pid}  = $safe_process->{pid};
	$vault->{vault_pid} = $vault_process->{pid};
	$local_vaults->{$alias} = $vault;

	my $status = '';
	while ($status ne "ok") {
		trace "Waiting for local vault to become available...";
		select(undef,undef,undef,0.25);
		$status = $vault->status;
		if ($status =~ /^ambiguous/) {
			$vault->shutdown;
			bail(
				"Failed to connect to local memory-backed vault: %s\n\nYou may need to clean out your ~/.saferc file for stale local vaults.",
				$status
			);
		}
	}

	# Restore the operator's default target -- and only now.  `safe local`
	# writes ~/.saferc twice: once registering the new target as current, and
	# again with the root token after it initializes the vault.  Restoring
	# between those two writes puts a second safe process into an unlocked
	# whole-file rewrite of the same file, and both open it O_TRUNC and write
	# from offset zero.  The shorter document then overwrites the longer one's
	# prefix and leaves its tail behind, producing a ~/.saferc that parses as
	# a valid config followed by garbage.
	#
	# That is not theoretical.  It corrupts real operator config, and because
	# the surviving prefix keeps the *previous* current target, the next
	# `safe local` connects to it and calls Init against a production vault.
	# Waiting until the status loop above has passed puts this after safe's
	# second write, so the two never overlap.
	#
	# Skipped when there was nothing to restore: a fresh scoped HOME (as
	# kit-validator produces) has no existing target, and set_default with
	# undef explodes on $vault->name.
	$class->set_default($restore_default) if $restore_default;

	# Explicit rather than left to scope exit: this is the point the lock is
	# safe to drop -- the vault is answering, so the next caller's port scan
	# will see it.
	undef $startup_lock;

	return $vault;
}

# }}}
# rebind - connect to and return an already-running local vault {{{
sub rebind {
	my ($class, $name) = @_;
  return unless $class->valid_local_vault($name);

	my $alias = _generate_alias($name);
	return $local_vaults->{$alias} if $local_vaults->{$alias};

	# Single read, unlike create(): rebind is only reached for a vault that is
	# already registered, so an absent target is an answer, not a race to wait out.
	my $vault_info = _lookup_vault_target($alias);
	return unless ($vault_info && ref($vault_info) eq 'HASH' && $vault_info->{url});

	my $safe_process = _get_safe_process($alias);
	return unless defined($safe_process);

	my $vault = $class->SUPER::new(
		@{$vault_info}{qw(url name verify namespace strongbox mount)}
	);
	return unless $vault;

	$vault->{logfile}   = workdir."/$alias.out"; #FIXME: This just assumes this value -- should use lsof to detect correct value
	$vault->{safe_pid}  = $safe_process->{pid};
	$vault->{vault_pid} = _get_vault_process($safe_process->{pid});
	$local_vaults->{$alias} = $vault;

	return $vault;
}

# }}}
# valid_local_vault - return true if the submitted name and optional url would be valid as a local vault {{{
sub valid_local_vault {
	my ($class, $name, $url) = @_;
	$name =~ /^local_vault_(.*)_[0-9]+$/ && (!$url || $url =~ /localhost/);
}


# }}}
# shutdown_all - shutdown all local vaults {{{
sub shutdown_all {

	# TODO: This may have to be done in order of what is targeted in .saferc so
	# that previous targets are restored properly.  Not sure if this even works
	# on multiple retargets, so local vaults may need to track their previous
	# target and restore it on shutdown.
	for (keys %$local_vaults) {
		debug "Shutting down $_ ...";
		delete($local_vaults->{$_})->shutdown;
	}
}
# }}}
# }}}

### Instance Methods {{{

# connect_and_validate - trivial pass-through for local vaults {{{
# A local vault is spun up in-process (or by rebind from a running
# safe process) and is known-good by construction: we have the token
# in .saferc and just verified `safe status` returned ok before
# create() returned.  The Remote implementation adds an authenticate/
# status retry loop which is meaningless for locals.  Just set-as-
# current and return; a caller doing Service::Vault->attach(url => X)
# where X happens to be a local vault should get the same
# "usable vault handle" semantics as it would from Remote.
sub connect_and_validate {
	my ($self) = @_;
	return $self->set_as_current;
}

# }}}
# pid - return the pid of the local vault instance {{{
sub pid {
	return $_[0]->{name} =~ /.*_([0-9]*)$/ ? $1 : undef;
}

# }}}

# shutdown - shutdown the local vault (which should restore previous safe target) {{{
sub shutdown {
	my $self = shift;

	# Don't shut down parent process provided local vault;
	unless ($self->pid == $$) {
		debug(
			"Not shutting down local vault %s because it is owned by a different process",
			$self->pid
		);
		return;
	}

	# Exit if the local vault is already shut down
	unless ($self->{safe_pid}) {
		debug "Local vault %s is already shut down", $self->{name};
		return;
	}

	# Shutdown strategy: Kill the vault process FIRST. When vault dies, the
	# safe process detects this and self-terminates, cleaning up .saferc
	# references. Killing safe first would orphan the vault process.
	if ($self->{vault_pid}) {
		my $signal = 'INT';
		my $tries = 0;
		while (_process_running($self->{vault_pid})) {
			trace "Shutting down vault $self->{vault_pid} with $signal";
			kill $signal => $self->{vault_pid};
			select(undef, undef, undef, 0.5);
			$tries += 1;
			$signal = 'TERM' if ($tries > 4);
			$signal = 'KILL' if ($tries > 8);
		}
	}
	# Wait for safe to self-terminate after vault death. The initial signal
	# is empty (just wait). If safe hasn't exited after 10 iterations,
	# escalate to TERM, then KILL after 20 iterations.
	if ($self->{safe_pid}) {
		my $signal = '';
		my $tries = 0;
		select(undef, undef, undef, 0.20);
		while (_process_running($self->{safe_pid})) {
			if ($signal) {
				trace "Shutting down safe $self->{safe_pid} with $signal";
				kill $signal => $self->{safe_pid}
			}
			select(undef, undef, undef, 0.20);
			$tries += 1;
			$signal = 'TERM' if ($tries > 10);
			$signal = 'KILL' if ($tries > 20);
		}
	}
	trace(
		"Shut down local vault %s - Output:\n%s",
		$self->{name}, slurp($self->{logfile})
	);
	$self->{safe_pid} = $self->{vault_pid} = undef;
	return;
}

# }}}
# DESTROY - perl descructor: will shutdown local vault if it hasn't been already shut down {{{
sub DESTROY {
	$_[0]->shutdown if $_[0]->{safe_pid};
}

# }}}
# }}}


### Helper functions {{{
# _port_free - true if we can bind <port> on the loopback right now {{{
sub _port_free {
	my ($port) = @_;
	# Bind rather than connect: a refused connection only proves nothing is
	# listening, not that the port is ours to take.  ReuseAddr is off so a
	# socket lingering in TIME_WAIT reads as occupied, which is what vault
	# will find a moment later.
	my $sock = IO::Socket::IP->new(
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Proto     => 'tcp',
		Listen    => 1,
		ReuseAddr => 0,
	) or return 0;
	close($sock);
	return 1;
}

# }}}
# _shuffled_ports - the range in a pid-varying order, without using rand() {{{
# Fisher-Yates driven by a local linear congruential generator.  Perl's rand()
# is process-global mutable state: seeding it for a fork-distinct order would
# rewrite the stream every other caller is drawing from, and leaving it alone
# means forked children inherit the parent's state and shuffle identically.
# A local generator sidesteps the choice -- nothing to seed, nothing to
# restore, correct in a forked child by construction.
#
# An LCG is a weak PRNG.  That is fine: the requirement is to spread probes
# apart so concurrent scans under different uids (which hold different startup
# locks, and so cannot see each other) do not converge, not to be
# unpredictable.
sub _shuffled_ports {
	my ($min, $max, $seed) = @_;

	# The multiply below overflows 2^53, so without this the intermediate
	# promotes to a double on a 32-bit perl and silently drops the low bits
	# the mask then keeps -- degrading the shuffle rather than failing.
	# Wrapping is the normal behaviour for an LCG anyway.
	use integer;

	# Default seed mixes the pid -- distinct per forked child, since $$ is the
	# one piece of state a fork does not duplicate -- with the clock, so that
	# recycled pids do not replay an earlier run's order.
	my $state = ($seed // ($$ * 2654435761 + time)) & 0x7FFFFFFF;

	my @ports = ($min .. $max);
	for (my $i = $#ports; $i > 0; $i--) {
		$state = ($state * 1103515245 + 12345) & 0x7FFFFFFF;
		# Take the index from the HIGH bits.  An LCG's low bits have very
		# short periods -- bit 0 alternates, bit 1 cycles every 4 -- so a
		# plain modulo reads exactly its worst output and clusters the
		# result badly: measured, that put 17x the expected number of runs
		# on a single starting port.
		my $j = ($state >> 16) % ($i + 1);
		@ports[$i, $j] = @ports[$j, $i];
	}
	return @ports;
}

# }}}
# _find_free_port - first free port from a pid-varying walk of the range {{{
sub _find_free_port {
	my ($min, $max, $seed) = @_;
	$min //= LOCAL_VAULT_PORT_MIN;
	$max //= LOCAL_VAULT_PORT_MAX;

	for my $port (_shuffled_ports($min, $max, $seed)) {
		next unless _port_free($port)
			&& _port_free($port + VAULT_CLUSTER_PORT_OFFSET);
		return $port;
	}
	bail(
		"No free port for a local vault in the range %d-%d.  Every port in ".
		"that range is in use, or held by a stale vault from an interrupted ".
		"run -- check with #C{lsof -nP -iTCP -sTCP:LISTEN}.",
		$min, $max
	);
}

# }}}
# _lock_local_vault_startup - serialize local vault startup machine-wide {{{
# Two races make concurrent `safe local` invocations unsafe, and both are
# closed by holding this lock until the new vault is listening:
#
#   1. safe picks its port by scanning for a refused connection, then execs
#      `vault version` before `vault server` ever binds.  Concurrent callers
#      all observe the same port free and all choose it.
#   2. `safe local` writes the new target into ~/.saferc *as current*, then
#      re-reads the file and talks to whatever `current` now says.  The write
#      is an unlocked whole-file rewrite, so concurrent callers clobber each
#      other's entries and one safe ends up initializing another's vault.
#
# Keyed by uid, not by HOME: race 1 is machine-global, so per-HOME locks (as
# scoped-HOME test harnesses would produce) would not close it.
sub _lock_local_vault_startup {
	my $path = File::Spec->catfile(
		File::Spec->tmpdir, sprintf("genesis-local-vault-%d.lock", $<)
	);
	open(my $fh, '>>', $path) or bail(
		"Could not open local vault startup lock %s: %s", $path, $!
	);
	flock($fh, LOCK_EX) or bail(
		"Could not acquire local vault startup lock %s: %s", $path, $!
	);
	return $fh;
}

# }}}
sub _generate_alias {
	my $name = shift;
	# Idempotent: when called with an already-full alias (from
	# all_vaults iterating `safe targets --json`, which returns the
	# alias verbatim), preserve it.  Otherwise double-prefixing
	# produces 'local_vault_local_vault_..._<pid>' that never
	# matches the .saferc entry.
	return $name if $name =~ /^local_vault_.+_\d+$/;
	my $pid = $name =~ /^local_vault_(.*)_([0-9]+)$/ ? $2 : $$;
	$name =~ s/^local_vault_(.*)_[0-9]+$/$1/; # strip back to original name
	return "local_vault_${name}_${pid}";
}

# _lookup_vault_target - read a local vault's target out of ~/.saferc {{{
# Tries up to $tries times, 100ms apart, so a caller that has just started safe
# can wait out the gap between the server coming up and safe registering it.
# An empty or unparseable read is a not-yet, not a failure: returning undef lets
# the caller report the real problem by name.
sub _lookup_vault_target {
	my ($alias, $tries) = @_;
	$tries ||= 1;

	my $vault_info;
	for my $attempt (1..$tries) {
		my $raw = run({env => {SAFE_TARGET => undef}},
			"safe targets --json | jq '.[] | select(.name==\"$alias\")'"
		);
		$vault_info = eval {read_json_from($raw)}
			if defined($raw) && $raw =~ /\S/;
		last if ($vault_info && ref($vault_info) eq 'HASH' && $vault_info->{url});
		select(undef,undef,undef,0.1) if $attempt < $tries;
	}
	return $vault_info;
}

# }}}
# `ps -eo pid,ppid,command` reports a process by the path it was exec'd with.
# safe >= 1.20.0 resolves the server binary before spawning it, so the command
# column reads /home/linuxbrew/.linuxbrew/bin/vault server rather than a bare
# `vault server`, and a filter anchored on the bare name never matches.  create()
# then bails with "Could not start local memory-backed vault" over a vault that
# is running normally.  Allow a leading path on both binaries.
sub _get_safe_process {
	my ($alias, $timeout) = @_;
	return _get_process("\\s\\+[^ ]*[s]afe local -m --as $alias", $timeout);
}

# The server is whichever engine safe chose, and safe >= 1.20.0 will drive
# OpenBao -- taking whichever of `vault` or `bao` it finds first on $PATH, or
# the one pinned by --engine/SAFE_ENGINE.  Genesis gates OpenBao on that same
# version, so naming one engine here made the OpenBao path unreachable: the
# server started, went unseen, and create() abandoned it.
sub _get_vault_process {
	my ($ppid, $timeout) = @_;
	return _get_process("\\s\\+$ppid\\s\\+[^ ]*\\([v]ault\\|[b]ao\\) server", $timeout);
}

sub _get_process {
	my ($filter, $timeout) = @_;
	$timeout = sprintf("%0.f", ($timeout//5)/0.05);
	my $i = 0;
	while ($i < $timeout ) {
		$i += 1;
		select(undef,undef,undef,0.05);
		my $ps_line = scalar(qx(ps -eo 'pid,ppid,command' | grep '$filter' | sed -e 's/^ *//' | head -n 1));
		trace "psline: $ps_line";
		chomp $ps_line;
		next unless $ps_line;

		my ($pid, $ppid, $cmd) = split(/ +/, $ps_line, 3);
		return {pid => $pid, ppid => $ppid, cmd => $cmd}
	}
	return undef;
}

sub _process_running {
	my $pid = shift;
	trace "Checking for process ID $pid...";
	my $out = scalar(qx(ps -o 'pid,command' -p $pid | grep '^\\s*$pid'));
	my $rc = $? >> 8;
	trace "[rc: $rc] $out";
	return $rc == '0';
}
# }}}
1;
# vim: fdm=marker:foldlevel=1:noet
