package Harness::Propagation::Git;
# The Service::Git test subclass with a step counter.  A row arms one named
# step to die on its nth call, and every call is appended to a log so the row
# can assert that nothing else behaved differently.
use strict;
use warnings;

use Fcntl qw/:flock/;
use JSON::PP;
use Harness::GitEnv;

our @ISA = ('Service::Git');

# The steps a row can arm.  Every one is a method the write sequence or the
# refresh takes, so a row names a git step rather than a shell command.
#
# ls_files is the one reader among them.  The writer asks it what the branch
# holds before it stages anything and again for the postcondition, and it
# refuses with a plain message rather than with the run-fatal class, so it is
# the step a row arms to shape a failure one environment survives.
our @STEPS = qw/
	checkout checkout_file add rm commit create_branch ls_files
	fetch_branches push
/;

# import - install the subclass over Service::Git for a spawned command {{{
#
# A row that runs a whole command cannot hand an object to the child, so the
# child loads this module through PERL5OPT and we make Service::Git->new
# answer with a subclass instance.  Nothing under lib/ changes.
sub import {
	my ($class) = @_;
	return unless $ENV{GENESIS_HARNESS_GIT_PLAN};

	# This runs in a spawned command, which is where an armed fault shells
	# out to git of its own.  The parent scrubbed before it built anything,
	# so there should be nothing left to take, and a child that says so for
	# itself costs one call and owes the parent nothing.
	scrub_git_env();

	require Service::Git;
	no strict 'refs';
	no warnings 'redefine';
	my $original = \&Service::Git::new;
	*{'Service::Git::new'} = sub {
		my (undef, @args) = @_;
		my $self = $original->('Service::Git', @args);
		return bless $self, $class;
	};
	return;
}

# }}}
# _plan - the armed faults, re-read each call so a row can arm mid-run {{{
sub _plan {
	my ($self) = @_;
	my $file = $ENV{GENESIS_HARNESS_GIT_PLAN} or return {};
	return {} unless -f $file;
	open my $fh, '<', $file or return {};
	my $json = do {local $/; <$fh>};
	close $fh;
	return eval {JSON::PP->new->decode($json)} || {};
}

# }}}
# _record - append one call to the step log {{{
#
# The arguments are written as text so a row can read them back, and an
# argument the caller left out stays a hole rather than becoming the empty
# string, because several steps take an optional remote and a row weighs how
# many arguments the call really carried.
sub _record {
	my ($self, $step, @args) = @_;
	my $file = $ENV{GENESIS_HARNESS_GIT_LOG} or return;
	open my $fh, '>>', $file or return;

	# The lock is held for the write, because a spawned command appends to
	# the same log as the process that spawned it, and two lines that
	# interleave leave a reader decoding half of each.
	unless (flock($fh, LOCK_EX)) {
		close $fh;
		return;
	}
	seek($fh, 0, 2);
	print $fh JSON::PP->new->canonical->encode([$step, map {_as_text($_)} @args]), "\n";
	close $fh;
	return;
}

# }}}
# _as_text - one argument as the log holds it {{{
#
# A plain hash is carried through key by key rather than stringified, because
# push takes its refs as a list of specs and a row that wants to know what one
# branch was leased against has nowhere else to read it.  A key the caller left
# out stays out, and a key whose value is undef stays undef, so a row can tell
# a spec that named no expected tip from one that named none deliberately.
# Anything blessed still stringifies, since it is an object and not a record.
sub _as_text {
	my ($arg) = @_;
	return undef unless defined $arg;
	return [map {_as_text($_)} @$arg] if ref($arg) eq 'ARRAY';
	return {map {($_ => _as_text($arg->{$_}))} keys %$arg}
		if ref($arg) eq 'HASH';
	return "$arg";
}

# }}}
# _hits - whether an armed fault fires on this call {{{
#
# A plain arming names the one call it wants, and `from` makes every call from
# the nth onward the one it wants, which is how a severed remote stays severed.
sub _hits {
	my ($armed, $n) = @_;
	return $armed->{from} ? ($n >= $armed->{n}) : ($n == $armed->{n});
}

# }}}
# _fault - what an armed fault does when it fires {{{
#
# One branch per kind of fault, so a later kind is a branch here rather than a
# rewrite of the wrappers below.  A branch answers with what the step should
# return, and a branch that dies never returns at all.
sub _fault {
	my ($self, $step, $n, $armed) = @_;
	my $kind = $armed->{kind} // 'fail';

	die(($armed->{message} // "the harness failed $step on call $n") . "\n")
		if $kind eq 'fail';

	# 'transport' answers the way the real method answers a remote it cannot
	# reach, which is a classified result and not a death.  fetch_branches
	# never dies on the remote: `git ls-remote` failing is an rc it turns into
	# {ok => 0, kind => ...}, and the caller composes its refusal out of that
	# kind.  A double that died there could not reach the classifier the
	# refusal is written from, so the one shape the product has for an
	# unreachable remote would have been unprovable through a whole command.
	# The real classifier is asked, so the double reports the kind the product
	# would report for the same stderr rather than a kind of its own.
	#
	# The five keys beside it are copied from Service::Git::fetch_branches,
	# which composes this same shape on both of its failure paths.  A row in
	# t/unit-tests/harness_propagation-faults.t reads a real failure out of
	# that sub and holds this answer to the same keys, so a key added there
	# cannot leave this one answering a shape the product never produces.
	if ($kind eq 'transport') {
		require Service::Git;
		my $err = ($armed->{message} // "the harness severed $step on call $n")."\n";
		my $result = {
			ok      => 0,
			kind    => Service::Git::_classify_remote_error($err),
			err     => $err,
			fetched => [],
			created => [],
			absent  => [],
		};
		return wantarray ? ($self, $result) : $self;
	}

	die "the harness does not know the fault kind '$kind'\n";
}

# }}}
# _act - the command an armed entry runs before the step goes through {{{
#
# An action is not a fault, so the step still happens and the wrapper goes on
# to delegate.  A row arms one to have a teammate move a branch on R at the
# step the row names, in the middle of this run, so the push the run then makes
# is rejected rather than absorbed by the run's own refresh.
sub _act {
	my ($armed) = @_;
	require Genesis;
	Genesis::run({dir => $armed->{in}}, 'git', @{$armed->{action}});
	return;
}

# }}}
# Install one counting wrapper per step {{{
#
# Each wrapper logs the call, counts it, consults the plan, and otherwise
# delegates to SUPER:: so the real work still happens.  A step nobody armed
# behaves exactly as it does without the subclass, which is what lets a row
# assert that no other git step behaved differently.  An entry carrying an
# action runs that command at the armed call and then delegates as it always
# would, where a fault never returns at all.
#
# The call is logged before it is delegated, and before the plan is consulted,
# so a step the plan fails is in the log as surely as one that went through,
# and a step that calls another step stands above the steps it calls rather
# than below it.  That is why a commit carrying files reads as commit and then
# add, which is the outer call first rather than the order the work finished
# in.
#
# An entry carrying a skip returns without delegating, so the step is reported
# in the log and its write never lands.  T119 needs that shape, because a
# death is not a silence and a fault cannot make one.
{
	no strict 'refs';
	for my $step (@STEPS) {
		*{__PACKAGE__ . "::$step"} = sub {
			my ($self, @args) = @_;
			$self->_record($step, @args);

			my ($n, $armed) = $self->_bump($step);
			if ($armed && _hits($armed, $n)) {
				return defined $armed->{return} ? $armed->{return} : 1
					if $armed->{skip};
				return $self->_fault($step, $n, $armed) unless $armed->{action};
				_act($armed);
			}

			my $super = "SUPER::$step";
			return $self->$super(@args);
		};
	}
}

# }}}
# _bump - count this call, persist the count, and return the armed fault {{{
#
# The count lives in the plan file rather than on the object, because a
# spawned command builds its own handle and the count has to survive the
# process boundary.  Counting and reading the fault happen together so the
# two cannot disagree about which call this is.
#
# The read, the increment, and the write are all under one exclusive lock,
# because the parent arms through this same file while a spawned command
# counts through it, and two unlocked read-modify-writes lose one another's
# change.  The parent takes the same lock when it arms.
sub _bump {
	my ($self, $step) = @_;
	my $file = $ENV{GENESIS_HARNESS_GIT_PLAN} or return (0, undef);

	my $fh;
	unless (open $fh, '+<', $file) {
		open $fh, '+>', $file or undef $fh;
	}
	undef $fh if $fh && !flock($fh, LOCK_EX);
	unless ($fh) {
		my $plan = $self->_plan;
		my $n = ++$plan->{_counts}{$step};
		return ($n, $plan->{$step});
	}

	my $json = do {local $/; <$fh>};
	my $plan = eval {JSON::PP->new->decode($json // '')} || {};
	my $n = ++$plan->{_counts}{$step};
	seek($fh, 0, 0);
	truncate($fh, 0);
	print $fh JSON::PP->new->canonical->encode($plan);
	close $fh;
	return ($n, $plan->{$step});
}

# }}}

1;
