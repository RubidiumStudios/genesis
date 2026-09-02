package Service::Vault;
use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term qw/csprintf/;

use Genesis::UI;
use JSON::PP qw/decode_json/;
use Time::HiRes qw/gettimeofday/;
use UUID::Tiny ();

### Class Variables {{{
my (@all_vaults, $default_vault, $current_vault);
# }}}

### Class Methods {{{

# new - raw instantiation of a vault object {{{
sub new {
	my ($class, $url, $name, $verify, $namespace, $strongbox, $mount) = @_;
	$mount =~ s#^/*(.*[^/])/*$#/$1/# if $mount;
	return bless({
			url       => $url,
			name      => $name,
			verify    => $verify ? 1 : 0, # Cleans out JSON::Boolean types
			namespace => $namespace || '',
			# Tri-state: undef means no safe target ever stated it.  Coercing
			# to true here is what made safe's old default indistinguishable
			# from a deliberate choice -- see strongbox_intent below.
			strongbox => defined($strongbox) ? ($strongbox ? 1 : 0) : undef,
			mount     => $mount || '/secret/',
			id        => sprintf("%s-%06d",$name,rand(1000000))
		}, $class);
}

# }}}
# create - return all vaults known to safe {{{
sub create {
  my $class = shift;
  bug 'Cannot directly instantiate a Genesis::Vault - use a derived class'
    if $class eq __PACKAGE__;
	# FIXME:  Should subclasses call this to add a created vault to the @all_vaults class property?
  bug "Expected $class to provide 'create' method, but it did not (or called SUPER)"
    if $class eq __PACKAGE__;
}

# }}}
# strongbox_intent - what ~/.saferc states about a target, if anything {{{
sub strongbox_intent {
	my ($alias) = @_;
	return undef unless defined $alias;

	# safe locates its rc at $HOME/.saferc in every version that has ever
	# shipped, with no environment override, so this needs no discovery.
	my $rc = ($ENV{HOME} // '') . '/.saferc';
	return undef unless -f $rc;

	# The file belongs to safe.  An unreadable or unparseable one says
	# nothing about intent, and must not take down a command over a flag
	# that only affects seal-state reporting.
	my $config = eval {load_yaml_file($rc)};
	return undef unless ref($config) eq 'HASH';

	my $target = ($config->{vaults} // {})->{$alias};
	return undef unless ref($target) eq 'HASH';

	# Two keys, two eras.  v1.20.0+ writes `strongbox` and omits it when
	# off; v1.4.0 through v1.10.0 wrote `no_strongbox` and omitted it when
	# on.  Absence therefore means opposite things depending on who wrote
	# the file, which is why neither key present has to stay undef rather
	# than pick a side.  `strongbox` wins when both appear: safe's own
	# migration rewrites the legacy key into it, so it is the newer intent.
	return $target->{strongbox} ? 1 : 0 if exists $target->{strongbox};
	return $target->{no_strongbox} ? 0 : 1 if exists $target->{no_strongbox};
	return undef;
}

# }}}
# all_vaults - return all vaults known to safe {{{
sub all_vaults {
	my @available_vaults;
	my @targets = sort {$a->{name} cmp $b->{name}} @{
		read_json_from(run({env => {VAULT_ADDR => undef, SAFE_TARGET => undef}}, "safe targets --json"))
	};
	require Service::Vault::Local;
	require Service::Vault::Remote;
	for (@targets) {
		if (Service::Vault::Local->valid_local_vault($_->{name})) {
			push @available_vaults, (
				Service::Vault::Local->rebind($_->{name})
				|| Service::Vault::Local->create($_->{name})
			);
		} else {
			push @available_vaults, Service::Vault::Remote->new(@{$_}{qw(
				url name verify namespace strongbox mount
			)})
		}
	}
	return @available_vaults;
}

# }}}
# find - return vaults that match filter (defaults to all) {{{
sub find {
	my ($class, %filter) = @_;

	@all_vaults = all_vaults() unless @all_vaults; #TODO: is it that important to cache this?  Does it save much time?
	my @matches = @all_vaults;
	for my $quality (keys %filter) {
		@matches = grep {$_->{$quality} eq $filter{$quality}} @matches;
	}
	return @matches;
}

# }}}
# find_by_target - return all vaults matching url associated with specified target alias or url {{{
sub find_by_target {
	my ($class, $target) = @_;
	my ($url, @aliases) = _get_targets($target);
	return map {$class->find(name => $_)} @aliases;
}

# }}}
# default - return the default vault (targeted by system) {{{
sub default {
	my ($class,$refresh) = @_;
	unless ($default_vault && !$refresh) {
		my $json = read_json_from(run({env => {VAULT_ADDR => "", SAFE_TARGET => ""}},"safe target --json"));
		$default_vault = (Service::Vault->find(name => $json->{name}))[0];
	}
	return $default_vault;
}

# }}}
# target - resolve an alias or URL to a vault and connect_and_validate {{{
sub target {
	my ($class, $target, %opts) = @_;
	bail "Service::Vault->target requires an alias or url (use ".
		"Service::Vault::Remote->target for interactive selection)"
		unless defined $target && length $target;

	my ($url, @targets) = _get_targets($target);
	bail "Safe target \"#M{%s}\" not found.  Please create it".
		 "and authorize against it before re-attempting this command.",
		 $target
		if scalar(@targets) < 1;
	bail "Multiple safe targets use url #M{%s}:\n%s\n".
		 "\n".
		 "Your ~/.saferc file cannot have more than one target for the ".
		 "given url.  Please remove any duplicate targets before ".
		 "re-attempting this command.",
		 $url, join("", map {" - #C{$_}\n"} @targets)
		if scalar(@targets) > 1;

	# Deliberate: Service::Vault->find here, not $class->find.  The
	# resolved URL may point at a Local vault; a subclass override
	# like Service::Vault::Remote::find would silently drop it.
	# Matches the class-agnostic lookup pattern already used by
	# Service::Vault::Remote::attach.
	my $vault = (Service::Vault->find(url => $url))[0];
	return $vault->connect_and_validate();
}

# }}}
# set_default - set the default vault (targeted by system) {{{
sub set_default {
	my ($class, $vault) = @_;
	my ($out, $rc, $err) = run({env => {VAULT_ADDR => "", SAFE_TARGET => ""}},"safe", "target", $vault->name);
	bail(
		"Could not set default vault to #C{%s}:\n%s",
		$vault->name, $err
	) unless $rc == 0;
	return $vault;
}
# }}}
# current - return the last vault returned by attach, target, or rebind {{{
sub current {
	return $current_vault
}

# }}}
# clear_all - clear all cached data {{{
sub clear_all {
	for (@all_vaults) {
		delete($_->{_env});
	}
	@all_vaults=();
	$default_vault=undef;
	$current_vault=undef;
	return $_[0]; # chaining Service::Vault
}
# }}}
# find_single_match_or_bail - error out if there are duplicate vaults for a url {{{
sub find_single_match_or_bail {

	my ($class, $url, $current) = @_;
	my @matches =  $class->find(url => $url);

	bail(
		"\nMore than one target is specified for URL '%s'\n".
		"Please edit your ~/.saferc, and remove all but one of these:\n".
		"  - %s\n".
		"(or alter the URLs to be unique)",
		$url, join("\n  - ", map {
			$_->name eq ($current||'') ? "#G{".$_->name." (current)}" : "#y{".$_->name."}"
		} @matches)
	) if scalar(@matches) > 1;
	return $matches[0]
}

# }}}
# rebind - callback-context vault lookup by URL or legacy name {{{
sub rebind {
	my ($class) = @_;

	bail("Cannot rebind to vault in callback due to missing environment variables!")
		unless $ENV{GENESIS_TARGET_VAULT};

	my $vault;
	if (is_valid_uri($ENV{GENESIS_TARGET_VAULT})) {
		# URL form: class-agnostic lookup -- accepts whatever
		# vault kind sits at this URL in .saferc.
		$vault = ($class->find(url => $ENV{GENESIS_TARGET_VAULT}))[0];
		bail("Cannot rebind to vault at address '$ENV{GENESIS_TARGET_VAULT}` - not found in .saferc")
			unless $vault;
		trace "Rebinding to $ENV{GENESIS_TARGET_VAULT}: matches %s",
			$vault->{name} || "<unnamed>";
	} else {
		# Legacy named-target path: match against the default vault.
		my $default = $class->default;
		if ($default && $ENV{GENESIS_TARGET_VAULT} eq $default->{name}) {
			$vault = $default->ref_by_name();
			trace "Rebinding to default vault `$ENV{GENESIS_TARGET_VAULT}` (legacy mode)";
		}
	}
	return unless $vault;
	return $vault->set_as_current;
}

# }}}
# get_vault_from_descriptor - find unique vault from vault descriptor, or bail {{{
sub get_vault_from_descriptor {

	my ($class, $descriptor, $source) = @_;
	my $filter = $class->parse_vault_descriptor($descriptor, $source);
	my ($alias,$url) = delete(@{$filter}{qw/alias url domain port tls/});

	bail(
		"No url specified by vault descriptor"
	) unless $url;
	my @matches =  $class->find(url => $url, %$filter);

	# TODO: If none found, try by alias name?  Potential for mismatch though...

	if (@matches > 1) {
		my @named_matches = grep {$_->name eq $alias} @matches;
		@matches = @named_matches if @named_matches == 1;
	}

	return $matches[0] if @matches <= 1;

	# Error processing
	my ($alias_clause, $alias_msg) = ('','');
	if ($alias) {
		$alias_clause = ", (and none match the provided vault alias of '$alias').";
		$alias_msg = ", or add/modify the alias of the desired target to '$alias'"
	}

	my $default = $class->default->name;
	my $current = $ENV{GENESIS_TARGET_VAULT};

	bail(
		"\nMore than one target is specified for URL '%s'%s\n\n".
		"        Please edit your ~/.saferc, and remove all but one of these:\n".
		"        - %s\n".
		"        (or alter the URLs to be unique%s)",
		$url,$alias_clause, join("\n        - ", map {
			$_->name eq ($current||'')
				? "#G{".$_->name." (current)}"
				: $_->name eq ($default||'')
					? "#g{".$_->name." (default)}"
					: "#y{".$_->name."}"
		} @matches), $alias_msg
	);
}

# }}}
# parse_vault_descriptor - Get all the components of the genesis.vault {{{
sub parse_vault_descriptor {
	my ($class, $vault_info, $source) = @_;
	$source ||= 'genesis.vault';
	my ($url, $verify, $alias, $namespace, $strongbox, $tls, $domain, $port);
	$strongbox = 1;
	$vault_info =~ s/ as ([^ ]*) / / and $alias = $1;
	for my $clause (split(' ',$vault_info)) {
		if ($clause =~ /^(no-)?strongbox$/) {
			$strongbox = $1 ? 0 : 1;
		} elsif ($clause =~ /^(no-)?verify/) {
			$verify = $1 ? 0 : 1;
		} elsif ($clause =~ /^(http(s)?:\/\/([^:]*)(?::([0-9]+))?)(?:\/(.*))?$/) {
			$url = $1;
			$tls = ($2||'' eq 's');
			$domain = $3;
			$port = $4;
			$namespace = $5;
		} else {
			$ENV{GENESIS_TRACE}=1;
			dump_stack();
			bail(
				"Unknown clause in #G{$source}: '#Y{$clause}'\n".
				"Expected http#Cu{s}://<domain-or-ip>#Cu{:<port>}#Cu{/<namespace>} #Cu{as <alias>} #Cu{[no-]verify} #Cu{[no-]strongbox}\n".
				"#i{Values in }#Cui{cyan}#i{ are optional}"
			)
		}
	}
	bail(
		"Missing connect clause in #G{$source}\n".
		"Expected http#Cu{s}://<domain-or-ip>#Cu{:<port>}#Cu{/<namespace>} #Cu{as <alias>} #Cu{[no-]verify} #Cu{[no-]strongbox}\n".
		"#i{Values in }#Cui{cyan}#i{ are optional}"
	) unless $url;
	$verify = $tls unless defined($verify);

	return wantarray ? (
		$url, $verify, $namespace, $alias, $strongbox
	) : {
		url => $url,
		verify => $verify,
		alias => $alias,
		namespace => $namespace,
		strongbox => $strongbox,
		tls => $tls,
		domain => $domain,
		port => $port
	};
}

# }}}
# TODO: Validate dependencies with output that is compatible wth
# Genesis::Command::check_reqs
# }}}

### Instance Methods {{{

# public accessors: url, name, port, verify, namespace, strongbox, tls {{{
sub url {
	$_[0]->{url};
}

sub name {
	$_[0]->{name};
}

# undef for urls that rely on the scheme's default port -- callers that care
# about the port are local vaults, which always carry an explicit one.
sub port {
	$_[0]->{url} =~ m{^\w+://[^/:]+:(\d+)} ? $1 : undef;
}

sub verify {
	$_[0]->{verify};
}

sub namespace {
	$_[0]->{namespace};
}

sub strongbox {
	$_[0]->{strongbox};
}

sub tls {
	$_[0]->{url} =~ "^https://";
}

#}}}
# connect_and_validate - connect to the vault and validate that its connected {{{
sub connect_and_validate {
	bug(
		"Expected %s to provide 'connect_and_validate' method, but it did not (or called SUPER)",
		ref($_[0])
	);
	# FIXME:  Should subclasses call this to set object as current?
}

# }}}
# authenticate - attempt to log in with credentials available in environment variables {{{
sub authenticate {
	bug(
		"Expected %s to provide 'authenticate' method, but it did not (or called SUPER)",
		ref($_[0])
	);
}

# }}}
# authenticated - returns true if authenticated {{{
sub authenticated {
	my $self = shift;
	delete($self->{_env}); # Force a fresh token retrieval
	return unless $self->token;
	my ($auth,$rc,$err) = read_json_from($self->query({stderr => '/dev/null'},'safe auth status --json'));
	return $rc == 0 && $auth->{valid};
}

# }}}
# initialized - returns true if initialized for Genesis {{{
sub initialized {
	my $self = shift;
	my $secrets_mount = $ENV{GENESIS_SECRETS_MOUNT} || $self->{mount};
	$self->has($secrets_mount.'handshake') || ($secrets_mount ne '/secret/' && $self->has('/secret/handshake'))
}

# }}}
# query - make safe calls against this vault {{{
sub query {
	my $self = shift;
	my $opts = ref($_[0]) eq "HASH" ? shift : {};
	my @cmd = @_;
	unshift(@cmd, 'safe') unless $cmd[0] eq 'safe' || $cmd[0] =~ /^safe /;
	$opts->{env} ||= {};
	$opts->{env}{DEBUG} = ""; # safe DEBUG is disruptive
	$opts->{env}{SAFE_TARGET} = $self->ref unless defined($opts->{env}{SAFE_TARGET});
	$opts->{stderr} = 0 unless defined($opts->{stderr});
	return run($opts, @cmd);
}

# }}}
# get - get a key or all keys under for a given path {{{
sub get {
	my ($self, $path, $key) = @_;
	$path =~ s/\/{2,}/\//g; # Clean up any double slashes from joins
	if (!defined($key) && $path =~ /:/) {
		($path, $key) = $path =~ m/^(.*?)(?::([^:]*))?$/;
	}
	if (defined($key)) {
		my ($out,$rc) = $self->query({redact_output => 1}, 'get', "$path:$key");
		return $out if $rc == 0;
		debug(
			"#R{[ERROR]} Could not read #C{%s:%s} from vault at #M{%s}",
			$path, $key,$self->{url}
		);
		return undef;
	}
	my $start = gettimeofday();
	my ($yaml,$rc,$err) = $self->query({stderr => 0, redact_output => 1}, 'get', $path);
	my $values;
	unless ($rc) {
		# safe exited cleanly, so let the payload decide rather than stderr:
		# a noverify target draws a TLS warning on every call, and treating
		# that as failure discards a perfectly good read.  stderr is still
		# the signal when safe fails without saying so in its exit code --
		# an unparseable payload keeps the error below.  Same reasoning as
		# read_json_from, which overrides $err for the JSON paths.
		trace(
			"safe wrote to stderr but exited 0; deferring to the payload: %s", $err
		) if $err;
		local $@;
		eval {$values = load_yaml($yaml)};
		$err = $@;
	}
	if ($rc || $err) {
		debug(
			"#R{[ERROR]} Could not read all key/value pairs from #C{%s} in vault at #M{%s}:%s\nexit code: %s",
			$path,$self->{url},$err || '',$rc
		);
		return {};
	}
	bail(
		"Expected #C{%s} to return a hash of key/value pairs, but got a %s",
		$path, ref($values)
	) unless ref($values) eq 'HASH';
	trace(
		"Exported %s key/value pairs from #C{%s} in vault at #M{%s} in %.3f seconds",
		scalar(CORE::keys %$values), $path, $self->{url}, gettimeofday() - $start
	);
	return $values;
}

# }}}
# get_path - get all the keys under a given path, including subpaths {{{
sub get_path {
	my ($self, $path) = @_;
	$path =~ s{(^/*|/*$)}{}; # Trim preceeding and trailing / as safe doesn't honour it
	my ($data,$rc,$err) = read_json_from($self->query({stderr => 0, redact_output => 1}, 'export', $path));
	if ($rc || $err) {
		debug(
			"#R{[ERROR]} Could not read all key/value pairs from #C{%s} in vault at #M{%s}:%s\nexit code: %s",
			$path,$self->{url},$err || '',$rc
		);
		return {};
	}

	my $results = {};
	for my $subpath (sort keys %$data) {
		if ($subpath eq $path) {
			$results = delete($data->{$subpath}{__flattened__})
				? Genesis::unflatten($data->{$subpath})
				: $data->{$subpath};
			next;
		}
		my @path_bits = split('/',substr($subpath,length($path)+1));
		my $refobj = $results;
		$refobj = $refobj->{shift @path_bits} //= {} while @path_bits > 1;
		$refobj->{$path_bits[0]} = delete($data->{$subpath}{__flattened__})
			? Genesis::unflatten($data->{$subpath})
			: $data->{$subpath};
	}
	return $results;
}
# }}}
# set - write a secret to the vault (prompts for value if not given) {{{
sub set {
	my ($self, $path, @args) = @_;
	$path =~ s/\/{2,}/\//g; # Clean up any double slashes from joins

	# A joined path:key names the key, so what follows is a value -- and
	# only one, since pairs after it would name a second key.
	if ($path =~ /:/) {
		my ($base, $key) = $path =~ m/^(.*?):([^:]*)$/;
		bail(
			"Could not write to #C{%s} in vault at #M{%s}: a joined path:key ".
			"names a single key, so it takes at most one value.",
			$path, $self->{url}
		) if @args > 1;
		($path, @args) = ($base, $key, @args);
	}

	bail(
		"Could not write to #C{%s} in vault at #M{%s}: no key was given.",
		$path, $self->{url}
	) unless @args;

	# A lone key, or an explicit undef value, means "prompt for it" -- the
	# undef case would otherwise read as a pair with an empty value.
	if (@args == 1 || (@args == 2 && !defined($args[1]))) {
		my $key = $args[0];
		# Interactive - you must supply the prompt before hand
		die_unless_controlling_terminal
			"#R{[ERROR]} Cannot interactively provide secrets unless in a controlling terminal - terminating!";
		my ($out,$rc) = $self->query({interactive => 1},'set', $path, $key);
		bail(
			"Could not write #C{%s:%s} to vault at #M{%s}",
			$path, $key,$self->{url}
		) unless $rc == 0;
		return $self->get($path,$key);
	}

	bail(
		"Could not write to #C{%s} in vault at #M{%s}: set() takes key/value ".
		"pairs, but was given an odd number of arguments.",
		$path, $self->{url}
	) if @args % 2;

	my %pairs = @args;
	$self->_write_pairs($path, \%pairs);
	return @args == 2 ? $args[1] : \%pairs;
}

# }}}
# _write_pairs - write key/value pairs, in as few commands as safe allows {{{
sub _write_pairs {
	my ($self, $path, $pairs) = @_;

	my (@batch, %written);
	for my $key (sort CORE::keys %$pairs) {
		push(@batch, sprintf("%s=%s", $key, $pairs->{$key} // ''));
		next if length(join(' ', @batch)) <= 900;

		# The pair that crossed the line starts the next batch -- unless it
		# is alone, since there is no smaller write to fall back to.
		my @carry = (@batch > 1) ? (pop @batch) : ();
		$self->_write_batch($path, \@batch, \%written);
		@batch = @carry;
	}
	$self->_write_batch($path, \@batch, \%written) if @batch;
	return;
}

# }}}
# _write_batch - send one `safe set`, then confirm all of it is readable {{{
sub _write_batch {
	my ($self, $path, $batch, $written) = @_;
	return unless @$batch;

	my ($out,$rc) = $self->query('set', $path, @$batch);
	bail(
		"Could not write #C{%s} to vault at #M{%s}:\n%s",
		$path,$self->{url},$out
	) unless $rc == 0;

	# Confirm everything written so far, not just this batch: a batch that
	# merged into a stale base drops the earlier ones, not itself.
	for my $pair (@$batch) {
		my ($key, $value) = split /=/, $pair, 2;
		$written->{$key} = $value;
	}
	$self->_confirm_written($path, $written);
	return;
}

# }}}
# _confirm_timeout - how long a read-back may take before giving up {{{
sub _confirm_timeout {
	my $t = $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT};
	return $t if defined($t) && $t =~ /^\d+(?:\.\d+)?$/ && $t > 0;
	return 10;
}

# }}}
# _confirm_written - wait until a write reads back with the values sent {{{
sub _confirm_written {
	my ($self, $path, $written) = @_;
	return unless $self->needs_write_confirmation;

	# Values, not key names: a batch that merged into a stale base carries
	# the right names and the wrong contents.
	my $timeout = _confirm_timeout();
	my $deadline = gettimeofday() + $timeout;
	my @wrong;
	while (1) {
		my $have = $self->get($path);
		$have = {} unless ref($have) eq 'HASH';
		@wrong = grep {
			!defined($have->{$_}) || $have->{$_} ne $written->{$_}
		} CORE::keys %$written;
		last unless @wrong;
		last if gettimeofday() >= $deadline;
		select(undef, undef, undef, 0.25);
	}
	bail(
		"Wrote #C{%s} to the vault at #M{%s}, but %s of its %s keys did not ".
		"read back within %ss.\n\n".
		"A write merges into whatever a read returns, so continuing would ".
		"discard what has already been written.\n\n".
		"This usually means the vault target is a standby node whose reads ".
		"lag the leader; pointing it at the cluster leader avoids it.",
		$path, $self->{url}, scalar(@wrong),
		scalar(CORE::keys %$written), $timeout
	) if @wrong;
	return;
}

# }}}
# _confirm_cleared - wait until a cleared path reads back empty {{{
sub _confirm_cleared {
	my ($self, $path) = @_;
	return unless $self->needs_write_confirmation;

	# The write after a clear merges into what a read returns, so keys that
	# outlive the delete are carried straight into the new value.
	my $timeout = _confirm_timeout();
	my $deadline = gettimeofday() + $timeout;
	my @left;
	while (1) {
		my $have = $self->get($path);
		@left = ref($have) eq 'HASH' ? CORE::keys %$have : ();
		last unless @left;
		last if gettimeofday() >= $deadline;
		select(undef, undef, undef, 0.25);
	}
	bail(
		"Cleared #C{%s} in the vault at #M{%s}, but %s of its keys were still ".
		"readable after %ss.\n\n".
		"The write that follows a clear merges into what a read returns, so ".
		"continuing would carry those keys into the new value.\n\n".
		"This usually means the vault target is a standby node whose reads ".
		"lag the leader; pointing it at the cluster leader avoids it.",
		$path, $self->{url}, scalar(@left), $timeout
	) if @left;
	return;
}

# }}}
# clear - remove all keys under a given path {{{
sub clear {
	my ($self, $path, $recursive) = @_;
	my ($out,$rc,$err) = ('',0,'');
	if ($recursive) {
		debug("Clearing #C{%s} and all subpaths in vault at #M{%s}", $path, $self->{url});
		($out,$rc,$err) = $self->query('rm', '-rf', $path);
	} elsif (!$self->has($path)) {
		debug("Path #C{%s} does not exist in vault at #M{%s} - no need to clear", $path, $self->{url});
		# A stale read can call a path absent while its keys are still there
		# for the next write to merge into, so this is checked not trusted.
		$self->_confirm_cleared($path);
		return;
	} else {
		debug("Clearing #C{%s} in vault at #M{%s}", $path, $self->{url});
		($out,$rc,$err) = $self->query('rm', '-f', $path);
	}
	bail(
		"Could not clear #C{%s} in vault at #M{%s}:\n%s",
		$path,$self->{url},$out.$err
	) unless $rc == 0;
	$self->_confirm_cleared($path);
	return 1;
}

# }}}
# set_path - writes a set of key value pairs to the vault {{{
sub set_path {
	my ($self, $path, $data, %opts) = @_;

	my $flatten = $opts{flatten} // 0;
	my $clear = $opts{clear} // 0;
	if ($flatten) {
		$data = Genesis::flatten({},'',$data);
		$data->{__flattened__} = JSON::PP::true;
	}

	$self->clear($path, !$flatten) if ($clear);

	my %pairs;
	for my $key (sort keys %$data) {
		my $value = $data->{$key};

		# Skip empty containers from flatten() - vault cannot store refs
		if (ref($value) eq 'HASH') {
			next if keys %$value == 0;  # Skip empty hashes
			$self->set_path("$path/$key", $value);
			next;
		}

		if (ref($value) eq 'ARRAY') {
			next if @$value == 0;  # Skip empty arrays
			for my $i (0..$#{$value}) {
				if (ref($value->[$i]) eq 'HASH') {
					$self->set_path("$path/$key/$i", $value->[$i]);
				} else {
					$pairs{"${key}[${i}]"} = $value->[$i] // '';
				}
			}
			next;  # Don't fall through to scalar handling
		}

		$pairs{$key} = $value // '';
	}

	return $data unless %pairs;
	# Straight to the writer: these keys are already the ones to store, so
	# set()'s path:key splitting would only mangle one containing a colon.
	$self->_write_pairs($path, \%pairs);
	return $data;
}

# }}}
# has - return true if vault has given key {{{
sub has {
	my ($self, $path, $key) = @_;
	$path =~ s/\/{2,}/\//g; # Clean up any double slashes from joins
	return $self->query({ passfail => 1 }, 'exists', defined($key) ? "$path:$key" : $path);
}

# }}}
# paths - return all paths found under the given prefixes (or all if no prefix given) {{{
sub paths {
	my ($self, @prefixes) = @_;

	# TODO: Once safe stops returning invalid pathts, the following will work:
	# return lines($self->query('paths', @prefixes));
	# instead, we have to do this less efficient routine
	return lines($self->query('paths')) unless scalar(@prefixes);

	my @all_paths=();
	for my $prefix (@prefixes) {
		my @paths = lines($self->query('paths', $prefix));
		if (scalar(@paths) == 1 && $paths[0] eq $prefix) {
			next unless $self->has($prefix);
		}
		push(@all_paths, @paths);
	}
	return @all_paths;
}

# }}}
# keys - return all path:key pairs under the given prefixes (or all if no prefix given) {{{
sub keys {
	my ($self, @prefixes) = @_;
	return lines($self->query('paths','--keys')) unless scalar(@prefixes);

	my @all_paths=();
	for my $prefix (@prefixes) {
		my @paths = lines($self->query('paths', '--keys', $prefix));
		next if (scalar(@paths) == 1 && $paths[0] eq $prefix);
		push(@all_paths, @paths);
	}
	return @all_paths;
}

# }}}
# status - returns status of vault: sealed, unreachable, unauthenticated, uninitialized or ok {{{
sub status {
	my $self = shift;

	# See if the url is reachable to start with
	$self->url =~ qr(^http(s?)://(.*?)(?::([0-9]*))?$) or
		bail("Invalid vault target URL #C{%s}: expecting http(s)://ip-or-domain(:port)", $self->url);
	my $ip = $2;
	my $port = $3 || ($1 eq "s" ? 443 : 80);
	my $status = tcp_listening($ip,$port);
	return "unreachable - $status" unless $status eq 'ok';

	my ($out,$rc) = $self->query({stderr => "&1"}, "vault", "status");
	if ($rc != 0) {
		if ($out =~ /More than one target for Vault at '(.*)'/) {
			return "ambiguous - multiple targets for $1";
		}
		$out =~ /exit status ([0-9])/;
		return "sealed" if $1//0 == 2;
		return "unreachable";
	}

	return "unauthenticated" unless $self->authenticated;
	return "uninitialized" unless $self->initialized;
	return "ok"
}

# }}}
# max_json_string_value_length - return the per-string JSON value cap {{{
sub max_json_string_value_length {
	my ($self) = @_;

	return $self->{__max_json_string_value_length}
		if defined $self->{__max_json_string_value_length};

	if (defined($ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH})
		&& $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH} =~ /^\d+$/
		&& $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH} > 0)
	{
		return $self->{__max_json_string_value_length}
			= $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH} + 0;
	}

	# Try to consult the server's listener config.  `safe curl
	# --data-only` strips safe's own wrapping; Vault's response envelope
	# (request_id, data, ...) is preserved, so the actual content lives
	# at $decoded->{data}->...
	my ($out, $rc, $err) = $self->query(
		{redact_output => 1, stderr => 0},
		'curl', '--data-only', '/sys/config/state/sanitized'
	);
	if ($rc == 0 && defined($out) && length($out)) {
		my $decoded = eval { decode_json($out) };
		if ($decoded && ref($decoded) eq 'HASH') {
			my $listeners = $decoded->{data}{listeners};
			if (ref($listeners) eq 'ARRAY' && @$listeners) {
				my $max = $listeners->[0]{config}{max_json_string_value_length};
				if (defined($max) && $max =~ /^\d+$/ && $max > 0) {
					return $self->{__max_json_string_value_length} = $max + 0;
				}
			}
		}
	}

	# Vault's compiled-in default for max_json_string_value_length.
	return $self->{__max_json_string_value_length} = 1024 * 1024;
}

# }}}
# needs_write_confirmation - whether a write must be read back to be trusted {{{
sub needs_write_confirmation {
	my ($self) = @_;

	return $self->{__needs_write_confirmation}
		if defined $self->{__needs_write_confirmation};

	if (defined($ENV{GENESIS_VAULT_CONFIRM_WRITES})
		&& $ENV{GENESIS_VAULT_CONFIRM_WRITES} =~ /^[01]$/)
	{
		return $self->{__needs_write_confirmation}
			= $ENV{GENESIS_VAULT_CONFIRM_WRITES} + 0;
	}

	# ha_enabled decides it, never is_self: leadership fails over, and the
	# target is usually a load balancer fronting more than one node.
	my ($out, $rc, $err) = $self->query(
		{redact_output => 1, stderr => 0},
		'curl', '--data-only', '/sys/leader'
	);
	if ($rc == 0 && defined($out) && length($out)) {
		my $decoded = eval {decode_json($out)};
		if (ref($decoded) eq 'HASH') {
			# sys endpoints answer flat, but the response envelope survives
			# on some builds, so accept the key in either position.
			my $ha = $decoded->{ha_enabled};
			$ha = $decoded->{data}{ha_enabled}
				if !defined($ha) && ref($decoded->{data}) eq 'HASH';
			return $self->{__needs_write_confirmation} = ($ha ? 1 : 0)
				if defined($ha);
		}
	}

	# A confirm that was not needed costs one read.  Skipping one that was
	# needed loses data with no error, so an unusable answer confirms.
	return $self->{__needs_write_confirmation} = 1;
}

# }}}
# token_info - return the token information for the active user token {{{
sub token_info {
	my $self = shift;
	my ($out,$rc, $err) = $self->query('vault', 'token', 'lookup', '-format=json');
	return read_json_from($out) if $rc == 0;
	debug(
		"#R{[ERROR]} Could not get token information from vault at #M{%s}",
		$self->{url}
	);
	return {};
}

# }}}
# sub user - return the user information for the active user token {{{
sub user {
	my $self = shift;
	my $token_info = $self->token_info;
	return $token_info->{data}{meta}{username} || $token_info->{data}{display_name};
}

# env - return the environment variables needed to directly access the vault {{{
sub env {
	my $self = shift;
	unless (defined $self->{_env}) {
		$self->{_env} = read_json_from(
			run({
					stderr =>'/dev/null',
					env => {SAFE_TARGET => $self->ref }
				},'safe', 'env', '--json')
		);
		$self->{_env}{VAULT_SKIP_VERIFY} ||= "";
		# Explicitly override any existing SAFE_TARGET
		$self->{_env}{SAFE_TARGET} = $self->{_env}{VAULT_ADDR};
		# die on missing VAULT_ADDR env?
	}

	return $self->{_env};
}

# }}}
# token - the authentication token for the active vault {{{
sub token {
	my $self = shift;
	return $self->env->{VAULT_TOKEN};
}

# }}}
# ref - the reference to be used when identifying the vault (name or url) {{{
sub ref {
	my $self = shift;
	return $self->{$self->{ref_by} || 'url'};
}

# }}}
# ref_by_name - use the name of the vault as its reference (legacy mode) {{{
sub ref_by_name {
	$_[0]->{ref_by} = 'name';
	$_[0];
}
# }}}
# build_descriptor - builds a descriptor for the current vault {{{
sub build_descriptor {
	my ($self) = @_;
	my $descriptor = $self->url;
	$descriptor .= ("/".$self->namespace) if $self->namespace;
	$descriptor .= " as ".$self->name;
	$descriptor .= " no-verify" if $self->tls && !$self->verify;
	# Only an explicit disable earns a clause.  The parser reads no-strongbox
	# as a decision, and a target that never stated the flag has not made one.
	$descriptor .= " no-strongbox" if defined($self->strongbox) && !$self->strongbox;
	return $descriptor;
}

# }}}
# set_as_current - set this vault as the current Genesis vault {{{
sub set_as_current {
	$current_vault = shift;
}
sub is_current {
  $current_vault && $current_vault->{id} eq $_[0]->{id};
}

# }}}
# fetch_unseal_keys - fetch and store unseal keys for post-deploy unsealing {{{
sub fetch_unseal_keys {
	my ($self, $env) = @_;

	# Clear any previously stored keys
	my $secrets_mount = $env->secrets_mount;
	my $keys_path = "${secrets_mount}vault/seal/keys";
	$self->{unseal_keys} = [values(($self->get($keys_path)//{})->%*)];
	my $key_count = scalar(@{$self->{unseal_keys}});

	# Check if the keys path exists
	return (0, "Vault unseal keys not found at #C{$keys_path}")
		unless ($key_count);

	return (0, "Insufficient unseal keys found at #C{$keys_path}: Need at least 3, found $key_count")
		unless $key_count >= 3;

	return (1, sprintf("Successfully fetched vault unseal keys from #C{%s}", $keys_path));
}

# }}}
# unseal - unseal the vault using stored unseal keys {{{
sub unseal {
	my $self = shift;

	# Check if we have stored unseal keys
	unless ($self->{unseal_keys} && @{$self->{unseal_keys}}) {
		return ("No unseal keys available", 1, "fetch_unseal_keys() must be called first");
	}

	# Check if we have at least 3 keys (required by safe unseal)
	unless (@{$self->{unseal_keys}} >= 3) {
		return ("Insufficient unseal keys available", 1, sprintf("safe unseal requires 3 keys, but only %d available", scalar(@{$self->{unseal_keys}})));
	}

	# Use safe unseal which unseals all vault instances in the cluster
	# safe unseal expects exactly 3 keys, so take the first 3
	my @keys_to_use = @{$self->{unseal_keys}}[0..2];
	my $keys_input = join("\n", @keys_to_use) . "\n";

	# Use the stdin option with query to pass keys to safe unseal
	my ($out, $rc);
	my ($tries, $max_tries) = (0, 3);
	while ($tries++ < $max_tries) {
		($out, $rc) = $self->query({stdin => $keys_input, redact_stdin => 1}, 'unseal');
		return ($out, 0, '') if ($rc == 0) || ($out =~ /Vault is already unsealed/);

		# RISK: If the unseal fails, we log all available keys for recovery purposes
		# This is a security risk, as it exposes the unseal keys in logs, but is
		# necessary to prevent irrevocable sealing of the vault.
		trace(
			"[Attempt %s] Failed to unseal vault cluster at #M{%s} - all available keys (first three used):\n%s",
			$tries, $self->{url}, join("\n", map {sprintf("#C{%s}", $_)} @{$self->{unseal_keys}})
		);
		sleep(2); # brief pause before retrying
	}
	# If we reach here, all attempts failed
	return ('', $rc // 1, $out || "Failed to unseal vault cluster");
}

# }}}
# }}}

### Private helper functions {{{

# _target_is_url - determine if target is in valid URL form {{{
sub _target_is_url {
	my $target = lc(shift);
	return 0 unless $target =~ qr(^https?://([^:/]+)(?::([0-9]+))?$);
	return 0 if $2 && $2 > 65535;
	my @comp = split(/\./, $1);
	return 1 if scalar(@comp) == 4 && scalar(grep {$_ =~ /^[0-9]+$/ && $_ >=0 && $_ < 256} @comp) == 4;
	return 1 if scalar(grep {$_ !~ /[a-z0-9]([-_0-9a-z]*[a-z0-9])*/} @comp) == 0;
	return 0;
}

# }}}
# _get_targets - find all matching safe targets for the provided name or url {{{
sub _get_targets {
	my $target = shift;
	unless (_target_is_url($target)) {
		my $target_vault = (Service::Vault->find(name => $target, @_))[0];
		return (undef) unless $target_vault;
		$target = $target_vault->{url};
	}
	my @names = map {$_->{name}} Service::Vault->find(url => $target, @_);
	return ($target, @names);
}
# }}}
# }}}
# }}}
1;
# vim: fdm=marker:foldlevel=1:noet
