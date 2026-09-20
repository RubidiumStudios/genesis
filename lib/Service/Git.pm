package Service::Git;

use strict;
use warnings;

use Genesis qw/run bail bug debug trace tmpfile mkfile_or_fail/;
use Genesis::Exit qw/CONFIG DATAERR SOFTWARE/;
use Genesis::Term qw/in_controlling_terminal/;
use File::Basename qw/dirname/;
use Cwd qw/abs_path getcwd/;

# The all-zero object name, which git reads as a ref that is not there.  A
# lease taken against it asks the remote for a branch it has not got yet.
use constant NULL_SHA => '0' x 40;

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
	# credentials handed in through the environment, which is a compiled
	# pipeline task and nothing else.  An operator at a terminal, whose
	# repository may have no remote at all and who may authenticate through
	# a credential helper or an agent, must be left exactly as configured,
	# because suppressing prompts there would turn a workflow that asks for
	# a password into one that simply fails.
	#
	# GENESIS_PIPELINE_TASK is what says a pipeline is running.  Genesis
	# owns that name, sets it on the deploy task it compiles, and reads it
	# for this same question at the pre-flight gates.  The credential
	# variables below cannot answer it, because neither is namespaced to
	# Genesis and an operator may export either one for another tool.
	# Reading one of them here would take host key verification away from
	# every git operation Genesis makes on that operator's machine.
	return unless $ENV{GENESIS_PIPELINE_TASK};
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

# _refuse_dubious_ownership - the one safe.directory refusal {{{
#
# A working tree git will not touch is refused while the handle is being
# built as readily as at the pre-flight, because the very first question the
# constructor asks git is one it declines to answer.  H20 is that the
# operator meets the condition late and generically, so both callers raise
# this one refusal and the message, the fix it names, and the code it exits
# with are written once.
#
# Silent unless git's own words name the condition, so a caller hands over
# whatever git said and carries on with its own classification when this
# returns.
sub _refuse_dubious_ownership {
	my ($said, $path) = @_;
	return unless defined($said) && $said =~ /dubious ownership|safe\.directory/i;

	bail({exitcode => CONFIG},
		"Git refuses to work in #C{%s} because it is owned by another user.\n\n".
		"    git config --global --add safe.directory %s\n\n".
		"Run that, then run this command again.",
		$path, $path);
}

# }}}
# new - get or create a Git service instance for a repository {{{
#
# One handle per repository root, and no branch tracking of any kind.  The
# session records its own origin at begin, so the first caller to ask can no
# longer stamp the branch it happened to be on onto the handle that every
# other caller shares, which is H16.
sub new {
	my ($class, $path, %opts) = @_;
	$path ||= '.';

	# Before any remote operation can work under CI.  A no-op when the
	# environment carries no credentials, which is every local run.
	provision_ci_credentials();

	my ($root, $rc, $err) = run({}, 'git', '-C', $path, 'rev-parse', '--show-toplevel');
	chomp $root if defined $root;

	# git answers a failure with its complaint rather than with nothing, and
	# a complaint is as true as a path, so the return code is what says
	# whether there is a root here at all.  A refusal over ownership is named
	# for what it is before the generic message gets a chance at it.
	if ($rc || !defined($root) || $root !~ /\S/) {
		# Named as git resolves it, which is the spelling the pre-flight
		# names and the one git compares a safe.directory entry against, so
		# an operator meeting this twice is handed one command both times.
		_refuse_dubious_ownership(
			join("\n", grep {defined && /\S/} ($err, $root)),
			abs_path($path) // $path);
		bail("Not a git repository: %s", $path);
	}

	# Return existing instance for this repo
	return $_instances{$root} if $_instances{$root};

	my ($prefix) = run({}, 'git', '-C', $path, 'rev-parse', '--show-prefix');
	chomp $prefix if defined $prefix;
	$prefix //= '';

	return $_instances{$root} = bless {
		root          => $root,
		prefix        => $prefix,
		_branch_cache => {},
		_in_session   => 0,
	}, $class;
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
# DESTROY - evict the flyweight entry {{{
#
# The branch restore that used to live here has moved to the session, which
# registers its last-resort abort through at_exit.  bail exits when it is not
# inside an eval, Perl runs END before global destruction, and the order after
# that is undefined, so a net here fires too late or not at all.
sub DESTROY {
	my ($self) = @_;
	delete $self->{_session};
	delete $_instances{$self->{root}} if $self->{root};
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
# git_dir - the absolute git directory of this working tree {{{
#
# Not the same as the working tree root, and deliberately so: in a linked
# working tree this resolves under .git/worktrees/<name>/, so a lock written
# here is per working tree and two working trees of one repository never
# contend, which is the scope D46 gives the switch lock.
sub git_dir {
	my ($self) = @_;
	return $self->{_git_dir} if $self->{_git_dir};
	my ($dir) = run({ dir => $self->{root} },
		'git', 'rev-parse', '--absolute-git-dir');
	chomp $dir if defined $dir;
	# --absolute-git-dir always answers an absolute path, and a failure
	# answers git's complaint, so the leading slash is what tells them apart.
	bail("Unable to resolve the git directory of %s", $self->{root})
		unless $dir && $dir =~ m{^/};
	return $self->{_git_dir} = $dir;
}

# }}}
# session - the one branch session for this handle {{{
#
# Keyed on the handle rather than on the repository, so a caller holding two
# handles for two working trees holds one session on each, which is what I9
# says.  Built on the first ask and reused afterwards.
sub session {
	my ($self, %opts) = @_;
	require Service::Git::Session;
	return $self->{_session} //= Service::Git::Session->new($self, %opts);
}

# }}}
# }}}

### Branch Operations {{{

# current_branch - name of the branch at HEAD {{{
#
# A name or nothing.  On an unborn HEAD git prints the literal string HEAD,
# writes a three-line fatal to standard error, and exits non-zero, so a
# reader that ignored the return code and merged that stream into its answer
# handed git's own complaint back as though it were a branch name.  It then
# reached an operator spliced into whichever refusal had asked the question,
# which is how the pre-deploy gate came to tell a repository with no commits
# to rebase onto the tip of control.  The return code decides here, standard
# error is left where it is, and a HEAD that names no branch answers
# undefined.
#
# A detached HEAD is not that state.  git succeeds there and says HEAD, and
# that is what comes back, because the session's _standing_on tells a
# detached HEAD from a branch by exactly that answer.
sub current_branch {
	my ($self) = @_;
	my ($out, $rc) = run({ dir => $self->{root}, stderr => 0 },
		'git', 'rev-parse', '--abbrev-ref', 'HEAD');

	my $branch;
	unless ($rc) {
		chomp($branch = $out // '');
		undef $branch unless length $branch;
	}

	return $branch;
}

# }}}
# checkout - switch to a branch, from inside a session {{{
#
# The one door.  Every branch change in Genesis goes through the session's
# switch, which is what makes I1 and I9 enforceable rather than hoped for, so
# a call from anywhere else is a bug and says so.
sub checkout {
	my ($self, $branch) = @_;
	bail(
		"A branch checkout was attempted outside a branch session in #C{%s}.\n\n".
		"Every branch change goes through the session, so that the working ".
		"tree can be put back the way it was found.",
		$self->{root}
	) unless $self->{_in_session};

	# The branch being checked out may not carry the directory we are
	# standing in -- a deployment root that exists only on the branch we are
	# leaving.  Run from the repository root so the checkout cannot delete
	# the ground under us, and return to where we were only if it survived;
	# run({dir => ...}) would restore unconditionally and die on a directory
	# the checkout just removed.
	my $cwd = getcwd();
	chdir($self->{root})
		or bail("Unable to enter git root %s: %s", $self->{root}, $!);
	run({ onfailure => "Failed to checkout '$branch'" },
		'git', 'checkout', $branch);
	chdir($cwd) if -d $cwd;

	return $self;
}

# }}}
# reset_hard - put the checked-out branch's tree, index, and tip at a ref {{{
#
# The pull request branch is derived state, rebuilt from the deployment branch
# on every run under D51, so the arm needs one call that moves all three at
# once.  It runs from the repository root, because the ref being reset to may
# not carry the directory we are standing in.
sub reset_hard {
	my ($self, $ref) = @_;
	run({dir => $self->{root}, onfailure => "Failed to reset to '$ref'"},
		'git', 'reset', '--hard', $ref);
	delete $self->{_branch_cache};
	return $self;
}

# }}}
# checkout_detached - stand on a commit rather than on a branch {{{
#
# Separate from checkout rather than folded into it, because the two are
# different operations with different consequences: one puts us on a branch
# that a later commit moves, and this one leaves HEAD detached, which is only
# ever safe inside a branch session that restores on every exit path.
#
# It runs from the repository root for the same reason checkout does: the
# commit being stood on may not carry the directory we are standing in, and a
# checkout that removes the ground under us would leave the caller nowhere.
sub checkout_detached {
	my ($self, $commit) = @_;
	bail(
		"A detached checkout was attempted outside a branch session in ".
		"#C{%s}.\n\nEvery branch change goes through the session, so that ".
		"the working tree can be put back the way it was found.",
		$self->{root}
	) unless $self->{_in_session};

	my $cwd = getcwd();
	chdir($self->{root})
		or bail("Unable to enter git root %s: %s", $self->{root}, $!);
	run({ onfailure => "Failed to check out '$commit'" },
		'git', 'checkout', '--detach', $commit);
	chdir($cwd) if -d $cwd;

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
# set_branch_ref - force one local branch ref to a ref {{{
#
#   $git->set_branch_ref('qa/bosh', 'refs/remotes/origin/qa/bosh');
#
# The forced write onto a local branch, which the design admits in three
# cases only: the pre-flight's reset of a marker-only commit, the session's
# abort of a branch it committed to, and the branch gate's fast-forward of a
# deployment branch this clone holds behind its counterpart, made for a
# command whose registration declares branch_fast_forward and for no other.
# The third discards nothing, its caller having asked resolve_branch first
# and moving only on behind.  It refuses the checked-out branch,
# because git's own `branch -f` refuses there and a ref that disagreed with
# the working tree beside it would be worse than a refusal.
sub set_branch_ref {
	my ($self, $branch, $ref) = @_;

	# SOFTWARE, because a caller that asks to move the branch the tree is
	# standing on has a defect in it.  Every caller the design admits knows
	# where it is standing, so an operator cannot provoke this by anything
	# they type.
	bail(
		{exitcode => SOFTWARE},
		"Refusing to force #C{%s}, which is the branch this working tree is ".
		"on.  Switch away from it first.",
		$branch
	) if ($self->current_branch // '') eq $branch;

	run({dir => $self->{root}, onfailure => "Failed to move '$branch' to '$ref'"},
		'git', 'branch', '-f', $branch, $ref);
	$self->{_branch_cache}{$branch} = 1;
	return $self;
}

# }}}
# create_orphan_branch - write a root commit with plumbing and no checkout {{{
#
# D42 makes a missing deployment branch an orphan whose root commit adds a
# single init file, and D80 has pipeline-apply create it with plumbing and
# no checkout, so the command needs no session and the operator's working
# tree never moves.  The objects go into the database through a private
# index, so the repository's own index is untouched too.
sub create_orphan_branch {
	my ($self, $branch, %opts) = @_;

	bail("Refusing to recreate the branch #C{%s}, which already exists", $branch)
		if $self->branch_exists($branch);

	# A caller that forgets the message would otherwise write a root commit
	# with an empty one, and hear about it as a warning about an undefined
	# value rather than as the argument it left out.
	bug("create_orphan_branch was called for '%s' with no message", $branch)
		unless defined($opts{message}) && length($opts{message});

	my $files = $opts{files} || {};

	# tmpfile reserves a name and creates nothing, so the index git writes
	# here is one it makes for itself and no stale index stands where the
	# name points.
	my $index = tmpfile(template => 'genesis-orphan-XXXXXXXX');
	local $ENV{GIT_INDEX_FILE} = $index;

	for my $path (sort keys %$files) {
		my $source = tmpfile(template => 'genesis-blob-XXXXXXXX');
		mkfile_or_fail($source, $files->{$path});

		my ($blob) = run({dir => $self->{root},
			onfailure => "Failed to write the object for '$path'"},
			'git', 'hash-object', '-w', $source);
		chomp $blob;

		run({dir => $self->{root},
			onfailure => "Failed to stage '$path' for '$branch'"},
			'git', 'update-index', '--add', '--cacheinfo', "100644,$blob,$path");
	}

	my ($tree) = run({dir => $self->{root},
		onfailure => "Failed to write the tree for '$branch'"},
		'git', 'write-tree');
	chomp $tree;

	# No parent is named, which is what makes the commit a root and the
	# branch an orphan.
	my ($sha) = run({dir => $self->{root},
		onfailure => "Failed to write the root commit for '$branch'"},
		'git', 'commit-tree', $tree, '-m', $opts{message});
	chomp $sha;

	run({dir => $self->{root},
		onfailure => "Failed to write refs/heads/$branch"},
		'git', 'update-ref', "refs/heads/$branch", $sha);
	$self->{_branch_cache}{$branch} = 1;

	return $sha;
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

	# git's own complaint is kept out of the answer, the way current_branch
	# keeps it out of its own.  A ref git cannot resolve is answered with
	# nothing, because a caller that recorded this value would otherwise
	# write a fatal sentence into the slot a commit belongs in.
	my ($sha, $rc) = run({ dir => $self->{root}, stderr => 0 }, @cmd);
	return undef if $rc;
	chomp $sha if defined $sha;
	return undef unless defined $sha && length $sha;
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
# holds_commit - does this repository have the commit object at all {{{
#
# The narrower of the two questions, and the one a reader asks before it asks
# git for anything that has to walk the commit.  A diff against a commit this
# clone never fetched fails outright, so a caller that would rather report
# what it cannot read than end on git's own error asks here first.
sub holds_commit {
	my ($self, $sha) = @_;
	return 0 unless defined $sha && $sha =~ /^[0-9a-f]{4,40}$/;
	return run({dir => $self->{root}, passfail => 1},
		'git', 'cat-file', '-e', "$sha^{commit}") ? 1 : 0;
}

# }}}
# commit_exists - does a remote-tracking ref still reach this commit {{{
#
# The question a propagation marker raises is whether a fresh clone could
# fetch the commit the marker names, so it is about reachability rather than
# about the object, and about what the remote holds rather than about what
# this clone happens to.  A commit the remote has dropped stays here as a
# loose object until git collects it, and the local branch that wrote it goes
# on reaching it, because a refresh moves the remote-tracking refs and leaves
# a local branch where it stands.  A reader that counted either would answer
# yes in exactly the clone an operator runs this command in, and could never
# report the breach H30 names.
sub commit_exists {
	my ($self, $sha) = @_;

	# Asked first, because git refuses to answer the reachability question
	# about a name it cannot resolve to an object at all.  It is the object
	# question, so it is asked through the reader that owns it rather than
	# spelled a second time here.
	return 0 unless $self->holds_commit($sha);

	# The remote-tracking refs alone, and the refresh has just made them
	# current, so what they reach is what the remote holds.
	my ($out) = run({dir => $self->{root}, stderr => 0},
		'git', 'branch', '--remotes', '--contains', $sha);
	return ($out // '') =~ /\S/ ? 1 : 0;
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
# preflight - classify the three failures a switch or a commit hides {{{
#
# D80 keeps this in the session's begin and shares it with genesis new, the
# one writer that never switches, so H20 closes for both without either
# growing its own copy.  One cheap git command asks the question, and its
# stderr is what tells the three apart: git itself names dubious ownership,
# reports an empty HEAD, and complains about an unknown committer, and each
# of those becomes a message naming the fix rather than a failed checkout.
sub preflight {
	my ($self) = @_;

	my ($out, $rc, $err) = run({ dir => $self->{root}, passfail => 0 },
		'git', 'rev-parse', '--verify', 'HEAD');
	my $said = join("\n", grep {defined && /\S/} ($err, $out));

	if ($rc) {
		_refuse_dubious_ownership($said, $self->{root});

		bail({exitcode => DATAERR},
			"The repository at #C{%s} has no commits, so there is no branch to ".
			"leave and nothing to come back to.\n\n".
			"    git commit --allow-empty -m 'Initial commit'\n\n".
			"Make the first commit, then run this command again.",
			$self->{root});
	}

	# Identity is asked for separately, because a repository with commits
	# answers rev-parse happily and only fails at the commit itself, which
	# is exactly the late generic error H20 names.
	my ($name)  = run({ dir => $self->{root}, passfail => 0 },
		'git', 'config', '--get', 'user.name');
	my ($email) = run({ dir => $self->{root}, passfail => 0 },
		'git', 'config', '--get', 'user.email');
	$name  = '' unless defined $name  && $name  =~ /\S/;
	$email = '' unless defined $email && $email =~ /\S/;
	$name  ||= $ENV{GIT_COMMITTER_NAME}  // $ENV{GIT_AUTHOR_NAME}  // '';
	$email ||= $ENV{GIT_COMMITTER_EMAIL} // $ENV{GIT_AUTHOR_EMAIL} // '';

	bail({exitcode => CONFIG},
		"This process has no committer identity, so git cannot record a ".
		"commit in #C{%s}.\n\n".
		"    git config user.name  \"Your Name\"\n".
		"    git config user.email \"you\@example.com\"\n\n".
		"Set both, then run this command again.",
		$self->{root}
	) unless length($name) && length($email);

	return $self;
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
#
# The return code is read and stderr is kept apart from stdout, for the
# reason diff_names gives below and with the same refusal, because a git
# that refuses the command writes its reason where the file names would
# be, no line of that reason matches any of the three statuses this loop
# tests, and the answer would be an empty changed list and an empty
# deleted list, which every caller reads as nothing having changed.  A
# drift warning that has gone silent is the one answer this reader must
# never give.
sub diff_files {
	my ($self, $from, $to, @pathspecs) = @_;
	my @cmd = ('git', 'diff', '--name-status', $from, $to);
	push @cmd, '--', @pathspecs if @pathspecs;
	my ($out, $rc, $err) = run({ dir => $self->{root}, stderr => 0 }, @cmd);
	bail(
		{exitcode => DATAERR},
		"Cannot diff #C{%s} against #C{%s} in #C{%s}:\n%s\n".
		"Fetch the missing commit or branch, then try again.",
		$from, $to, $self->{root},
		($err // $out // 'git gave no reason')
	) if $rc;

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
#
# The return code is read rather than thrown away, and stderr is kept
# apart from stdout, because a git that refuses the command writes its
# reason where the file names would be and an unchecked read hands that
# reason back as though those lines were changed paths.  No error text
# matches a real path, so a caller comparing the list against a known set
# would find nothing in it and conclude that nothing had changed, which is
# the one wrong answer a diff can give.  Two ordinary states reach it: an
# applied commit the local repository does not hold, and a branch that
# exists only as a remote-tracking ref.
sub diff_names {
	my ($self, $from, $to, @pathspecs) = @_;
	my @cmd = ('git', 'diff', '--name-only', $from, $to);
	push @cmd, '--', @pathspecs if @pathspecs;
	my ($out, $rc, $err) = run({ dir => $self->{root}, stderr => 0 }, @cmd);
	bail(
		{exitcode => DATAERR},
		"Cannot diff #C{%s} against #C{%s} in #C{%s}:\n%s\n".
		"Fetch the missing commit or branch, then try again.",
		$from, $to, $self->{root},
		($err // $out // 'git gave no reason')
	) if $rc;
	return grep { /\S/ } split /\n/, ($out || '');
}

# }}}
# commit_stat - the diff --stat lines for one commit, scoped to a pathspec {{{
#
# Each entry of D49's aggregate body carries the files one control commit
# changed within this environment's propagation set, in the shape git prints,
# so a reviewer reads the same summary they would read on control.
#
# It takes the commit rather than a pair of endpoints, and it reads through
# diff-tree with --root, because control's own first commit is a commit like
# any other: an environment introduced there has that commit due on its first
# run, and a summary asked for against a parent the commit does not have is
# one git refuses outright.  Genesis::CI::Walk::changed_set reads a commit's
# paths the same way and for the same reason.  --no-commit-id keeps the hash
# diff-tree would otherwise print above the summary out of the body.
#
# The width is fixed rather than left to git, because git sizes the graph
# column against the terminal it thinks it is writing to and the answer here
# is going into a commit message, where the width the author's terminal
# happened to have is nobody's business.
#
# The status is read and the standard error kept apart, the way diff_names
# reads its own, because a git that refuses the command writes its reason
# where the file names would be and those lines would be printed into a commit
# message as though they were a summary.
sub commit_stat {
	my ($self, $commit, @pathspecs) = @_;
	my @cmd = ('git', 'diff-tree', '--no-commit-id', '--stat',
		'--stat-width=72', '--root', $commit);
	push @cmd, '--', @pathspecs if @pathspecs;
	my ($out, $rc, $err) = run({dir => $self->{root}, stderr => 0}, @cmd);
	bail(
		{exitcode => DATAERR},
		"Cannot summarise #C{%s} in #C{%s}:\n%s",
		$commit, $self->{root}, ($err // $out // 'git gave no reason')
	) if $rc;
	return grep { /\S/ } split /\n/, ($out || '');
}

# }}}
# mirror_tree - the tree a mirror of these paths at this commit makes {{{
#
# A delivery is a mirror, so the tree it produces is entirely decided by the
# commit it delivers and the paths of the set at that commit: every one of
# them with the blob and the mode the source carries, and nothing beside
# them.  Nothing about the branch it lands on enters into it.
#
# It exists for the preview.  A dry run writes no commit, so the branch does
# not advance between one previewed delivery and the next, and a second
# delivery worked out against the branch would report the first delivery's
# files under it as well.  The preview therefore takes this tree from each
# delivery and hands it to the one after as its base, so each commit's files
# are that commit's own.
#
# The index is a temporary one that git makes for itself, and the tree is
# written into the object database unreferenced, the way write-tree always
# writes one.  Nothing points at it, so it costs a gc and no more.
#
# The listing and the staging are both NUL-separated, because git quotes and
# octal-escapes any path holding a byte outside ASCII when it writes one name
# per line, and a quoted name staged back is a path nobody has.
sub mirror_tree {
	my ($self, $source, @paths) = @_;

	bug("Service::Git::mirror_tree needs the commit the mirror is taken from")
		unless defined $source && length $source;
	return undef unless @paths;

	my ($listing) = run({dir => $self->{root}, stderr => 0,
		onfailure => "Failed to read the tree of '$source'"},
		'git', 'ls-tree', '-r', '-z', $source, '--', @paths);
	return undef unless defined $listing && length $listing;

	# tmpfile reserves a name and creates nothing, so the index below is one
	# git makes for itself and no stale index stands where the name points.
	my $index = tmpfile(template => 'genesis-mirror-XXXXXXXX');
	local $ENV{GIT_INDEX_FILE} = $index;

	# The listing reaches git through a file rather than through run's stdin,
	# which fills a pipe and closes it before the child is spawned.  Nobody
	# is reading the far end while it fills, so a listing larger than the
	# pipe will hold stops the write for good, and a set of about nine
	# hundred files already makes a listing larger than that.  A file has no
	# such ceiling, and the child reads it at whatever pace it likes.
	my $feed = tmpfile(template => 'genesis-mirror-in-XXXXXXXX');
	mkfile_or_fail($feed, $listing);

	run({dir => $self->{root},
		onfailure => "Failed to stage the mirror of '$source'"},
		'git update-index -z --index-info < "$1"', $feed);
	unlink $feed;

	my ($tree, $rc, $err) = run({dir => $self->{root}, stderr => 0},
		'git', 'write-tree');
	chomp $tree if defined $tree;

	unlink $index;

	# The status is read and stderr is kept apart, the way ls_tree and
	# diff_names read theirs, and the answer is read for its shape besides.
	# write-tree writes the tree it made and nothing beside it, so anything
	# else standing there is git talking rather than git answering.  Merged
	# into stdout, a warning about the environment comes back as the head of
	# the answer, and the preview hands that on as the base of the delivery
	# after it, which then asks git to diff against a tree nobody wrote.
	#
	# The length test is not the sibling chain's ($err // $out // ...) and
	# must not be simplified into one.  Under stderr => 0 the stderr file is
	# always created, and slurp reads an empty one as the empty string rather
	# than as undefined, so a defined-or stops at an $err that says nothing
	# and the refusal goes out with nothing in it.  The case this guards is
	# the one that matters here: git exits zero, answers something that is
	# not a tree, and writes nothing to stderr.
	my $said = length($err // '') ? $err
	         : length($tree // '') ? $tree
	         : 'git gave no reason';
	bail(
		{exitcode => DATAERR},
		"Cannot write the mirror tree of #C{%s} in #C{%s}:\n%s",
		$source, $self->{root}, $said
	) if $rc || !defined($tree) || $tree !~ /^[0-9a-f]{40}$/;

	return $tree;
}

# }}}
# ls_tree - list files on a ref under a prefix {{{
#
# The listing is NUL-separated, because git quotes and octal-escapes any path
# holding a byte outside ASCII when it writes one name per line, and a caller
# comparing those names against a set would read the real path as absent and
# the quoted one as a stranger.  Under -z the bytes come through as they are.
sub ls_tree {
	my ($self, $ref, $path) = @_;
	$path //= '';
	my ($out, $rc, $err) = run({ dir => $self->{root}, stderr => 0 },
		'git', 'ls-tree', '-r', '--name-only', '-z', $ref, $path);
	# The status is read, the way ls_files and diff_names read theirs.  git
	# refuses an empty pathspec and a ref it cannot resolve by name, and a
	# refusal handed back unread is a sentence split on NULs and answered as
	# though it were the paths on that ref.  A caller then has git's own
	# complaint standing where a path should be, which is worse than the
	# question going unanswered.
	bail(
		{exitcode => DATAERR},
		"Cannot list #C{%s} in #C{%s}:\n%s",
		$ref, $self->{root}, ($err // $out // 'git gave no reason')
	) if $rc;
	return grep { /\S/ } split /\0/, ($out || '');
}

# }}}
# ls_files - list what the index holds, optionally scoped by pathspec {{{
#
# The index and not the working tree, which is the difference that matters to
# every caller here: the mirror asks what the branch holds before it writes,
# and D82's second assertion asks what the index holds after it has written,
# and a reader that walked the working tree would answer both questions with
# the operator's untracked files thrown in.
#
# The paths come back git-root-relative whatever directory the caller is
# standing in, because --full-name fixes them to the root, and the run is made
# from the root so a pathspec is read against the root as well.  They are
# NUL-separated for the reason ls_tree's are.
#
# The return code is read rather than thrown away, and stderr is kept apart
# from stdout, for the reason diff_names gives: a git that refuses the command
# writes its reason where the paths would be, and no error text matches a real
# path.  The mirror's removing half is what makes that fatal here.  Every line
# of a complaint read as an index path lands among the paths the set does not
# hold, `git rm` is then handed a pathspec matching nothing and fails wholesale
# under passfail, and every genuine removal is lost with nothing said.
sub ls_files {
	my ($self, @pathspecs) = @_;
	my @cmd = ('git', 'ls-files', '--cached', '--full-name', '-z');
	push @cmd, '--', @pathspecs if @pathspecs;
	my ($out, $rc, $err) = run({ dir => $self->{root}, stderr => 0 }, @cmd);
	bail(
		{exitcode => DATAERR},
		"Cannot read the index of #C{%s}:\n%s",
		$self->{root}, ($err // $out // 'git gave no reason')
	) if $rc;
	return grep { /\S/ } split /\0/, ($out || '');
}

# }}}
# diff_cached_quiet - does the index match a ref's tree over these paths {{{
#
# D82's first assertion, spelled the way the design spells it.  True when the
# index and the ref agree, which is git's own quiet exit status, where nought
# means they agree and one means they differ.
#
# Anything above one is a git that could not take the comparison at all, and
# it is raised rather than answered, the way diff_names raises.  A source the
# repository cannot reach is not a mismatch over every path, and a caller
# handed a false for it would report the whole set as differing and name a
# difference nobody made.
sub diff_cached_quiet {
	my ($self, $ref, @pathspecs) = @_;
	my @cmd = ('git', 'diff', '--cached', '--quiet', $ref);
	push @cmd, '--', @pathspecs if @pathspecs;
	my ($out, $rc, $err) = run({ dir => $self->{root}, stderr => 0 }, @cmd);
	bail(
		{exitcode => DATAERR},
		"Cannot compare the index of #C{%s} against #C{%s}:\n%s\n".
		"Fetch the missing commit or branch, then try again.",
		$self->{root}, $ref, ($err // $out // 'git gave no reason')
	) if $rc > 1;
	return $rc == 0 ? 1 : 0;
}

# }}}
# diff_cached_names - the paths over which the index and a ref differ {{{
#
# What a failed first assertion reports, so a run names the difference rather
# than saying only that there was one.
sub diff_cached_names {
	my ($self, $ref, @pathspecs) = @_;
	my @cmd = ('git', 'diff', '--cached', '--name-only', '-z', $ref);
	push @cmd, '--', @pathspecs if @pathspecs;
	my ($out, $rc, $err) = run({ dir => $self->{root}, stderr => 0 }, @cmd);
	bail(
		{exitcode => DATAERR},
		"Cannot compare the index of #C{%s} against #C{%s}:\n%s\n".
		"Fetch the missing commit or branch, then try again.",
		$self->{root}, $ref, ($err // $out // 'git gave no reason')
	) if $rc;
	return grep { /\S/ } split /\0/, ($out || '');
}

# }}}
# log_subjects - return commit lines, or whole messages, for a branch {{{
#
# Options:
#   limit  => N       — max number of entries
#   format => '...'   — custom format (default: %H %s, or %H\x1f%B with body)
#   paths  => [...]   — git-root-relative pathspec
#   body   => 1       — return whole commit messages rather than lines
#
# The body walk exists because a squash merge keeps the pull request's title
# as its subject and pushes the aggregate's message down into the body, so a
# marker that is plainly on the commit is invisible to a walk over subject
# lines.  D49 has the marker walk read subjects and bodies alike, and this is
# the primitive it reads them with.  Records are separated by an ASCII record
# separator and their two fields by a unit separator, so a commit message may
# carry any text at all without confusing the split.
sub log_subjects {
	my ($self, $branch, %opts) = @_;

	my $body = $opts{body} ? 1 : 0;
	my $fmt  = $opts{format} || ($body ? '%H%x1f%B' : '%H %s');
	$fmt .= '%x1e' if $body;

	my @cmd = ('git', 'log', "--format=$fmt", $branch);
	push @cmd, "-$opts{limit}" if $opts{limit};
	# Optional pathspec filter: only commits that touched any of these
	# git-root-relative paths.  Used to scope the env-branch history to
	# what's relevant to a particular deployment (e.g., bosh vs vault in
	# a multi-deploy repo).
	if ($opts{paths} && @{$opts{paths}}) {
		push @cmd, '--', @{$opts{paths}};
	}

	# Standard error is kept apart and the return code is read, because the
	# default folds git's complaint into the answer and a range git cannot
	# resolve would come back as the lines of its fatal message for the
	# caller to read as commits.
	my ($out, $rc, $err) = run({ dir => $self->{root}, stderr => 0 }, @cmd);
	bail(
		{exitcode => DATAERR},
		"Cannot read the history of #C{%s} in #C{%s}:\n%s\n".
		"Fetch the missing commit or branch, then try again.",
		$branch, $self->{root}, ($err // $out // 'git gave no reason')
	) if $rc;

	return split /\n/, ($out || '') unless $body;

	my @records;
	for my $record (split /\x1e/, ($out || '')) {
		next unless $record =~ /\S/;
		my ($sha, $message) = split /\x1f/, $record, 2;
		$sha =~ s/\A\s+//;
		push @records, {sha => $sha, message => defined $message ? $message : ''};
	}
	return @records;
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
# branch_upstream_remote - the remote a branch is configured to track {{{
sub branch_upstream_remote {
	my ($self, $branch) = @_;
	my ($out) = run({dir => $self->{root}, passfail => 0, stderr => 0},
		'git', 'config', '--get', "branch.$branch.remote");
	chomp $out if defined $out;
	return (defined $out && length $out) ? $out : undef;
}

# }}}
# has_remote - whether a remote of this name is configured {{{
sub has_remote {
	my ($self, $remote) = @_;
	# stderr apart from stdout for the same reason branch_upstream_remote
	# asks for it: a complaint merged into the output would be one more
	# line to search for a remote's name in.
	my ($out) = run({dir => $self->{root}, stderr => 0}, 'git', 'remote');
	return 0 unless defined $out;
	return scalar(grep {$_ eq $remote} split(/\n/, $out)) ? 1 : 0;
}

# }}}
# remote_url - fetch the fetch URL for a named (or default) remote {{{
sub remote_url {
	my ($self, $remote) = @_;
	$remote //= $self->default_remote;
	return undef unless $remote;
	# git writes its complaint on stderr, and merging that into stdout would
	# put the text of the complaint into the url a caller goes on to use, so
	# it is captured apart and a non-zero exit answers no url at all.
	my ($url, $rc) = run({dir => $self->{root}, stderr => 0},
		'git', 'remote', 'get-url', $remote);
	return undef if $rc;
	chomp $url if defined $url;
	return $url;
}

# }}}
# remote_branch_exists - check whether a branch exists on the remote {{{
#
# The remote is asked for the fully qualified ref, and the answer is then
# filtered to the line whose ref is exactly that, because ls-remote matches
# the tail of a ref at slash boundaries.  A bare name such as qa/bosh is
# answered by the pull request branch pr/qa/bosh, so a caller deciding
# whether to create qa/bosh would be told it was already there.
sub remote_branch_exists {
	my ($self, $branch, $remote) = @_;
	$remote //= $self->default_remote;
	return 0 unless $remote;
	my ($out, $rc, $err) = run({ dir => $self->{root}, passfail => 0 },
		'git', 'ls-remote', '--heads', $remote, "refs/heads/$branch");
	bail("ls-remote against #C{%s} failed: %s",
		$remote, ($err || $out || "rc=$rc") =~ s/\s+$//r) if $rc;

	for my $line (split /\n/, ($out // '')) {
		next unless $line =~ m{\srefs/heads/(\S+)\s*$};
		return 1 if $1 eq $branch;
	}
	return 0;
}

# }}}
# resolve_branch - how a local branch stands against its remote-tracking ref {{{
#
#   my $div = $git->resolve_branch($branch);
#   my $div = $git->resolve_branch($branch, remote => 'origin');
#   my $div = $git->resolve_branch($branch, unverifiable => 1);
#
# Returns one of the six states of the design with both counts and the
# unverifiable flag:
#
#   { state => 'in-sync', ahead => 0, behind => 0, unverifiable => 0 }
#
# in-sync, ahead, behind, and diverged come from the two counts that
# `git rev-list --left-right --count L...T` reports.  no-local and no-remote
# are the two existence answers, asked before the counts because the query
# compares two refs and runs only when both exist.  When neither ref exists
# the whole record is undef, because the design gives that case no state.
#
# Both halves are read through _ref_exists, which asks about the named ref
# and about nothing else.  branch_exists runs `git rev-parse --verify` on a
# short name, so a tag carrying a branch name would read as the branch, and
# it memoises, so a handle that asked before a refresh would keep answering
# no-local after one.  The counts are taken against refs/heads, and a local
# half that disagreed with them would turn this query into a bail.
#
# The query never fetches.  Under D40 the refresh is its own step, so a
# caller refreshes first and passes unverifiable => 1 when it did not,
# which is what `genesis pipeline-status --no-refresh` does.
sub resolve_branch {
	my ($self, $branch, %opts) = @_;
	my $remote       = exists $opts{remote} ? $opts{remote} : $self->default_remote;
	my $unverifiable = $opts{unverifiable} ? 1 : 0;

	my $local    = $self->_ref_exists("refs/heads/$branch");
	my $tracking = $remote
		? $self->_ref_exists("refs/remotes/$remote/$branch")
		: 0;

	return undef unless $local || $tracking;

	return {state => 'no-remote', ahead => 0, behind => 0, unverifiable => $unverifiable}
		if $local && !$tracking;

	return {state => 'no-local', ahead => 0, behind => 0, unverifiable => $unverifiable}
		if $tracking && !$local;

	my ($out) = run({dir => $self->{root}, onfailure => "Failed to compare '$branch' with '$remote/$branch'"},
		'git', 'rev-list', '--left-right', '--count',
		"refs/heads/$branch...refs/remotes/$remote/$branch");
	my ($ahead, $behind) = (($out // '') =~ /(\d+)\s+(\d+)/);
	($ahead, $behind) = (0, 0) unless defined $ahead;

	my $state = ($ahead && $behind) ? 'diverged'
	          : $ahead              ? 'ahead'
	          : $behind             ? 'behind'
	          :                       'in-sync';

	return {
		state        => $state,
		ahead        => $ahead + 0,
		behind       => $behind + 0,
		unverifiable => $unverifiable,
	};
}

# }}}
# _ref_exists - does this fully qualified ref exist in this repository {{{
sub _ref_exists {
	my ($self, $ref) = @_;
	return run({dir => $self->{root}, passfail => 1},
		'git', 'show-ref', '--verify', '--quiet', $ref) ? 1 : 0;
}

# }}}
# _ref_names - the short names under one ref namespace {{{
#
# One read rather than one probe per name, because the refresh asks about
# every branch it was given twice, once to decide which refspec each takes
# and once to see what arrived.  The read is checked rather than trusted: a
# failure that answered an empty set would tell the refresh that every
# branch is absent locally, and the refresh would then force a write onto
# each of them, which is H17 coming back through inherited code.
sub _ref_names {
	my ($self, $prefix, $opts) = @_;
	my $strip = scalar grep {length} split m{/}, $prefix;
	my ($out, $rc, $err) = run({%{$opts || {dir => $self->{root}}}},
		'git', 'for-each-ref', "--format=%(refname:strip=$strip)", $prefix);
	bail("Failed to list #C{%s} in #C{%s}: %s",
		$prefix, $self->{root}, ($err || $out || "rc=$rc") =~ s/\s+$//r)
		if $rc;
	return {map {$_ => 1} grep {/\S/} split(/\n/, $out // '')};
}

# }}}
# checked_out_branch - the branch HEAD points at, born or not {{{
#
# current_branch reads `git rev-parse --abbrev-ref HEAD`, which fails on an
# unborn branch, so it answers undefined there and cannot name the branch a
# fresh orphan checkout is standing on.  symbolic-ref names that branch, and
# it answers nothing at all on a detached HEAD, which tells the two cases
# apart.
sub checked_out_branch {
	my ($self) = @_;
	my ($out, $rc) = run({dir => $self->{root}, stderr => 0},
		'git', 'symbolic-ref', '--short', '-q', 'HEAD');
	return undef if $rc;
	chomp(my $branch = $out // '');
	return length $branch ? $branch : undef;
}

# }}}
# delete_branch - delete a local branch, forcibly {{{
#
# The pull request branch is derived state and is rebuilt from the deployment
# branch on every run, so a local ref is never worth preserving, and one the
# remote no longer carries is exactly what breaks the next cycle.
sub delete_branch {
	my ($self, $branch) = @_;
	return $self if ($self->current_branch // '') eq $branch;
	run({dir => $self->{root},
			onfailure => "Failed to delete local branch '$branch'"},
		'git', 'branch', '-D', $branch);
	delete $self->{_branch_cache}{$branch};
	return $self;
}

# }}}
# forget_branch - drop the remote-tracking ref for a branch the remote lost {{{
#
# fetch_branches never prunes, because the local-only commit query reads the
# tracking refs a prune would delete, so a branch the remote no longer carries
# leaves its tracking ref standing and every reader of that ref is told the
# remote still has it.  One reader pays for that, which is the lease, because a
# push leased against a value the remote has not got is refused, and it stays
# refused on every run afterwards.
#
# So the removal is one ref, named by a caller that has just asked the remote
# and been told the branch is gone, rather than a prune of everything.
sub forget_branch {
	my ($self, $branch, $remote) = @_;
	$remote //= $self->default_remote;
	return $self unless $remote;
	return $self unless $self->branch_exists("$remote/$branch");

	run({dir => $self->{root},
			onfailure => "Failed to forget the remote-tracking ref for '$branch'"},
		'git', 'update-ref', '-d', "refs/remotes/$remote/$branch");
	delete $self->{_branch_cache}{"$remote/$branch"};
	return $self;
}

# }}}
# fetch_branches - refresh branches from a remote in one call {{{
#
# The one refresh.  It brings the remote into the remote-tracking refs for
# every branch it is given, it skips none of them for being checked out,
# because control usually is the checked-out branch and leaving it out is
# how a run comes to source from stale state, and it never prunes, because
# the local-only commit query reads the tracking refs a prune would delete.
sub fetch_branches {
	my ($self, $names, $remote) = @_;
	$remote //= $self->default_remote;
	my $noop = {ok => 1, kind => 'success', fetched => [], created => [], absent => []};
	return wantarray ? ($self, $noop) : $self
		unless $remote && $names && @$names;

	# One name asked for twice is one branch, and a caller that prepends the
	# control branch to a list that may already carry it should not have to
	# check.  A duplicate would otherwise be reported twice and, where the
	# clone lacks it, put the same forced refspec on the command line twice.
	my %seen;
	my @want = grep {defined && length && !$seen{$_}++} @$names;
	return wantarray ? ($self, $noop) : $self unless @want;

	my %env;
	$env{GIT_TERMINAL_PROMPT} = '0' unless in_controlling_terminal();
	my %opts = (dir => $self->{root}, (%env ? (env => \%env) : ()));

	# A refspec naming a branch the remote lacks aborts the entire fetch.
	# Patterns are fully qualified: ls-remote matches the tail of a ref.
	my ($out, $rc, $err) = run({%opts},
		'git', 'ls-remote', '--heads', $remote,
		map {"refs/heads/$_"} @want);
	return wantarray
		? ($self, {ok => 0, kind => _classify_remote_error($err), err => $err // '',
		           fetched => [], created => [], absent => []})
		: $self
		if $rc;

	my %on_remote;
	for my $line (split /\n/, ($out // '')) {
		$on_remote{$1} = 1 if $line =~ m{\srefs/heads/(\S+)\s*$};
	}
	my @present = grep { $on_remote{$_}} @want;
	my @absent  = grep {!$on_remote{$_}} @want;
	my (@fetched, @created);

	if (@present) {
		# The remote is authoritative for which branches exist, not for
		# what they contain.  A branch we already have locally may carry
		# commits that have not been pushed, so it only updates its
		# remote-tracking ref, and that is what makes the checked-out
		# branch safe to include.  Branches we lack are materialised
		# locally, which is the one creation I2 permits.
		my $before = $self->_ref_names('refs/heads/', \%opts);
		my %is_local = %$before;

		# git refuses outright to fetch into the ref HEAD points at, and it
		# fails the whole fetch when it does, so the branch this clone is
		# standing on takes the tracking refspec whatever the read above
		# said about it.  An unborn branch is the one checked-out branch
		# for-each-ref does not list, so without this a fresh orphan
		# checkout would take the forced refspec and lose every other
		# branch in the list with it.
		my $here = $self->checked_out_branch;
		$is_local{$here} = 1 if defined $here;

		my ($fout, $frc, $ferr) = run({%opts}, 'git', 'fetch', $remote,
			(map {"+refs/heads/$_:refs/remotes/$remote/$_"}
				grep { $is_local{$_}} @present),
			(map {"+refs/heads/$_:refs/heads/$_"}
				grep {!$is_local{$_}} @present));
		return wantarray
			? ($self, {ok => 0, kind => _classify_remote_error($ferr), err => $ferr // '',
			           fetched => [], created => [], absent => \@absent})
			: $self
			if $frc;

		# What the result reports is read back off the refs rather than
		# taken from the probe.  The probe says what the remote had a round
		# trip ago, and only a ref says what arrived, so a branch the remote
		# lost in between is reported by what is here rather than by what
		# was there.  D9 asks a refresh to re-read for exactly this reason,
		# since `git fetch --porcelain` arrived above the git floor.
		my $after_local = $self->_ref_names('refs/heads/', \%opts);
		my $after_track = $self->_ref_names("refs/remotes/$remote/", \%opts);
		@created = grep {!$is_local{$_} && $after_local->{$_}} @present;
		@fetched = grep {
			$is_local{$_} ? $after_track->{$_} : $after_local->{$_}
		} @present;

		# Absent on the remote says nothing about local state, so only
		# fetched branches are cached.  The tracking name is cached beside
		# the branch's own, because branch_exists remembers the answer it
		# gave and a caller that asked for origin/<branch> before this
		# fetch would otherwise be handed that miss for the rest of the
		# run.  Genesis::CI::PullRequest::expected_tip and its
		# align_with_remote are the two readers that depend on this, so
		# narrowing the deletion gives each of them a stale miss.
		for my $name (@fetched) {
			$self->{_branch_cache}{$name} = 1;
			delete $self->{_branch_cache}{"$remote/$name"};
		}
	}

	return wantarray
		? ($self, {ok => 1, kind => 'success', fetched => \@fetched,
		           created => \@created, absent => \@absent})
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
# push - push refs to a remote, one push per ref {{{
#
#   my $results = $git->push(remote => 'origin', refs => [
#       { branch => 'lab/bosh',   kind => 'deployment' },
#       { branch => 'pr/qa/bosh', kind => 'pr' },
#   ]);
#
# The remote is required and named, under D83.  Deciding it by asking whether
# a local branch of that name exists is H4, because a repository carrying a
# branch called origin published that branch along with the rest, and a
# mistyped remote that collided with a branch name went to the default remote
# instead of the one the caller meant.
#
# Each ref is pushed on its own, so no ref's rejection withholds another's
# push, which is the third stage of D96.
#
# Returns an arrayref of per-ref results, in the order the specs were given.
# A result carries the reason git gave for a ref it turned down, because a
# push the remote refuses does not die and a caller that took only the ones
# and zeros would have to guess at the cause.  One branch's quarrel with the
# remote is not another's, so each failed ref keeps its own text.
#
# It carries the ref git named as well, and what git made of it, because the
# branch a caller asked for and the ref the remote answered about can differ
# and the name worth reporting is the remote's own.
sub push {
	my ($self, %opts) = @_;
	# Tested for presence rather than for truth, because a remote somebody
	# named 0 is a remote and not a missing argument.
	bail(
		"#R{Service::Git->push} needs its remote by name, as ".
		"#C{remote => '<remote>'}"
	) unless defined $opts{remote} && length $opts{remote};
	my $remote = $opts{remote};
	my @specs = @{$opts{refs} || []};
	return [map {$self->_push_one($remote, $_)} @specs];
}

# }}}
# _push_one - push a single ref and report what git did with it {{{
#
# The refspec is written out in full, so git is asked for the branch and never
# for a name it could resolve some other way.  A spec asking for a removal
# writes the empty source side instead, which is how git is told to take a
# branch off the remote.
#
# The push is asked for its porcelain form, because what the caller reports is
# the ref git named rather than one the caller composed out of the branch it
# asked for, and the porcelain line is the only place git says so.
sub _push_one {
	my ($self, $remote, $spec) = @_;
	my $branch = $spec->{branch};
	my $kind   = $spec->{kind} || 'deployment';

	# A spec with no branch would build refs/heads/:refs/heads/, which git
	# reads as a ref pair of its own and which nobody meant to ask for, so a
	# spec that lost its name says so rather than pushing something.
	bug("#R{Service::Git->push} was handed a ref spec with no branch name")
		unless defined $branch && length $branch;

	# D31 lets a pull request branch be rewritten, because it is derived and
	# private until it merges, and forbids the rewrite on control and on
	# every deployment branch, whose history is append-only.  The refusal
	# sits beside the refspec it would otherwise build, because this is the
	# one place every caller passes through, so Genesis never leaves the
	# guarantee to the repository's own branch protection.  The refusal
	# itself is _refuse_rewrite, which push_append_only raises as well, so
	# an operator who meets this rule on two commands meets one sentence.
	_refuse_rewrite($branch, $remote)
		if exists $spec->{expect} && $kind ne 'pr';

	my $refspec = $spec->{delete}
		? ":refs/heads/$branch"
		: "refs/heads/$branch:refs/heads/$branch";

	# A pull request branch takes its lease against the tip the run read, so
	# the rewrite lands only where nobody has written since, and NULL_SHA
	# asks for a branch the remote has not got yet.  Every other branch is
	# pushed plain, which leaves the remote's own non-fast-forward rule to
	# reject a branch that moved.
	my @lease = exists $spec->{expect}
		? ("--force-with-lease=refs/heads/$branch:".($spec->{expect} || NULL_SHA))
		: ();

	my ($out, $rc, $err) = run({dir => $self->{root}, stderr => 0},
		'git', 'push', '--porcelain', @lease, $remote, $refspec);

	return _read_push_result($branch, $out, $rc, $err);
}

# }}}
# _read_push_result - read one ref's fate out of git push --porcelain {{{
#
# D83 has the run name the moved ref from git's own output rather than from a
# message it composed, so the flag and the ref pair are read here and nowhere
# else.  The flags are git's own: a space is a fast-forward, a plus is a forced
# update, a minus is a deletion, a star is a new ref, an equals sign is a ref
# already up to date, and an exclamation mark is a refusal.
#
# A push that never reached the remote prints no porcelain line at all, so a
# failure with nothing to read falls back to what git wrote to its standard
# error, which is the sentence the caller's classifier reads.
#
# That standard error is carried on its own as well, and whole, because the
# porcelain line's parenthetical is a short phrase such as "fetch first" and
# the words that name a failure's class live in the hint text beside it.  The
# reason stays the short phrase wherever git printed one, so a caller that
# wants the phrase and a caller that wants the whole of it each have their
# own field to read.
sub _read_push_result {
	my ($branch, $out, $rc, $err) = @_;
	my %status = (
		' ' => 'updated', '+' => 'forced',     '-' => 'deleted',
		'*' => 'created', '=' => 'up-to-date', '!' => 'rejected',
	);

	my $result = {
		branch  => $branch,
		ok      => $rc ? 0 : 1,
		ref     => undef,
		status  => undef,
		reason  => '',
		stderr  => ($err // '') =~ s/\s+$//r,
		summary => '',
	};

	for my $line (split /\n/, ($out // '')) {
		next unless $line =~ /^(.)\t([^\t]*)\t(.*)$/;
		my ($flag, $refpair, $summary) = ($1, $2, $3);
		# The remote side of the pair, which is the ref the remote holds or
		# refused.  A deletion writes an empty source side, so the pair still
		# splits in two and the second half is still the ref that matters.
		my @sides = split(/:/, $refpair, 2);
		$result->{ref}     = @sides > 1 ? $sides[1] : $sides[0];
		$result->{status}  = $status{$flag} // 'rejected';
		$result->{summary} = $summary;
		$result->{ok}      = 0 if $flag eq '!';
		$result->{reason}  = $1 if $summary =~ /\[[^\]]+\]\s*\((.+)\)\s*$/;
		last;
	}

	unless ($result->{ok}) {
		$result->{status} //= 'rejected';
		$result->{reason} ||= ($err // $out // '') =~ s/\s+$//r;
	}
	return $result;
}

# }}}
# _refuse_rewrite - the one refusal both append-only paths raise {{{
#
# D31 makes control and every deployment branch append-only on R, and two
# commands enforce that.  pipeline-apply checks the ancestry before it pushes,
# and the publish refuses a lease before it builds a refspec.  The sentence
# lives here so the two cannot come to word the same rule differently, since
# an operator can meet it on either command.
sub _refuse_rewrite {
	my ($branch, $remote) = @_;
	bail(
		"Refusing to push #C{%s}, because that would rewrite history on ".
		"#C{%s}.\n\n".
		"That branch is append-only, so recovery is a new commit that ".
		"restores the content and never a force push.",
		$branch, $remote
	);
}

# }}}
# push_append_only - publish a branch without ever rewriting its history {{{
#
# D31 makes control and every deployment branch append-only on R, so the
# previous tip is always an ancestor of the new tip and Genesis never
# force-pushes either class.  The push carries no force option of any kind,
# and the ancestry is checked against the remote's own tip first, so a
# refusal names the branch and says what the remedy is rather than leaving
# a rejected push to be read out of git's stderr.
#
# The remote is asked for the fully qualified ref rather than for the bare
# branch name, because ls-remote matches the tail of a ref and a bare name
# such as qa/bosh also matches the pull request branch pr/qa/bosh.
sub push_append_only {
	my ($self, $branch, %opts) = @_;

	my $remote = $opts{remote} // $self->default_remote
		or bail("No remote is configured, so #C{%s} cannot be published", $branch);

	my $local = $self->sha($branch);
	my ($out, $rc, $err) = run({dir => $self->{root}, passfail => 0},
		'git', 'ls-remote', '--heads', $remote, "refs/heads/$branch");
	bail("Failed to read #C{%s} on #C{%s}: %s",
		$branch, $remote, ($err || $out || "rc=$rc") =~ s/\s+$//r) if $rc;

	my $previous;
	for my $line (split /\n/, ($out // '')) {
		next unless $line =~ m{^([0-9a-f]{40})\s+refs/heads/(\S+)\s*$};
		next unless $2 eq $branch;
		$previous = $1;
		last;
	}

	_refuse_rewrite($branch, $remote)
		if $previous && !$self->is_ancestor($previous, $local);

	run({dir => $self->{root},
		onfailure => "Failed to push '$branch' to '$remote'"},
		'git', 'push', $remote, "refs/heads/$branch:refs/heads/$branch");

	return $local;
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
