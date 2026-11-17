#!/usr/bin/env perl
# Proves the carrier half of T493: an error that reads as the text it was
# raised with and still says what kind of failure it was and which exit code
# that earns (D163, D168).
#
# bail dies with a plain string inside an eval, so the code it was given
# never reached the caller that caught it.  This class is what it dies with
# instead.  It is written to the interface plans/genesis-result-module.md
# proposes for Genesis::Result, which replaces it after the MVP, so the rows
# hold the names a caller asks it by as well as what it answers.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Exception;

use Genesis::Exit qw/NOPERM UNAVAILABLE DATAERR CONFIG/;
use_ok 'Genesis::Error';

# Carp::Always, which the helper may load, appends a stack trace to a string
# die; the rows here are about what the class itself carries
local $SIG{__DIE__} = 'DEFAULT';

sub refused {
	return Genesis::Error->new(
		state => 'refused',
		msg   => 'Could not read #C{secret/a} from vault',
		text  => "\n[FATAL] Could not read secret/a from\n        vault\n\n",
		@_,
	);
}

subtest 'it reads as the text it was raised with' => sub {
	plan tests => 7;
	my $e = refused();
	is("$e", "\n[FATAL] Could not read secret/a from\n        vault\n\n", 'as a string it is the rendered text');
	like($e, qr/Could\s+not\s+read\s+secret\/a/, 'so a pattern matches it as it matched the string');
	ok($e, 'it is true in a condition');
	is($e, "$e", 'and equal to its own text');
	is($e->msg, 'Could not read #C{secret/a} from vault', 'msg is the message as it was written, markup and all');
	is($e->text, "$e", 'text is the rendered form by name');
	is(Genesis::Error->new(msg => 'plain')."", 'plain', 'with no rendered text given, it reads as its message');
};

subtest 'it answers its state through the names Genesis::Result uses' => sub {
	plan tests => 11;
	my $e = refused();
	is($e->state, 'refused', 'state is the cause');
	is($e->is_fatal, 1, 'a raised error is fatal');
	is($e->is_passable, 0, 'and never passable');
	is($e->is_ok, 0, 'nor ok');
	is($e->is_warning, 0, 'nor a warning');
	is($e->is_error, 0, 'is_error is the plain error state, which a refusal is not');
	is(Genesis::Error->new(msg => 'x')->state, 'error', 'a state not given is error');
	is(Genesis::Error->new(msg => 'x')->is_error, 1, 'and is_error answers yes for it');
	is_deeply($e->data, {}, 'data is an empty set when none is given');
	is(refused(data => {path => 'secret/a'})->data_for('path'), 'secret/a', 'data_for reads one key of it');
	is($e->message_or('fallback'), $e->msg, 'message_or answers the message where there is one');
};

subtest 'each failed-read state has a predicate of its own, and an exit code' => sub {
	my %states = (
		refused     => [NOPERM,      'is_refused'],
		unreachable => [UNAVAILABLE, 'is_unreachable'],
		unread      => [UNAVAILABLE, 'is_unread'],
		invalid     => [DATAERR,     'is_invalid'],
	);
	plan tests => 4 * keys(%states) + 3;
	for my $state (sort keys %states) {
		my ($code, $predicate) = @{$states{$state}};
		my $e = Genesis::Error->new(state => $state, msg => 'x');
		is($e->$predicate, 1, "$predicate answers yes for $state");
		is(scalar(grep {$e->$_} map {$states{$_}[1]} grep {$_ ne $state} keys %states), 0,
			"and no other state's predicate does");
		is($e->exitcode, $code, "$state exits $code where the raise named no code");
		is($e->is_unreadable, ($state eq 'invalid' ? 0 : 1),
			$state eq 'invalid' ? 'an invalid record was read, so it is not unreadable'
			                    : "$state is one of the ways a read does not finish");
	}
	is(Genesis::Error->new(msg => 'x')->exitcode, undef, 'a plain error names no code of its own');
	is(Genesis::Error->new(msg => 'x', exitcode => CONFIG)->exitcode, CONFIG, 'unless the raise gave it one');
	is(Genesis::Error->new(state => 'refused', msg => 'x', exitcode => CONFIG)->exitcode, CONFIG,
		'and a code the raise gave outranks the one its state would earn');
};

subtest 'it survives being raised again, and not being rewritten' => sub {
	plan tests => 5;
	eval { eval { die refused() }; die $@ };
	isa_ok($@, 'Genesis::Error', 'an error raised again as it was caught');
	is($@->exitcode, NOPERM, 'and it still names its code');

	my $e = refused();
	is(ref(sprintf('%s', $e)), '', 'put through a format it is a plain string');
	is(ref($e =~ s/\s+$//r), '', 'and so is a trimmed copy of it');
	isa_ok($e, 'Genesis::Error', 'the error itself, after both');
};

subtest 'a message is required, and the class does not raise through bail' => sub {
	plan tests => 2;
	throws_ok { Genesis::Error->new(state => 'refused') } qr/Genesis::Error needs a msg/,
		'a new error with no message says so';
	is(ref($@), '', 'as a plain die, since bail would build one of these to say it');
};

done_testing;
