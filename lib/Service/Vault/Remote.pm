package Service::Vault::Remote;
use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term;

use Genesis::UI;
use JSON::PP qw/decode_json/;
use POSIX ();
use UUID::Tiny ();

use base 'Service::Vault';

### Class Variables {{{
my (@all_vaults, $default_vault, $current_vault);
# }}}

### Class Methods {{{

# create - create a new safe target and target it {{{
sub create {
	my ($class, $url, $name, %opts) = @_;

	my $default = $class->default(1);

	my @cmd = ('safe', 'target', $url, $name);
	push(@cmd, '-k') if $opts{skip_verify};
	push(@cmd, '-n', $opts{namespace}) if $opts{namespace};
	push(@cmd, '--no-strongbox') if $opts{no_strongbox};
	my ($out,$rc,$err) = run({stderr => 0, env => {VAULT_ADDR => "", SAFE_TARGET => ""}}, @cmd);
	run('safe','target',$default->{name}) if $default; # restore original system target if there was one
	bail(
		"Could not create new Safe target #C{%s} pointing at #M{%s}:\n %s",
		$name, $url, $err
	) if $rc;
	my $vault = $class->new($url, $name, !$opts{skip_verify}, $opts{namespace}, !$opts{no_strongbox}, $opts{mount});
	for (0..scalar(@all_vaults)-1) {
		if ($all_vaults[$_]->{name} eq $name) {
			$all_vaults[$_] = $vault;
			return $vault;
		}
	}
	push(@all_vaults, $vault);
	return $vault;
}

# }}}
# target - builder for vault based on locally available vaults {{{
#
# Two code paths:
#   1. Target given (alias or url): delegates to the parent
#      Service::Vault->target, whose lookup is class-agnostic so a
#      local vault at that url is honored.
#   2. Target absent: interactive picker for the user to choose from
#      the Remote vaults on this system.  Remote-specific and stays
#      here.
sub target {
	my ($class, $target, %opts) = @_;

	# Non-interactive path lives on the parent so the naming stays
	# honest ("Service::Vault->target" = class-agnostic lookup).
	return $class->SUPER::target($target, %opts) if defined $target && length $target;

	# Interactive picker: Remote-specific.  All find calls below are
	# deliberately $class->find, i.e. Service::Vault::Remote::find,
	# which filters to Remote objects -- the user is choosing a
	# Remote to connect to.
	$opts{default_vault} ||= $class->default;

	die_unless_controlling_terminal
		"Cannot interactively select vault unless in a controlling terminal - terminating!";

	my $w = (sort {$b<=>$a} map {length($_->{name})} $class->find)[0];

	my (%uses, @labels, @choices);
	$uses{$_->{url}}++ for $class->find;
	for ($class->find) {
		next unless $uses{$_->{url}} == 1;
		push(@choices, $_->{url});
		push(@labels, [csprintf(
		"#%s{%-*.*s}   #R{%-10.10s} #%s{%s}",
		  $_->{name} eq $opts{default_vault}->{name} ? "G" : "-",
		     $w, $w, $_->{name},
		                  $_->{url} =~ /^https/ ? ($_->{verify} ? "" : "(noverify)") : "(insecure)",
		                             $_->{name} eq $opts{default_vault}->{name} ? "Y" : "-",
		                                $_->{url}
		),$_->{name}]);
	}

	my $msg = csprintf("#u{Select Vault:}\n");
	my @invalid_urls = grep {$uses{$_} > 1} keys(%uses);

	if (scalar(@invalid_urls)) {
		$msg .= csprintf("\n".
			"#Y{Note:} One or more vault targets have been omitted because they are alias for\n".
			"      the same URL, which is incompatible with Genesis's distributed model.\n".
			"      If you need one of the omitted targets, please ensure there is only one\n".
			"      target alias that uses its URL.\n");
	}

	bail("There are no valid vault targets found on this system.")
		unless scalar(@choices);

	my $url = prompt_for_choice(
		$msg,
		\@choices,
		$uses{$opts{default_vault}->{url}} == 1 ? $opts{default_vault}->{url} : undef,
		\@labels
	);

	# The picker fed us a URL known to come from a Remote target
	# (choices were built from $class->find above), so class-filtered
	# find is safe and correct here.
	my $vault = ($class->find(url => $url))[0];
	return $vault->connect_and_validate();
}

# }}}
# attach - builder for vault based on loaded environment {{{
sub attach {
	my ($class, %opts) = @_;

	for my $opt (keys %opts) {
		# Allow vault options to be specified by ENV variables.
		my $value = $opts{$opt};
		next unless defined $value;
		$opts{$opt} = $ENV{substr($value,1)} if substr($value,0,1) eq '$';
	}

	$opts{tls} = $opts{url} =~ /https:\/\// ? 1 : 0 if $opts{url} && !defined($opts{tls});

	my $url = delete($opts{url});
	my $alias = delete($opts{alias});
	my $allow_no_vault = $opts{no_vault};
	my $silent = $opts{silent};

	bail "No vault target specified"
		unless $url;
	bail "Expecting vault target '$url' to be a url"
		unless Service::Vault::_target_is_url($url);

	my %filter = (url => $url);
	$filter{verify} = (($opts{tls} && $opts{verify}) ? 1 : 0) if $opts{tls};
	for (qw/namespace strongbox/) {
		$filter{$_} = $opts{$_} if defined($opts{$_});
	}

	my @targets = Service::Vault->find(%filter);
	if (scalar(@targets) <1) {
		my @close_targets = Service::Vault->find(url => $filter{url});
		if (@close_targets) {
			my $msg = "Could not find matching safe target, but the following are similar:\n";
			for my $target (@close_targets) {
				$msg .= "\nAlias:     '$target->{name}'\n";
				for my $property (qw/url namespace strongbox verify/) { # TODO: support name and mount in filter
					$msg .= sprintf("%-11s'%s'", ucfirst($property.":"),$target->{$property});
					$msg .= " (expected '$filter{$property}')" if ($filter{$property} ne $target->{$property});
					$msg .= "\n";
				}
			}
			bail $msg."\nAlter your ~/.saferc or .genesis/config to match, or add a matching target.\n";
		} else {
			# TODO: If alias and url was given, and in a controlling terminal, create safe target
			return if $allow_no_vault;
			bail "Safe target for #M{%s} not found.  Please run\n\n".
					 "  #G{safe target <name> \"%s\"%s}\n\n".
					 "then authenticate against it using the correct auth method before ".
					 "re-attempting this command.",
					 $url, $url,($opts{verify}?"":" -k");
		}
	}
	if (scalar(@targets) >1) {
		my ($named_target) = grep {$_->name eq $alias} @targets;
		if ($named_target) {
			@targets = ($named_target)
		} else {
			bail(
				"Multiple safe targets found for #M{%s}:\n%s\n".
				"\n".
				"Your ~/.saferc file cannot have more than one target for the given ".
				"url, namespace, insecure or strongbox combination.  If you don't, it ".
				"may be that your selected secrets provider is out of date - please ".
				"rerun #G{genesis sp -i}\n".
				"\n".
				"Please remove any duplicate targets before re-attempting this command.",
				$url, join("", map {" - #C{$_->name}\n"} @targets)
			);
		}
	}
	return $targets[0]->connect_and_validate($opts{silent});
}

# }}}
# rebind - builder for rebinding to a previously selected vault (for callbacks) {{{
# TODO: Bind to alias, which encapuslates all the namespace, validation, strongbox, url, etc...
sub rebind {
	# Special builder with less checking for callback support
	my ($class) = @_;

	bail("Cannot rebind to vault in callback due to missing environment variables!")
		unless $ENV{GENESIS_TARGET_VAULT};

	my $vault;
	if (is_valid_uri($ENV{GENESIS_TARGET_VAULT})) {
		$vault = ($class->find(url => $ENV{GENESIS_TARGET_VAULT}))[0];
		bail("Cannot rebind to vault at address '$ENV{GENESIS_TARGET_VAULT}` - not found in .saferc")
			unless $vault;
		trace "Rebinding to $ENV{GENESIS_TARGET_VAULT}: Matches %s", $vault && $vault->{name} || "<undef>";
	} else {
		# Check if its a named vault and if it matches the default (legacy mode)
		if ($ENV{GENESIS_TARGET_VAULT} eq $class->default->{name}) {
			$vault = $class->default()->ref_by_name();
			trace "Rebinding to default vault `$ENV{GENESIS_TARGET_VAULT}` (legacy mode)";
		}
	}
	return unless $vault;
	return $vault->set_as_current;
}

# }}}
# find - return vaults that match filter (defaults to all) {{{
sub find {
	my ($class, %filter) = @_;
	return grep {ref($_) eq $class} $class->SUPER::find(%filter);
}

# }}}
# }}}

### Instance Methods {{{

# connect_and_validate - connect to the vault and validate that its connected {{{
sub connect_and_validate {
	my ($self, $silent) = @_;
	unless ($self->is_current) {
		my $log_id = info({pending => 1, delay => 2000 }, # don't show for 2 seconds (NYI)
			"\n#yi{Verifying availability of vault '%s' (%s)...}",
			$self->name, $self->url
		) unless in_callback || under_test || $silent;
		my $status = $self->status;
		if ($status eq 'unauthenticated') {
			$self->authenticate;
			$status = $self->initialized ? 'ok' : 'uninitialized';
		}
		# TODO: support delayed output:
		#   Implement delay flag to logs
		#   - Print logs after delay specified
		#   - cancel_delayed_log(log_id) clear logs before delay expires by log_id
		#   - have has_been_logged(log_id) for checking
		#   - clear_delay(log_id) clears delay and logs entry
		#
		#   Issues: Perl can only handle one timeout (via alarm) at the same time
		#   - see https://metacpan.org/pod/Time::Out
		#
		#  As it applies here:
		#    if the $log_id hasn't been logged, cancel it and move on if ok, print
		#    it immediately and add bad status
		#    if it has been logged, just do what it currently does
		#
		#  Motive:  Don't print out the vault test if it quickly comes back, but
		#  if it takes a long time, let user's know what its trying to do...
		#
		info ("#%s{%s}", $status eq "ok"?"G":"R", $status)
			unless in_callback || under_test || $silent;
		debug "Vault status: $status";
		bail("Could not connect to vault%s",
			(in_callback || under_test || $silent) ? sprintf(" '%s' (%s): status is %s)", $self->name, $self->url,$status):""
		) unless $status eq "ok";
	}
	return $self->set_as_current;
}

# }}}
# authenticate - attempt to log in with credentials available in environment variables {{{
sub authenticate {
	my $self = shift;
	my $ref = $self->ref();
	my $auth_types = [
		{method => 'approle',  label => "AppRole",                     vars => [qw/VAULT_ROLE_ID VAULT_SECRET_ID/]},
		{method => 'token',    label => "Vault Token",                 vars => [qw/VAULT_AUTH_TOKEN/]},
		{method => 'userpass', label => "Username/Password",           vars => [qw/VAULT_USERNAME VAULT_PASSWORD/]},
		{method => 'github',   label => "Github Peronal Access Token", vars => [qw/VAULT_GITHUB_TOKEN/]},
	];

	return $self->_on_auth_success if $self->authenticated;
	my %failed;
	for my $auth (@$auth_types) {
		my @vars = @{$auth->{vars}};
		if (scalar(grep {$ENV{$_}} @vars) == scalar(@vars)) {
			debug "Attempting to authenticate with $auth->{label} to #M{$ref} vault";
			my ($out, $rc) = $self->query(
				'safe auth ${1} < <(echo "$2")', $auth->{method}, join("\n", map {$ENV{$_}} @vars)
			);
			return $self->_on_auth_success if $self->authenticated;
			debug "Authentication with $auth->{label} to #M{$ref} vault failed!";
			$failed{$auth->{method}} = 1;
		}
	}

	# Last chance, check if we're already authenticated; otherwise fall
	# through to the interactive ladder.  This also forces an update to
	# the token, so we don't have to explicitly do that here.
	return $self->_on_auth_success if $self->authenticated;

	# Interactive fallback: only when a real operator can answer.
	if ($self->_interactive_auth_available) {
		if ($self->_authenticate_interactively) {
			return $self->_on_auth_success if $self->authenticated;
		}
	}

	# Bail with a message that distinguishes "session expired" from
	# "you have not authenticated yet".  The __renewer_armed_at marker
	# is set by start_token_renewer() on success, so its presence
	# tells us we had a working renewable session earlier.
	my $had_session = defined $self->{__renewer_armed_at};
	my $heading = $had_session
		? "Your vault session at #M{$ref} has expired and could not be renewed."
		: "Could not successfully authenticate against #M{$ref} vault with #C{safe}.";
	my $verb = $had_session ? 're-authenticate' : 'authenticate';

	bail(
		"%s\n\nGenesis can automatically %s with #C{safe} in the following ways:\n%s",
		$heading,
		$verb,
		join("", map {
			my $a=$_;
			sprintf(
				"        - #G{%s}, supplied by %s%s\n",
				$a->{label},
				join(' and ', map {"#y{\$$_}"} @{$a->{vars}}),
				($failed{$a->{method}}) ? " #R{[present, but failed]}" : ""
			)
		} @{$auth_types})
	);
}

# }}}
# _on_auth_success - common return path for a successful authenticate() {{{
#
# Called from every "return $self" point in authenticate() so that the
# token renewer is armed regardless of which auth method succeeded (or
# whether we short-circuited on an already-authenticated session).
sub _on_auth_success {
	my ($self) = @_;
	$self->start_token_renewer;
	return $self;
}

# }}}
# DESTROY - reap any running token renewer when the vault goes out of scope {{{
sub DESTROY {
	my ($self) = @_;
	$self->stop_token_renewer;
	return;
}

# }}}
# renewer_pid - accessor for the background renewer child's PID {{{
sub renewer_pid {
	return $_[0]->{__renewer_pid};
}

# }}}
# start_token_renewer - fork a child that keeps the vault token alive {{{
#
# Returns the child PID on success, or undef when:
#   - The token is not renewable (or has zero/undef TTL).
#   - fork() fails.
#
# Dead-man switches:
#   - Idempotent: any prior renewer is stopped before a new one starts,
#     so repeated authenticate() calls don't leak children.
#   - Child body is eval-wrapped.  Every exit path goes through
#     POSIX::_exit, so a `die` cannot fall through to Perl's normal exit
#     machinery (which would run END blocks).
#   - Child's parent-liveness check honours both `kill 0` AND getppid().
#     getppid() == 1 (reparented to init) is a reliable orphan signal
#     immune to PID reuse on long-running systems.
sub start_token_renewer {
	my ($self) = @_;

	# Reap any prior renewer first.
	$self->stop_token_renewer if $self->renewer_pid;

	# token_info() can die (read_json_from bails on malformed/empty
	# response, network error, etc.).  Treat any failure as "no renewer"
	# — fail-closed so authenticate() never crashes when the vault is
	# unreachable or returning garbage.
	my $info = eval { $self->token_info() };
	return undef unless $self->_token_renewal_available($info);

	my $parent_pid = $$;
	my $pid = fork();
	return undef unless defined $pid;

	if ($pid == 0) {
		# CHILD: never `exit`, never `die` uncaught — POSIX::_exit only.
		Genesis::init_forked_child();
		my $rc = eval {
			$self->_run_renewer_loop(
				parent_pid => $parent_pid,
				ttl        => $info->{data}{ttl},
				sleep_fn   => sub { sleep $_[0] },
				kill_fn    => sub {
					# Reparented to init means the original parent is
					# definitively gone, independent of PID reuse.
					return 0 if getppid() == 1;
					return kill 0 => $_[0];
				},
				query_fn   => sub { $self->query(@_) },
				info_fn    => sub { $self->token_info },
			);
		};
		# On die ($@ set, $rc undef): exit non-zero rather than letting
		# Perl's normal exit machinery run END blocks.
		POSIX::_exit(defined($rc) ? $rc : 2);
	}

	$self->{__renewer_pid} = $pid;
	# Marker that this session had a working, renewable token at some
	# point.  Consumed by authenticate()'s bail message to distinguish
	# "your session expired" from "you have not authenticated yet".
	$self->{__renewer_armed_at} = time;
	return $pid;
}

# }}}
# stop_token_renewer - signal and reap the background renewer child {{{
#
# Idempotent: no-op when no renewer PID is stored.  Always clears the
# stored PID regardless of whether kill/waitpid succeed, so a second
# call is safe.
#
# Dead-man switch: TERM is polled with WNOHANG for ~2 seconds; if the
# child refuses to exit (or is stuck in an uninterruptible syscall) the
# stop path escalates to SIGKILL.  Without this, a stuck child would
# block DESTROY and hang Genesis at command exit.
sub stop_token_renewer {
	my ($self) = @_;
	my $pid = delete $self->{__renewer_pid};
	return unless $pid;

	kill 'TERM', $pid;

	my $reaped = 0;
	for (1..20) {
		$reaped = waitpid($pid, POSIX::WNOHANG());
		last if $reaped;        # >0 = reaped, -1 = no such child (race)
		select(undef, undef, undef, 0.1);
	}
	if ($reaped <= 0) {
		# Child ignored TERM or is stuck.  KILL is uninterceptible.
		kill 'KILL', $pid;
		waitpid($pid, 0);
	}
	return;
}

# }}}
# _run_renewer_loop - testable renewer loop body {{{
#
# Returns an exit code (0 or 1) instead of calling POSIX::_exit directly
# so the body can be unit-tested without forking.  All side-effecting
# operations are injected so tests can drive the loop in-process:
#
#   parent_pid  parent PID to monitor (kill 0 => $parent_pid)
#   ttl         initial token ttl, seconds
#   sleep_fn    invoked with the computed sleep duration
#   kill_fn     invoked with parent_pid; truthy => alive, false => dead
#   query_fn    invoked with ('vault', 'token', 'renew');
#               returns ($out, $rc, $err)
#   info_fn     invoked after each renew; returns token_info hash
#
# Termination:
#   - parent reported dead       => return 0
#   - renew returned non-zero rc => return 1 (parent re-auths next call)
#   - token becomes non-renewable
#     or ttl decays to 0/undef   => return 0
#
# Sleep computation: half-life with a 60s floor so pathologically short
# tokens don't busy-renew.
sub _run_renewer_loop {
	my ($self, %opts) = @_;
	my $parent_pid = $opts{parent_pid};
	my $ttl        = $opts{ttl};
	my $sleep_fn   = $opts{sleep_fn};
	my $kill_fn    = $opts{kill_fn};
	my $query_fn   = $opts{query_fn};
	my $info_fn    = $opts{info_fn};

	while (1) {
		my $sleep_for = $ttl >= 120 ? int($ttl / 2) : 60;
		$sleep_fn->($sleep_for);

		return 0 unless $kill_fn->($parent_pid);

		my ($out, $rc, $err) = $query_fn->('vault', 'token', 'renew');
		return 1 if $rc != 0;

		my $info = $info_fn->();
		return 0 unless $self->_token_renewal_available($info);
		$ttl = $info->{data}{ttl};
	}
}

# }}}
# _authenticate_interactively - prompt-driven re-auth flow {{{
#
# Walks the operator through choosing an auth method and entering
# credentials, then issues the same `safe auth $method` query the
# env-var path uses.  Sensitive fields (tokens, passwords, secret-ids)
# are collected via prompt_for_password (hidden input); identity
# fields (role-id, username) via prompt_for_line.
#
# Returns truthy when $self->authenticated() agrees the new
# credentials worked.  Returns 0 when the operator aborts, enters a
# blank credential, or the safe call fails post-prompt.
sub _authenticate_interactively {
	my ($self) = @_;
	my $ref = $self->ref;

	my $methods = [
		{ value => 'approle',
		  label => 'AppRole (role-id / secret-id)',
		  fields => [
		  	{ prompt => 'Role ID',   hide => 0 },
		  	{ prompt => 'Secret ID', hide => 1 },
		  ],
		},
		{ value => 'token',
		  label => 'Vault Token (paste a token)',
		  fields => [
		  	{ prompt => 'Vault Token', hide => 1 },
		  ],
		},
		{ value => 'userpass',
		  label => 'Username / Password',
		  fields => [
		  	{ prompt => 'Username', hide => 0 },
		  	{ prompt => 'Password', hide => 1 },
		  ],
		},
		{ value => 'github',
		  label => 'GitHub Personal Access Token',
		  fields => [
		  	{ prompt => 'GitHub Personal Access Token', hide => 1 },
		  ],
		},
	];

	my @choices = (
		(map { {value => $_->{value}, label => $_->{label}} } @$methods),
		{value => 'abort', label => 'Abort'},
	);

	my $choice = new_prompt_for_choice(
		header => "Re-authenticate to vault $ref:",
		description => "method",
		choices => \@choices,
	);
	return 0 if !defined($choice) || $choice eq 'abort';

	my ($spec) = grep { $_->{value} eq $choice } @$methods;
	return 0 unless $spec;

	my @creds;
	for my $field (@{$spec->{fields}}) {
		my $value = $field->{hide}
			? prompt_for_password($field->{prompt})
			: prompt_for_line(undef, $field->{prompt}, undef, undef, undef);
		return 0 unless defined($value) && $value ne '';
		push @creds, $value;
	}

	my ($out, $rc) = $self->query(
		'safe auth ${1} < <(echo "$2")',
		$spec->{value},
		join("\n", @creds),
	);
	return 0 if $rc;

	return $self->authenticated ? 1 : 0;
}

# }}}
# _interactive_auth_available - pure: can we prompt the operator? {{{
#
# True only when:
#   - We're attached to a controlling terminal.
#   - We're not running inside a Genesis kit-hook callback
#     (the parent Genesis owns the user interaction in that case).
#   - GENESIS_QUIET is not set.
#   - GENESIS_NONINTERACTIVE is not set (explicit operator opt-out
#     even when a TTY happens to be attached, e.g. some CI runners).
#   - GENESIS_TESTING is not set (test harnesses must never prompt).
sub _interactive_auth_available {
	return 0 unless in_controlling_terminal();
	return 0 if in_callback();
	return 0 if envset('QUIET');
	return 0 if envset('GENESIS_NONINTERACTIVE');
	return 0 if under_test();
	return 1;
}

# }}}
# _token_renewal_available - pure: does this token support background renewal? {{{
sub _token_renewal_available {
	my ($self, $info) = @_;
	return 0 unless $info && ref($info) eq 'HASH';
	my $data = $info->{data} or return 0;
	return 0 unless $data->{renewable};
	my $ttl = $data->{ttl};
	return 0 unless defined($ttl) && $ttl =~ /^\d+$/ && $ttl > 0;
	return 1;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
