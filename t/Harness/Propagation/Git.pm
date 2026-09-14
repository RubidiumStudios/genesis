package Harness::Propagation::Git;
# The Service::Git test subclass with a step counter.  A row arms one named
# step to die on its nth call, and every call is appended to a log so the row
# can assert that nothing else behaved differently.
use strict;
use warnings;

use JSON::PP;

our @ISA = ('Service::Git');

# The steps a row can arm.  Every one is a method the write sequence or the
# refresh takes, so a row names a git step rather than a shell command.
our @STEPS = qw/
	checkout checkout_file add rm commit create_branch
	fetch_branch fetch_branches push delete_remote_branch reset_working_tree
/;

# import - install the subclass over Service::Git for a spawned command {{{
#
# A row that runs a whole command cannot hand an object to the child, so the
# child loads this module through PERL5OPT and we make Service::Git->new
# answer with a subclass instance.  Nothing under lib/ changes.
sub import {
	my ($class) = @_;
	return unless $ENV{GENESIS_HARNESS_GIT_PLAN};
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
	print $fh JSON::PP->new->canonical->encode([$step, map {_as_text($_)} @args]), "\n";
	close $fh;
	return;
}

# }}}
# _as_text - one argument as the log holds it {{{
sub _as_text {
	my ($arg) = @_;
	return undef unless defined $arg;
	return [map {_as_text($_)} @$arg] if ref($arg) eq 'ARRAY';
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
sub _bump {
	my ($self, $step) = @_;
	my $file = $ENV{GENESIS_HARNESS_GIT_PLAN} or return (0, undef);
	my $plan = $self->_plan;
	my $n = ++$plan->{_counts}{$step};
	open my $fh, '>', $file or return ($n, $plan->{$step});
	print $fh JSON::PP->new->canonical->encode($plan);
	close $fh;
	return ($n, $plan->{$step});
}

# }}}

1;
