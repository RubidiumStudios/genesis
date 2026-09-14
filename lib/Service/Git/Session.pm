package Service::Git::Session;

# The branch session: one object owns "leave the current branch, do work,
# come back", and nothing outside it switches branches.  It belongs to one
# Service::Git handle and so to one working tree, which is what keys I9.

use strict;
use warnings;

use Genesis qw/bail run trace/;
use Genesis::Exit qw/TEMPFAIL DATAERR/;
use Cwd qw/getcwd/;
use Fcntl qw/:flock/;
use IO::Handle;

### Constructor {{{

# new - build a session on one handle, without opening it {{{
#
# The control option is the branch abort never resets, which is I2 as D32
# revised it.  The session is told the name rather than reading it, because
# the accessor that knows it lands at M4 and the session is built at M5.
sub new {
	my ($class, $git, %opts) = @_;
	bail("A branch session needs a Service::Git handle") unless $git;
	return bless {
		git       => $git,
		control   => $opts{control},
		active    => 0,
		origin    => undef,
		on        => undef,
		switched  => {},
		lock      => undef,
	}, $class;
}

# }}}
# }}}

### Accessors {{{

# active - is this session open {{{
sub active { $_[0]->{active} }

# }}}
# origin - the branch, the HEAD sha, and the cwd begin recorded {{{
sub origin { $_[0]->{origin} }

# }}}
# on - the branch or commit the session last switched to {{{
sub on { $_[0]->{on} }

# }}}
# committed_branches - the branches whose tip moved since we switched to them {{{
#
# The writer lands at M8, so the session works out for itself what it wrote
# rather than being told.  A branch whose tip differs from the tip recorded
# at switch is one this session committed to, which is exactly the set D32
# has abort reset back to T.
sub committed_branches {
	my ($self) = @_;
	my $git = $self->{git};
	my $control = $self->{control} // '';
	return grep {
		my $now = eval { $git->sha($_) } // '';
		$_ ne $control && $now && $now ne ($self->{switched}{$_} // '');
	} sort keys %{$self->{switched}};
}

# }}}
# }}}

### The four verbs {{{

# begin - the pre-flight, the clean assertion, and the record {{{
#
# No lock is taken here.  The lock guards switching and switch takes it, so
# a command that opens a session and never switches never touches it.
sub begin {
	my ($self) = @_;
	my $git = $self->{git};

	# I9: within one working tree sessions are sequential and never nested.
	# A command that needs control after a deployment branch finishes the
	# first session before it begins the second.
	bail(
		"A branch session is already open in #C{%s}.\n\n".
		"Sessions are sequential and are never nested, so a command that ".
		"needs another branch finishes the open session first.",
		$git->root
	) if $self->{active};

	$git->preflight;

	# Clean means what is_clean means under D84: no tracked modification and
	# nothing staged, with untracked files ignored.  An operator's scratch
	# file blocks no session, and no session removes one.
	unless ($git->is_clean) {
		my $status = $git->status;
		my @dirty = sort grep {($status->{$_} // '') !~ /^\?\?/} keys %$status;
		bail(
			"Working tree has uncommitted changes, and this command switches ".
			"branches.\n\nCommit or stash them first:\n%s",
			join("", map {"  - $_\n"} @dirty)
		);
	}

	$self->{origin} = {
		branch => $git->current_branch,
		head   => $git->sha('HEAD'),
		cwd    => getcwd(),
	};
	$self->{active}   = 1;
	$self->{switched} = {};
	$self->_register_net;

	trace("Service::Git::Session: began on %s", $self->{origin}{branch});
	return $self;
}

# }}}
# switch - change to a branch or stand on a commit {{{
#
# Runs from the repository root, because the branch being checked out may
# not carry the directory we are standing in, and returns to that directory
# only if the checkout kept it.
#
# The lock is taken here and nowhere else, because D46 has it guard
# switching alone: a command that never switches never touches it, so a kit
# hook that shells out to genesis inside a deploy is unaffected while one
# that tries to switch under that deploy is refused by name.  The directory
# we came from is handed along, so a refusal stands us back where we were
# rather than leaving us at the root.
sub switch {
	my ($self, $target) = @_;
	my $git = $self->{git};
	bail("A branch change was attempted with no session open in %s.",
		$git->root) unless $self->{active};

	my $cwd = getcwd();
	chdir($git->root)
		or bail("Unable to enter git root %s: %s", $git->root, $!);

	$self->_take_lock($cwd);
	$git->checkout($target);
	chdir($cwd) if -d $cwd;

	$self->{on} = $target;
	$self->{switched}{$target} //= eval { $git->sha($target) };
	return $self;
}

# }}}
# finish - re-read, restore, verify, and release {{{
#
# Re-reads the branch and the cleanliness rather than assuming them, which
# is the restore clause of I7.  A tracked modification here is a defect and
# not a by-product under D84, because the deploy writes no git and the
# exodus store's own cleanup hands the tree back as it found it, so what is
# left is a kit hook that wrote into the repository or a deploy that died
# before cleaning up.  It takes the abort path, which names the files.
sub finish {
	my ($self) = @_;
	my $git = $self->{git};
	return $self unless $self->{active};

	unless ($git->is_clean) {
		my $status = $git->status;
		my @modified = sort grep {($status->{$_} // '') !~ /^\?\?/} keys %$status;
		return $self->abort(sprintf(
			"Something wrote into the repository during this command, which ".
			"it should not have done:\n%s\nThese changes are being discarded.",
			join("", map {"  - $_\n"} @modified)
		));
	}

	$self->_restore;
	$self->_release_lock;
	$self->{active} = 0;
	return $self;
}

# }}}
# abort - discard, reset, restore, verify, and die {{{
#
# D32 fixes what it reaches: every deployment branch this session committed
# to goes back to T, and control is never touched, because committed work on
# control in L is never discarded.  The discard reaches the index as well as
# the tree, which is H1, and it names the modified files before it throws
# them away so the evidence reaches the operator.  Nothing here removes an
# untracked file, so an operator's scratch file survives under D84.
sub abort {
	my ($self, $error) = @_;
	my $git = $self->{git};
	$error = 'the session was aborted' unless defined $error && length $error;
	$error =~ s/\s+$//;

	unless ($self->{active}) {
		bail("%s", $error);
	}
	$self->{active} = 0;

	# Name what is about to go, before it goes.
	my $status = $git->status;
	my @modified = sort grep {($status->{$_} // '') !~ /^\?\?/} keys %$status;
	Genesis::error("Discarding uncommitted changes in #C{%s}:\n%s",
		$git->root, join("", map {"  - $_\n"} @modified)) if @modified;

	my @reset = $self->committed_branches;
	my $restore_error;
	eval {
		chdir($git->root)
			or die sprintf("unable to enter the git root %s: %s\n",
				$git->root, $!);

		# The tree and the index both, which is the half the baseline
		# cleanup missed.
		run({ dir => $git->root, passfail => 1 },
			'git', 'reset', '--hard', 'HEAD');

		$self->_reset_to_remote($_) for @reset;
		$self->_restore;
		1;
	} or do {
		$restore_error = $@ || 'the restore failed for an unknown reason';
		$restore_error =~ s/\s+$//;
	};

	$self->_release_lock;

	# H2: a restore that fails is loud.  We are on the wrong branch, and
	# nothing a retry does moves us, so the operator is told all three
	# facts at once rather than discovering them one command later.
	bail(
		"%s\n\n".
		"We then failed to return to #C{%s}: %s\n\n".
		"You are standing on #C{%s}.  Put the working tree back by hand ".
		"before running anything else here.",
		$error, $self->{origin}{branch}, $restore_error,
		$git->current_branch // '<detached>'
	) if $restore_error;

	bail("%s", $error);
}

# }}}
# }}}

### Internals {{{

# _register_net - the last-resort abort, from an END block {{{
#
# RF12 put this here rather than in DESTROY.  bail exits when it is not
# inside an eval, Perl runs END before global destruction, and the order of
# destruction after that is undefined, so a net hung on DESTROY fires late
# or never.  at_exit hooks run from END, which is early enough to still
# have a working tree to put back.
#
# The hook is registered once per session and is a no-op on a session that
# finished, so an ordinary run pays nothing for it.
sub _register_net {
	my ($self) = @_;
	return $self if $self->{net};

	require Genesis::Commands;
	my $me = $self;
	Genesis::Commands::at_exit(sub {
		return unless $me->{active};

		# The hooks run from END with $? already holding the code the
		# command chose, and the process exits on whatever $? reads once
		# they are done.  The abort shells out to git several times, so
		# without this the net would hand every refusal git's nought and a
		# caller waiting on a switch would be told it succeeded.  It is
		# saved and put back by hand because the obvious localisation,
		# local $? = $?, loses the value: assigning a magic variable to its
		# own freshly localised self does not preserve it.  An explicit save
		# says what it does at the one point where getting it wrong is
		# invisible.
		my $status = $?;

		# Inside an END block there is nobody left to catch a die, so the
		# abort is wrapped and whatever it could not do is printed here.
		eval {
			$me->abort("the process exited with a branch session still open");
			1;
		} or do {
			my $err = $@ || 'the restore failed';
			$err =~ s/\s+$//;
			print STDERR "\n$err\n";
		};

		$? = $status;
	});

	$self->{net} = 1;
	return $self;
}

# }}}
# _take_lock - the flock D46 fixes, on genesis-session.lock {{{
#
# Per working tree, because git_dir resolves under .git/worktrees/<name>/
# in a linked working tree.  The pid and the command go inside so that the
# refusal can name a live holder, and there is no break-lock option: the
# kernel drops the flock when the holder dies, so an abandoned lock cannot
# arise and a refusal always names somebody who is still running.
#
# The pid is the first line and the command the second, which is the form
# every reader of this file already agrees on, so a command carrying spaces
# or a colon cannot be mistaken for part of the pid.
sub _take_lock {
	my ($self, $restore) = @_;
	return $self if $self->{lock};

	my $path = $self->{git}->git_dir . '/genesis-session.lock';
	open(my $fh, '+>>', $path)
		or bail("Unable to open the session lock at %s: %s", $path, $!);

	unless (flock($fh, LOCK_EX | LOCK_NB)) {
		my $holder = do { seek($fh, 0, 0); local $/; <$fh> } // '';
		close $fh;
		my ($pid, $command) = split /\n/, $holder, 2;
		chomp $command if defined $command;
		$pid = 'unknown' unless defined $pid && $pid =~ /^\d+$/;
		$command = 'an unknown command'
			unless defined $command && $command =~ /\S/;

		# I1 promises the directory we exit in is the one we came in on,
		# and a refusal is an exit, so we stand back where switch found us
		# before we say anything.
		chdir($restore) if defined $restore && -d $restore;

		bail({exitcode => TEMPFAIL},
			"Another Genesis process is using this working tree.\n\n".
			"  process %s is running: %s\n\n".
			"Only one session may switch branches in #C{%s} at a time.  Wait ".
			"for that command to finish and run this one again.",
			$pid, $command, $self->{git}->root);
	}

	truncate($fh, 0);
	seek($fh, 0, 0);
	print $fh sprintf("%d\n%s\n", $$, _command_line());
	$fh->flush;

	$self->{lock} = $fh;
	trace("Service::Git::Session: took the switch lock at %s", $path);
	return $self;
}

# }}}
# _release_lock - finish lets go, and nothing else does {{{
sub _release_lock {
	my ($self) = @_;
	my $fh = delete $self->{lock} or return $self;
	flock($fh, LOCK_UN);
	close $fh;
	return $self;
}

# }}}
# _command_line - what the refusal names the holder as {{{
sub _command_line {
	require Genesis::Commands;
	my $command = eval { Genesis::Commands::current_command() };
	return join(' ', 'genesis', grep {defined && length} ($command))
		if $command;
	return join(' ', $0, @ARGV);
}

# }}}
# _reset_to_remote - put one branch back at T {{{
#
# A ref write rather than a switch, so it takes no lock and needs no
# checkout.  The control branch never reaches here, because
# committed_branches is the set this session moved and it filters that name
# out of it.
sub _reset_to_remote {
	my ($self, $branch) = @_;
	my $git    = $self->{git};
	my $remote = $git->default_remote or return $self;
	my $t      = "refs/remotes/$remote/$branch";

	my ($tip) = run({ dir => $git->root, passfail => 0 },
		'git', 'rev-parse', '--verify', '--quiet', $t);
	chomp $tip if defined $tip;
	return $self unless $tip;

	# On the branch itself a ref write alone would leave the tree ahead of
	# HEAD, so a hard reset is what puts the two back together.
	if (($git->current_branch // '') eq $branch) {
		run({ dir => $git->root, onfailure => "Failed to reset $branch" },
			'git', 'reset', '--hard', $tip);
	} else {
		run({ dir => $git->root, onfailure => "Failed to reset $branch" },
			'git', 'update-ref', "refs/heads/$branch", $tip);
	}
	trace("Service::Git::Session: reset %s to %s", $branch, $t);
	return $self;
}

# }}}
# _restore - return to the branch begin recorded, from the root {{{
sub _restore {
	my ($self) = @_;
	my $git    = $self->{git};
	my $origin = $self->{origin} or return $self;

	chdir($git->root)
		or bail("Unable to enter git root %s: %s", $git->root, $!);
	$git->checkout($origin->{branch})
		unless ($git->current_branch // '') eq $origin->{branch};

	# The directory begin recorded may not exist on the branch we came back
	# to, and saying so beats landing somewhere the caller did not choose.
	if (-d $origin->{cwd}) {
		chdir($origin->{cwd})
			or bail("Unable to return to %s: %s", $origin->{cwd}, $!);
	} else {
		Genesis::info("The directory #C{%s} is gone, so we are at #C{%s}.",
			$origin->{cwd}, $git->root);
	}

	bail("Failed to return to #C{%s}: we are on #C{%s}.",
		$origin->{branch}, $git->current_branch // '<detached>')
		unless ($git->current_branch // '') eq $origin->{branch};

	return $self;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=0:noet
