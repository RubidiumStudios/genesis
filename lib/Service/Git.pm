package Service::Git;

use strict;
use warnings;

use Genesis qw/run bail debug trace/;
use File::Basename qw/dirname/;

### Class State {{{
my %_instances;  # keyed by resolved git root path
# }}}

### Constructor & Lifecycle {{{

# new - get or create a Git service instance for a repository {{{
#
# Flyweight: returns the existing instance if one already exists for
# the same .git-controlled repo.  This prevents competing objects
# from stepping on each other's branch tracking or caches.
#
#   my $git = Service::Git->new($path);   # or ->new() for cwd
#   my $git = Service::Git->new($path, track_branch => 1);
#
# With track_branch => 1, the current branch is saved and restored
# when the object goes out of scope (DESTROY).  If the instance
# already exists and track_branch is requested, it upgrades the
# existing instance.
sub new {
	my ($class, $path, %opts) = @_;
	$path ||= '.';

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
#
#   my $git = Service::Git->create($path);
#   my $git = Service::Git->create($path, initial_branch => 'control');
#
# Runs git init at the given path, optionally setting the initial
# branch name.  Returns a Service::Git instance for the new repo.
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
#
# Wraps `git status --porcelain` and parses each line into the
# two-character status code and the path.  Optional pathspec args
# limit the report to those paths (relative to git root).  Includes
# untracked files (`??`) -- callers can filter if they only want
# tracked-file changes.
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
#
# Returns a hashref:
#   {
#     changed => \@files,     # added, modified, or type-changed
#     deleted => \@files,
#     renamed => \%old_to_new,
#     all     => \@all_files, # union of changed + deleted
#   }
#
# Pathspecs are relative to git root (caller should prefix if needed).
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
#
# Builds all refspecs and runs a single git fetch, so credentials are
# only prompted once regardless of how many branches are listed.
# Silently skips the currently checked-out branch (git refuses to
# update an active branch via refspec fetch); call pull_ff_only for
# that one separately.  Returns $self.
sub fetch_branches {
	my ($self, $remote, @branches) = @_;
	$remote //= $self->default_remote;
	return $self unless $remote && @branches;
	my $current  = $self->current_branch // '';
	my @refspecs = map { "+refs/heads/$_:refs/heads/$_" }
	               grep { $_ ne $current } @branches;
	return $self unless @refspecs;
	run({ dir => $self->{root}, passfail => 1 },
		'git', 'fetch', $remote, @refspecs);
	$self->{_branch_cache}{$_} = 1 for grep { $_ ne $current } @branches;
	return $self;
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
#
# Inverse of `prefixed`.  Converts git-root-relative paths into
# Top-root-relative paths for user-facing display.  Paths that don't
# start with the prefix are left untouched (so sibling-dir paths
# outside the deployment Top root remain identifiable).
#
#   my @user_paths = $git->unprefixed(@git_paths);
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
