package Service::Git;

use strict;
use warnings;

use Genesis qw/run bail debug trace/;
use Genesis::Term qw/in_controlling_terminal/;
use File::Basename qw/dirname/;

### Class State {{{
my %_instances;  # keyed by resolved git root path
my $_ci_credentials_dir;  # temp dir holding materialised CI credentials
# }}}

### CI Credentials {{{

# provision_ci_credentials - make environment-supplied git creds usable {{{
#
# A CI task receives git credentials as environment variables, which git
# itself cannot consume: a key has to exist as a file with the right mode,
# and a password has to be answerable at prompt time.  Materialise both
# into a private temp directory and point git at them.
#
# Deliberately does not move HOME.  The retired ci-* task commands did,
# because they owned the whole process; here the same process also
# resolves ~/.saferc and ~/.genesis, so relocating HOME would break vault
# and repository configuration.  Everything below is therefore expressed
# through git's own environment variables, touching neither HOME nor the
# repository's config.
sub provision_ci_credentials {
	return if $_ci_credentials_dir;

	# Author identity is supplied without a committer identity, and git
	# needs both.  A CI container rarely has user.name/user.email set, so
	# without this every commit fails with "Please tell me who you are".
	$ENV{GIT_COMMITTER_NAME}  //= $ENV{GIT_AUTHOR_NAME}  if $ENV{GIT_AUTHOR_NAME};
	$ENV{GIT_COMMITTER_EMAIL} //= $ENV{GIT_AUTHOR_EMAIL} if $ENV{GIT_AUTHOR_EMAIL};

	# Everything below assumes a remote reached over ssh or https with
	# credentials handed in through the environment -- which is a CI task,
	# and nothing else.  A repository with no remote, or one whose operator
	# authenticates through a credential helper or an agent, must be left
	# exactly as configured: suppressing prompts there would turn a
	# workflow that asks for a password into one that simply fails.
	return unless $ENV{GIT_PRIVATE_KEY} || $ENV{GIT_USERNAME};

	# Having established we are answering prompts ourselves, refuse to
	# block on one we cannot answer.  A CI task has no terminal, so an
	# interactive prompt hangs indefinitely rather than failing visibly.
	$ENV{GIT_TERMINAL_PROMPT} //= '0';
	$ENV{GIT_ASKPASS}         //= '/bin/false';

	require File::Temp;
	my $dir = File::Temp->newdir('genesis-git-creds.XXXXXX', TMPDIR => 1);
	chmod 0700, "$dir";

	_provision_ssh_key("$dir")  if $ENV{GIT_PRIVATE_KEY};
	_provision_askpass("$dir")  if $ENV{GIT_USERNAME};

	# Hold the object, not the path: File::Temp removes the directory when
	# the last reference goes away, and these files must outlive this sub.
	$_ci_credentials_dir = $dir;
	trace("Service::Git: provisioned CI credentials in %s", "$dir");
	return;
}

# }}}
# reset_ci_credentials - discard provisioned credentials (testing) {{{
sub reset_ci_credentials {
	$_ci_credentials_dir = undef;
	return;
}

# }}}
# _provision_ssh_key - write the key and an ssh config that selects it {{{
sub _provision_ssh_key {
	my ($dir) = @_;

	my $key = "$dir/key";
	open my $fh, '>', $key or bail("Cannot write git ssh key: %s", $!);
	print $fh $ENV{GIT_PRIVATE_KEY};
	close $fh;
	chmod 0600, $key;

	# Host key checking is disabled because a CI worker is ephemeral and
	# has no known_hosts to check against; the key itself is the
	# authentication.
	my $config = "$dir/ssh_config";
	open my $cfh, '>', $config or bail("Cannot write git ssh config: %s", $!);
	print $cfh <<EOF;
Host *
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel QUIET
  IdentityFile $key
  IdentitiesOnly yes
EOF
	close $cfh;

	$ENV{GIT_SSH_COMMAND} = "ssh -F $config";
	return;
}

# }}}
# _provision_askpass - answer git's credential prompts from the env {{{
sub _provision_askpass {
	my ($dir) = @_;

	# git passes the prompt text as the sole argument, and reads one line
	# of stdout.  The script reads the values from the environment rather
	# than having them written into it, so a password containing shell
	# metacharacters cannot be mangled or leak via the file.
	my $script = "$dir/askpass";
	open my $fh, '>', $script or bail("Cannot write git askpass helper: %s", $!);
	print $fh <<'EOF';
#!/bin/sh
case "$1" in
  Username*|username*) printf '%s\n' "$GIT_USERNAME" ;;
  *)                   printf '%s\n' "$GIT_PASSWORD" ;;
esac
EOF
	close $fh;
	chmod 0700, $script;

	$ENV{GIT_ASKPASS} = $script;
	return;
}

# }}}
# }}}

### Constructor & Lifecycle {{{

# new - get or create a Git service instance for a repository {{{
sub new {
	my ($class, $path, %opts) = @_;
	$path ||= '.';

	# Before any remote operation can work under CI.  A no-op when the
	# environment carries no credentials, which is every local run.
	provision_ci_credentials();

	my ($root) = run({}, 'git', '-C', $path, 'rev-parse', '--show-toplevel');
	chomp $root if defined $root;
	bail("Not a git repository: %s", $path) unless $root;

	# Return existing instance for this repo
	if (my $existing = $_instances{$root}) {
		# Upgrade to track_branch if requested and not already tracking
		if ($opts{track_branch} && !$existing->{_track_branch}) {
			$existing->{_track_branch} = 1;
			$existing->{_original_branch} //= $existing->current_branch;
		}
		return $existing;
	}

	my ($prefix) = run({}, 'git', '-C', $path, 'rev-parse', '--show-prefix');
	chomp $prefix if defined $prefix;
	$prefix //= '';

	my $self = bless {
		root           => $root,
		prefix         => $prefix,
		_branch_cache  => {},
		_track_branch  => $opts{track_branch} || 0,
		_original_branch => undef,
	}, $class;

	if ($self->{_track_branch}) {
		$self->{_original_branch} = $self->current_branch;
	}

	$_instances{$root} = $self;
	return $self;
}

# }}}
# create - initialize a new git repository and return an instance {{{
sub create {
	my ($class, $path, %opts) = @_;
	$path ||= '.';

	my @init = ('git', 'init');
	if ($opts{initial_branch}) {
		# git symbolic-ref works on all versions (git init -b requires >= 2.28)
		run({ onfailure => "Failed to initialize git in $path" },
			"cd \Q$path\E && git init && git symbolic-ref HEAD refs/heads/$opts{initial_branch}");
	} else {
		run({ onfailure => "Failed to initialize git in $path" },
			'git', '-C', $path, 'init');
	}

	return $class->new($path, %opts);
}

# }}}
# DESTROY - restore original branch on process exit {{{
#
# With flyweight caching, the instance lives for the process lifetime.
# DESTROY fires during global cleanup, restoring the branch if needed.
sub DESTROY {
	my ($self) = @_;
	return unless $self->{_track_branch} && $self->{_original_branch};
	my $current = eval { $self->current_branch };
	return unless $current && $current ne $self->{_original_branch};
	# Reset any partial changes before switching
	run({ dir => $self->{root}, passfail => 1 },
		'git', 'checkout', '--', '.');
	run({ dir => $self->{root}, passfail => 1 },
		'git', 'checkout', $self->{_original_branch});
	trace("Service::Git: restored branch %s", $self->{_original_branch});
	delete $_instances{$self->{root}};
}

# }}}
# }}}

### Accessors {{{

# root - git toplevel directory (cached) {{{
sub root { $_[0]->{root} }

# }}}
# prefix - subdir offset within git repo (cached, e.g., "bosh/") {{{
sub prefix { $_[0]->{prefix} }

# }}}
# }}}

### Branch Operations {{{

# current_branch - name of HEAD branch (cached, invalidated on checkout) {{{
sub current_branch {
	my ($self) = @_;
	my ($branch) = run({ dir => $self->{root} },
		'git', 'rev-parse', '--abbrev-ref', 'HEAD');
	chomp $branch if defined $branch;
	$self->{_current_branch} = $branch;
	return $branch;
}

# }}}
# checkout - switch to a branch {{{
#
# Saves the original branch for restore_branch / DESTROY.
sub checkout {
	my ($self, $branch) = @_;
	$self->{_original_branch} //= $self->current_branch
		if $self->{_track_branch};
	run({ dir => $self->{root}, onfailure => "Failed to checkout '$branch'" },
		'git', 'checkout', $branch);
	delete $self->{_current_branch};
	return $self;
}

# }}}
# restore_branch - return to the branch we were on before any checkout {{{
sub restore_branch {
	my ($self) = @_;
	return unless $self->{_original_branch};
	my $current = $self->current_branch;
	if ($current ne $self->{_original_branch}) {
		run({ dir => $self->{root}, passfail => 1 },
			'git', 'checkout', $self->{_original_branch});
		delete $self->{_current_branch};
	}
	return $self;
}

# }}}
# create_branch - create a new branch at the given ref (default HEAD) {{{
sub create_branch {
	my ($self, $name, $ref) = @_;
	my @cmd = ('git', 'branch', $name);
	push @cmd, $ref if $ref;
	run({ dir => $self->{root}, onfailure => "Failed to create branch '$name'" },
		@cmd);
	$self->{_branch_cache}{$name} = 1;
	return $self;
}

# }}}
# branch_exists - check if a branch exists (cached) {{{
sub branch_exists {
	my ($self, $name) = @_;
	return $self->{_branch_cache}{$name}
		if exists $self->{_branch_cache}{$name};
	my $exists = run({ dir => $self->{root}, passfail => 1 },
		'git', 'rev-parse', '--verify', $name);
	$self->{_branch_cache}{$name} = $exists ? 1 : 0;
	return $self->{_branch_cache}{$name};
}

# }}}
# }}}

### Queries {{{

# sha - return the commit SHA for a ref {{{
#
#   $git->sha('HEAD')                  # full SHA
#   $git->sha('HEAD', short => 1)      # abbreviated
#   $git->sha($branch)                 # resolve branch to SHA
#   $git->sha($short_sha)             # expand short to full
sub sha {
	my ($self, $ref, %opts) = @_;
	return $self->rev_parse($ref // 'HEAD', %opts);
}

# }}}
# rev_parse - resolve a ref via git rev-parse (low-level) {{{
#
# Options:
#   short => 1   — return abbreviated SHA
sub rev_parse {
	my ($self, $ref, %opts) = @_;
	my @cmd = ('git', 'rev-parse');
	push @cmd, '--short' if $opts{short};
	push @cmd, $ref;
	my ($sha) = run({ dir => $self->{root} }, @cmd);
	chomp $sha if defined $sha;
	return $sha;
}

# }}}
# merge_base - find the common ancestor of two refs {{{
sub merge_base {
	my ($self, $a, $b) = @_;
	my ($sha) = run({ dir => $self->{root} }, 'git', 'merge-base', $a, $b);
	chomp $sha if defined $sha;
	return $sha;
}

# }}}
# is_ancestor - true if $maybe_ancestor is an ancestor of (or equal to) $descendant {{{
#
#   $git->is_ancestor($a, $b)  # true if A == B, or A is reachable from B
sub is_ancestor {
	my ($self, $maybe_ancestor, $descendant) = @_;
	return 0 unless defined $maybe_ancestor && defined $descendant;
	my $ok = run(
		{ dir => $self->{root}, passfail => 1 },
		'git', 'merge-base', '--is-ancestor', $maybe_ancestor, $descendant
	);
	return $ok ? 1 : 0;
}

# }}}
# is_clean - true if working tree has no modified/staged/conflicted files {{{
#
# Ignores untracked files — they don't affect branch switching.
sub is_clean {
	my ($self) = @_;
	my ($status) = run({ dir => $self->{root} }, 'git', 'status', '--porcelain');
	my @dirty = grep { /^[^?]/ } split /\n/, ($status || '');
	return !@dirty;
}

# }}}
# status - working-tree state as a {path => XY-code} hashref {{{
sub status {
	my ($self, @pathspecs) = @_;
	my @cmd = ('git', 'status', '--porcelain');
	push @cmd, '--', @pathspecs if @pathspecs;
	my ($out) = run({ dir => $self->{root} }, @cmd);
	my %unclean;
	for my $line (split /\n/, ($out // '')) {
		next unless length $line;
		# Format: "XY path" — two-char status, single space, path.
		my $code = substr($line, 0, 2);
		my $path = substr($line, 3);
		$unclean{$path} = $code if length $path;
	}
	return \%unclean;
}

# }}}
# pull_ff_only - fast-forward a branch from a remote, bail on divergence {{{
#
# Defaults to `default_remote` when no remote is given.  No-op when
# no remote is configured.  Bails (via run's onfailure) when the
# pull would require a non-fast-forward.
sub pull_ff_only {
	my ($self, $branch, $remote) = @_;
	$remote //= $self->default_remote;
	return $self unless $remote;
	run({ dir => $self->{root},
		  onfailure => "Failed to fast-forward $branch from $remote -- ".
		               "resolve the divergence and retry" },
		'git', 'pull', '--ff-only', $remote, $branch);
	delete $self->{_branch_cache}{$branch};
	return $self;
}

# }}}
# pull_rebase - rebase the current branch on top of remote/<branch> {{{
#
# Used to integrate concurrent updates before a push.  Defaults to
# `default_remote` when no remote is given.  No-op when no remote
# is configured.  Bails (via run's onfailure) when rebase fails.
sub pull_rebase {
	my ($self, $branch, $remote) = @_;
	$remote //= $self->default_remote;
	return $self unless $remote;
	run({ dir => $self->{root},
		  onfailure => "Failed to rebase $branch on $remote/$branch -- ".
		               "resolve the divergence and push manually" },
		'git', 'pull', '--rebase', $remote, $branch);
	return $self;
}

# }}}
# diff_files - structured diff between two refs, filtered by pathspecs {{{
sub diff_files {
	my ($self, $from, $to, @pathspecs) = @_;
	my @cmd = ('git', 'diff', '--name-status', $from, $to);
	push @cmd, '--', @pathspecs if @pathspecs;
	my ($out) = run({ dir => $self->{root} }, @cmd);

	my (@changed, @deleted, %renamed);
	for my $line (grep { /\S/ } split /\n/, ($out || '')) {
		if ($line =~ /^D\t(.+)$/) {
			push @deleted, $1;
		} elsif ($line =~ /^R\d*\t(.+)\t(.+)$/) {
			$renamed{$1} = $2;
			push @deleted, $1;
			push @changed, $2;
		} elsif ($line =~ /^[AMT]\t(.+)$/) {
			push @changed, $1;
		}
	}
	return {
		changed => \@changed,
		deleted => \@deleted,
		renamed => \%renamed,
		all     => [@changed, @deleted],
	};
}

# }}}
# diff_names - simple list of changed file names between two refs {{{
sub diff_names {
	my ($self, $from, $to, @pathspecs) = @_;
	my @cmd = ('git', 'diff', '--name-only', $from, $to);
	push @cmd, '--', @pathspecs if @pathspecs;
	my ($out) = run({ dir => $self->{root} }, @cmd);
	return grep { /\S/ } split /\n/, ($out || '');
}

# }}}
# ls_tree - list files on a ref under a prefix {{{
sub ls_tree {
	my ($self, $ref, $path) = @_;
	$path //= '';
	my ($out) = run({ dir => $self->{root} },
		'git', 'ls-tree', '-r', '--name-only', $ref, $path);
	return grep { /\S/ } split /\n/, ($out || '');
}

# }}}
# log_subjects - return commit subjects for a branch {{{
#
# Options:
#   limit  => N       — max number of entries
#   format => '...'   — custom format (default: %H %s)
sub log_subjects {
	my ($self, $branch, %opts) = @_;
	my $fmt = $opts{format} || '%H %s';
	my @cmd = ('git', 'log', "--format=$fmt", $branch);
	push @cmd, "-$opts{limit}" if $opts{limit};
	# Optional pathspec filter: only commits that touched any of these
	# git-root-relative paths.  Used to scope the env-branch history to
	# what's relevant to a particular deployment (e.g., bosh vs vault in
	# a multi-deploy repo).
	if ($opts{paths} && @{$opts{paths}}) {
		push @cmd, '--', @{$opts{paths}};
	}
	my ($out) = run({ dir => $self->{root} }, @cmd);
	return split /\n/, ($out || '');
}

# }}}
# show_file - read file content from a specific ref {{{
sub show_file {
	my ($self, $ref, $path) = @_;
	my ($content, $rc) = run({ dir => $self->{root}, passfail => 0 },
		'git', 'show', "$ref:$path");
	return $content;
}

# }}}
# }}}

### Working Tree Operations {{{

# checkout_file - extract a file from a ref into the working tree {{{
sub checkout_file {
	my ($self, $ref, $file) = @_;
	# Ensure parent directory exists
	my $full_path = "$self->{root}/$file";
	my $dir = dirname($full_path);
	if (!-d $dir) {
		require File::Path;
		File::Path::make_path($dir);
	}
	run({ dir => $self->{root}, onfailure => "Failed to checkout $file from $ref" },
		'git', 'checkout', $ref, '--', $file);
	return $self;
}

# }}}
# add - stage files {{{
sub add {
	my ($self, @files) = @_;
	return unless @files;
	run({ dir => $self->{root} }, 'git', 'add', @files);
	return $self;
}

# }}}
# rm - remove files from index and working tree {{{
sub rm {
	my ($self, @files) = @_;
	return unless @files;
	run({ dir => $self->{root}, passfail => 1 },
		'git', 'rm', '-f', '-q', '--', @files);
	return $self;
}

# }}}
# commit - stage files and commit {{{
#
#   $git->commit("message");              # commit staged changes
#   $git->commit("message", @files);      # add files then commit
sub commit {
	my ($self, $message, @files) = @_;
	$self->add(@files) if @files;
	run({ dir => $self->{root}, onfailure => "Failed to commit" },
		'git', 'commit', '-m', $message);
	return $self;
}

# }}}
# cherry_pick - apply the given commit by sha onto the current branch {{{
sub cherry_pick {
	my ($self, $sha) = @_;
	my ($out, $rc, $err) = run({ dir => $self->{root}, passfail => 0 },
		'git', 'cherry-pick', $sha);
	return $self unless $rc;

	# Conflict: collect the conflicting paths from `git cherry-pick`'s
	# stdout/stderr ("CONFLICT (content): Merge conflict in <path>"),
	# abort the in-progress cherry-pick, then bail.
	my @conflicts = ($out =~ /Merge conflict in (.+?)(?:\r?\n|$)/g);
	if (@conflicts) {
		run({ dir => $self->{root}, passfail => 1 },
			'git', 'cherry-pick', '--abort');
		bail(
			"cherry-pick of #C{%s} produced conflict(s):\n  - %s\n",
			$sha, join("\n  - ", @conflicts)
		);
	}

	# Non-conflict failure: surface whatever git said.
	bail("cherry-pick of #C{%s} failed: %s",
		$sha, ($err || $out || "rc=$rc") =~ s/\s+$//r);
}
# }}}
# reset_working_tree - discard all working tree changes to tracked files {{{
sub reset_working_tree {
	my ($self) = @_;
	run({ dir => $self->{root}, passfail => 1 },
		'git', 'checkout', '--', '.');
	return $self;
}

# }}}
# }}}

### Remote Operations {{{

# default_remote - first configured remote name (cached) {{{
sub default_remote {
	my ($self) = @_;
	return $self->{_default_remote} if exists $self->{_default_remote};
	my ($out) = run({ dir => $self->{root} }, 'git', 'remote');
	if ($out && $out =~ /\S/) {
		chomp $out;
		$self->{_default_remote} = (split /\n/, $out)[0];
	} else {
		$self->{_default_remote} = undef;
	}
	return $self->{_default_remote};
}

# }}}
# remote_url - fetch the fetch URL for a named (or default) remote {{{
sub remote_url {
	my ($self, $remote) = @_;
	$remote //= $self->default_remote;
	return undef unless $remote;
	my ($url) = run({ dir => $self->{root} }, 'git', 'remote', 'get-url', $remote);
	chomp $url if defined $url;
	return $url;
}

# }}}
# remote_branch_exists - check whether a branch exists on the remote {{{
sub remote_branch_exists {
	my ($self, $branch, $remote) = @_;
	$remote //= $self->default_remote;
	return 0 unless $remote;
	my ($out, $rc, $err) = run({ dir => $self->{root}, passfail => 0 },
		'git', 'ls-remote', '--heads', $remote, $branch);
	bail("ls-remote against #C{%s} failed: %s",
		$remote, ($err || $out || "rc=$rc") =~ s/\s+$//r) if $rc;
	return ($out && $out =~ /\S/) ? 1 : 0;
}

# }}}
# delete_remote_branch - delete a branch on the remote {{{
#
# Uses `git push <remote> --delete <branch>`.  Returns $self on
# success or when no remote is configured (no-op).  Bails on push
# failure with the underlying git error.
sub delete_remote_branch {
	my ($self, $branch, $remote) = @_;
	$remote //= $self->default_remote;
	return $self unless $remote;
	my ($out, $rc, $err) = run({ dir => $self->{root}, passfail => 0 },
		'git', 'push', $remote, '--delete', $branch);
	bail("Failed to delete remote branch #C{%s} on #C{%s}: %s",
		$branch, $remote, ($err || $out || "rc=$rc") =~ s/\s+$//r) if $rc;
	return $self;
}

# }}}
# fetch_branch - fetch a specific branch from remote into a local ref {{{
#
# Uses the forced refspec (+refs/heads/branch:refs/heads/branch) so the
# local ref is created or updated regardless of fast-forward status.
# Safe for propagation branches that are written-once and never rebased.
sub fetch_branch {
	my ($self, $branch, $remote) = @_;
	$remote //= $self->default_remote;
	return $self unless $remote;
	run({ dir => $self->{root}, onfailure => "Failed to fetch '$branch' from '$remote'" },
		'git', 'fetch', $remote,
		"+refs/heads/$branch:refs/heads/$branch");
	$self->{_branch_cache}{$branch} = 1;
	return $self;
}

# }}}
# fetch_branches - fetch multiple branches from remote in one call {{{
sub fetch_branches {
	my ($self, $names, $remote) = @_;
	$remote //= $self->default_remote;
	my $noop = { ok => 1, kind => 'success', fetched => [], absent => [] };
	return wantarray ? ($self, $noop) : $self
		unless $remote && $names && @$names;
	my $current = $self->current_branch // '';
	my @want    = grep { $_ ne $current } @$names;
	return wantarray ? ($self, $noop) : $self unless @want;

	my %env;
	$env{GIT_TERMINAL_PROMPT} = '0' unless in_controlling_terminal();
	my %opts = (dir => $self->{root}, (%env ? (env => \%env) : ()));

	# Ask the remote what it has before fetching.  A refspec naming a
	# branch the remote lacks aborts the entire fetch, so one absent env
	# branch would leave every other branch unrefreshed.  Patterns are
	# fully qualified because ls-remote matches the tail of a ref: a bare
	# "qa" would also match refs/heads/team/qa.
	my ($out, $rc, $err) = run({%opts},
		'git', 'ls-remote', '--heads', $remote,
		map { "refs/heads/$_" } @want);
	return wantarray
		? ($self, { ok => 0, kind => _classify_remote_error($err), err => $err // '',
		            fetched => [], absent => [] })
		: $self
		if $rc;

	my %on_remote;
	for my $line (split /\n/, ($out // '')) {
		$on_remote{$1} = 1 if $line =~ m{\srefs/heads/(\S+)\s*$};
	}
	my @present = grep {  $on_remote{$_} } @want;
	my @absent  = grep { !$on_remote{$_} } @want;

	if (@present) {
		my ($fout, $frc, $ferr) = run({%opts}, 'git', 'fetch', $remote,
			map { "+refs/heads/$_:refs/heads/$_" } @present);
		return wantarray
			? ($self, { ok => 0, kind => _classify_remote_error($ferr), err => $ferr // '',
			            fetched => [], absent => \@absent })
			: $self
			if $frc;

		# Only branches actually fetched are known to exist.  Absent on
		# the remote says nothing about local state -- pipeline-prepare
		# creates env branches before anything pushes them -- so leave
		# those cache entries for branch_exists to resolve locally.
		$self->{_branch_cache}{$_} = 1 for @present;
	}

	return wantarray
		? ($self, { ok => 1, kind => 'success', fetched => \@present, absent => \@absent })
		: $self;
}

# }}}
# _classify_remote_error - bucket a git transport error for the caller {{{
sub _classify_remote_error {
	my ($err) = @_;
	my $emsg = $err // '';
	return 'network'
		if $emsg =~ /could not resolve host|network is unreachable|operation timed out|connection refused/i;
	return 'auth'
		if $emsg =~ /authentication failed|permission denied|terminal prompts disabled|could not read username|could not read password/i;
	return 'unknown';
}

# }}}
# push - push branches to a remote {{{
#
#   $git->push(@branches);              # push to default remote
#   $git->push($remote, @branches);     # push to specific remote
#
# Returns a hashref of branch => success (1/0).
sub push {
	my ($self, @args) = @_;
	# If first arg looks like a remote name (not a branch we know), use it
	my $remote;
	if (@args && !$self->branch_exists($args[0])) {
		$remote = shift @args;
	}
	$remote ||= $self->default_remote;
	return {} unless $remote;

	my %results;
	for my $branch (@args) {
		my $ok = run({ dir => $self->{root}, passfail => 1 },
			'git', 'push', $remote, $branch);
		$results{$branch} = $ok ? 1 : 0;
	}
	return \%results;
}

# }}}
# }}}

### Utility {{{

# prefixed - prepend the git prefix to repo-relative paths {{{
#
# Converts paths relative to the deployment repo root into paths
# relative to the git root.  No-op when prefix is empty.
#
#   my @git_paths = $git->prefixed(@repo_paths);
sub prefixed {
	my ($self, @paths) = @_;
	my $p = $self->{prefix};
	return @paths unless $p;
	return map { "${p}$_" } @paths;
}

# }}}
# unprefixed - strip the git prefix from git-root-relative paths {{{
sub unprefixed {
	my ($self, @paths) = @_;
	my $p = $self->{prefix};
	return @paths unless $p;
	return map { my $q = $_; $q =~ s{^\Q$p\E}{}; $q } @paths;
}

# }}}
# in_repo - true if we're inside a subdirectory of the git root {{{
sub in_repo {
	return defined $_[0]->{root};
}

# }}}
# is_inside_work_tree - check if a path is inside a git work tree {{{
sub is_inside_work_tree {
	my ($class, $path) = @_;
	$path ||= '.';
	return run({ passfail => 1 },
		'git', '-C', $path, 'rev-parse', '--is-inside-work-tree');
}

# }}}
# }}}

1;
