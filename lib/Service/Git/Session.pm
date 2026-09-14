package Service::Git::Session;

# The branch session: one object owns "leave the current branch, do work,
# come back", and nothing outside it switches branches.  It belongs to one
# Service::Git handle and so to one working tree, which is what keys I9.

use strict;
use warnings;

use Genesis qw/bail trace/;
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
	return grep {
		my $now = eval { $git->sha($_) } // '';
		$now && $now ne ($self->{switched}{$_} // '');
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

	# RF12: DESTROY is the wrong place for the safety net, because bail
	# exits outside an eval and Perl runs END before global destruction,
	# after which the order is undefined.  at_exit runs from END.  The task
	# that adds abort replaces this restore with the full discard and reset.
	unless ($self->{net}) {
		require Genesis::Commands;
		my $me = $self;
		Genesis::Commands::at_exit(sub {
			return unless $me->{active};

			# The hooks run from END with $? already holding the code the
			# command chose, and the process exits on whatever $? reads
			# once they are done.  The restore shells out to git, so
			# without this the net would hand every refusal git's nought
			# and a caller waiting on a switch would be told it succeeded.
			# It is saved and put back by hand because the obvious
			# localisation, local $? = $?, loses the value: assigning a
			# magic variable to its own freshly localised self does not
			# preserve it.  An explicit save says what it does at the one
			# point where getting it wrong is invisible.
			my $status = $?;

			$me->{active} = 0;
			eval { $me->_restore; 1 } or print STDERR "\n$@\n";
			$? = $status;
		});
		$self->{net} = 1;
	}

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
# finish - re-read, restore, and verify {{{
#
# Re-reads the branch and the cleanliness rather than assuming them, which
# is the restore clause of I7.  A tracked modification here is a defect and
# not a by-product under D84, and the task that adds abort routes it there.
sub finish {
	my ($self) = @_;
	my $git = $self->{git};
	return $self unless $self->{active};

	bail("The working tree in %s holds changes at the end of a session.",
		$git->root) unless $git->is_clean;

	$self->_restore;
	$self->_release_lock;
	$self->{active} = 0;
	return $self;
}

# }}}
# }}}

### Internals {{{

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
