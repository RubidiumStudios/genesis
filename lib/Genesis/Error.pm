package Genesis::Error;
# What bail dies with inside an eval: its message, and with it the kind of
# failure and the exit code that earns, so a caller that catches the error
# can keep both (D163).
#
# It holds the message as written and nothing rendered from it.  As a string
# it is that message as a plain sentence, and the block an operator is shown,
# with its prefix and its wrap, is made from it where it is printed.
#
# The names are the ones plans/genesis-result-module.md proposes for
# Genesis::Result, which is to replace this class, so a caller written
# against it needs no change when it does (D168).
use strict;
use warnings;

use Genesis::Exit qw/NOPERM UNAVAILABLE DATAERR/;
use Genesis::Term qw/csprintf wrap terminal_width decolorize/;

# Only the string form and the append are overloaded.  Concatenation falls
# back to the string form, so "context: $error" is a plain string; a
# concatenation that answered an object would hand one to every caller that
# interpolates a caught error, and an encoder given one refuses it.
use overload
	'""' => sub {$_[0]->sentence},
	'.=' => sub {$_[0]->with_more($_[1])},
	fallback => 1;

### The states {{{

# A state that names why a read failed earns a code by being that state.
# Any other state exits with what the raise gave it, or as a plain error.
my %EXIT_FOR = (
	refused     => NOPERM,
	unreachable => UNAVAILABLE,
	unread      => UNAVAILABLE,
	invalid     => DATAERR,
);

# }}}

### Constructor {{{

# new - an error with its message, its state, and the code it exits with {{{
sub new {
	my ($class, %args) = @_;
	# A plain die: bail builds one of these, so it cannot be asked to say so.
	die "Genesis::Error needs a msg, and was given none\n"
		unless defined $args{msg};

	my $state = $args{state} // 'error';
	return bless({
		state    => $state,
		msg      => $args{msg},
		exitcode => $args{exitcode} // $EXIT_FOR{$state},
		data     => $args{data} // {},
	}, $class);
}

# }}}
# with_more - the same error with more said after its message {{{
sub with_more {
	my ($self, $more) = @_;
	# A new one, so a copy somebody kept of this error says what it said.
	return bless({%$self, msg => $self->{msg}.($more // '')}, ref $self);
}

# }}}
# }}}

### Its forms {{{

# sentence - the message in plain words, which is what it is as a string {{{
sub sentence {
	# Laid out at a width nothing reaches, so the layout marks a message
	# may carry become the indent they stand for and no line is broken.
	return decolorize(wrap($_[0]{msg}, 100_000));
}

# }}}
# rendered - the block an operator is shown: the prefix, wrapped to the terminal {{{
sub rendered {
	return "\n".csprintf("%s", wrap($_[0]{msg}."\n", terminal_width, "#r{[FATAL]} "))."\n";
}

# }}}
# }}}

### Accessors {{{

sub state    { $_[0]{state} }
sub msg      { $_[0]{msg} }
sub exitcode { $_[0]{exitcode} }
sub data     { $_[0]{data} }
sub data_for { $_[0]{data}{$_[1]} }

# message_or - the message, or what the caller gave where there is none {{{
sub message_or {
	return length($_[0]{msg}) ? $_[0]{msg} : $_[1];
}

# }}}
# }}}

### Predicates {{{

sub is_ok       { 0 }
sub is_warning  { 0 }
sub is_passable { 0 }
sub is_fatal    { 1 }
sub is_error    { $_[0]{state} eq 'error' ? 1 : 0 }

sub is_refused     { $_[0]{state} eq 'refused'     ? 1 : 0 }
sub is_unreachable { $_[0]{state} eq 'unreachable' ? 1 : 0 }
sub is_unread      { $_[0]{state} eq 'unread'      ? 1 : 0 }
sub is_invalid     { $_[0]{state} eq 'invalid'     ? 1 : 0 }

# is_unreadable - whether a read did not finish, for whichever reason {{{
sub is_unreadable {
	return $_[0]{state} =~ /^(?:refused|unreachable|unread)$/ ? 1 : 0;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
