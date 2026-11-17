#!/usr/bin/env perl
# Proves the raise half of T493: what bail dies with inside an eval keeps the
# exit code it was given, and a caller that raises the error again with
# context exits the code the first raise set (D163, D168).
#
# Outside an eval bail exits with its code and always has.  Inside one it
# died with a string, so the code stopped at the eval: a reader that named
# NOPERM for a refusal was caught by a caller that could only say
# UNAVAILABLE for whatever it had caught.
#
# The rows read what a caller can ask a caught error, that the error still
# reads as the text it always was, and what a process exits with when the
# error is raised again, with context and bare.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis;
use Genesis::Exit qw/NOPERM UNAVAILABLE CONFIG DATAERR/;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

# Carp::Always, which the helper may load, appends a stack trace to a string
# die; these rows are about what bail itself raises
local $SIG{__DIE__} = 'DEFAULT';

# What a process running this code exits with, and what it says.  The code
# runs under a bare perl with the handler bin/genesis installs, since an exit
# code is only a fact about a process.
sub in_a_process {
	my ($code) = @_;
	my $script = workdir('bail-raised').'/run.pl';
	put_file($script, join("\n",
		'use strict; use warnings;',
		'use Genesis;',
		'use Genesis::Exit qw/NOPERM UNAVAILABLE CONFIG DATAERR/;',
		'$SIG{__DIE__} = \&Genesis::uncaught;',
		$code, ''));
	my $said = qx(NOCOLOR=1 GENESIS_OUTPUT_COLUMNS=80 $^X -Ilib $script 2>&1);
	return ($? >> 8, $said);
}

subtest 'inside an eval, bail raises an error a caller can ask' => sub {
	plan tests => 9;

	eval { bail({exitcode => CONFIG}, "No such kit #C{%s}", 'omega') };
	my $caught = $@;
	my $raised = raised($caught);
	ok($raised, 'raised answers the error for what bail died with');
	is($raised->exitcode, CONFIG, 'which names the exit code bail was given');
	is($raised->state, 'error', 'and the plain error state, bail having been given none');
	is($raised->msg, 'No such kit #C{omega}', 'its message is the one written, markup and all');

	eval { bail("Something else") };
	is(raised($@)->exitcode, undef, 'a bail given no code raises an error that names none');

	eval { bail({state => 'refused'}, "The vault refused") };
	is(raised($@)->state, 'refused', 'a bail given a state raises an error in that state');
	is(raised($@)->exitcode, NOPERM, 'with the code the state earns');

	is(raised("a plain die\n"), undef, 'raised answers undef for a plain die');
	is(raised(undef), undef, 'and for nothing at all');
};

subtest 'as a string the error is its sentence, and the block is asked for' => sub {
	plan tests => 5;

	eval { bail("Could not read #C{%s} from vault at #M{%s}: %s", 'secret/a', 'https://v', 'sealed') };
	my $caught = $@;
	is("$caught", 'Could not read secret/a from vault at https://v: sealed',
		'as a string it is what bail said, with no prefix and no wrap');
	ok($caught, 'and is true in a condition');
	my $block = raised($caught)->rendered;
	like($block, qr/\A\n\[FATAL\] Could not read secret\/a from vault at https:\/\/v: sealed\n\n\z/,
		'rendered is the block bail prints: a blank line, the prefix, a blank line');
	is(scalar(() = $block =~ /\[FATAL\]/g), 1, 'with one prefix');

	local $ENV{GENESIS_OUTPUT_COLUMNS} = 40;
	like(raised($caught)->rendered, qr/\n {8}\S/, 'and it is wrapped to the terminal it is asked for at');
};

subtest 'an error raised again with context keeps the code the first raise set' => sub {
	plan tests => 9;

	my $reader = sub { bail({state => 'refused'}, "Could not read #C{secret/a}") };

	eval { eval { $reader->() }; bail("While checking the record: %s", $@) };
	is(raised($@)->exitcode, NOPERM, 'a caller that names no code raises the reader\'s');
	is(raised($@)->state, 'refused', 'and its state');
	is("$@", 'While checking the record: Could not read secret/a', 'under its own words, as one sentence');
	is(raised($@)->msg, 'While checking the record: Could not read #C{secret/a}',
		'the reader\'s message goes in as it was written, to be coloured once');
	is(scalar(() = raised($@)->rendered =~ /\[FATAL\]/g), 1, 'and the two are one block, under one prefix');

	eval { eval { $reader->() }; bail({exitcode => UNAVAILABLE}, "While checking the record: %s", $@) };
	is(raised($@)->exitcode, NOPERM, 'a caller that names a code of its own still raises the reader\'s');

	eval { eval { bail("a plain failure") }; bail({exitcode => UNAVAILABLE}, "While checking: %s", $@) };
	is(raised($@)->exitcode, UNAVAILABLE, 'where the first raise named none, the caller\'s code stands');

	eval { eval { die "a library died\n" }; bail({exitcode => DATAERR}, "While checking: %s", $@) };
	is(raised($@)->exitcode, DATAERR, 'and so it does over a plain die');

	eval { eval { $reader->() }; my $text = "$@"; bail({exitcode => UNAVAILABLE}, "While checking: %s", $text) };
	is(raised($@)->exitcode, UNAVAILABLE, 'an error passed on as text carries nothing, which is why it is passed whole');
};

subtest 'a process exits with the code the first raise set' => sub {
	plan tests => 8;

	my ($exit, $said) = in_a_process(
		'eval { bail({state => "refused"}, "Could not read the record") }; bail("While checking: %s", $@);');
	is($exit, NOPERM, 'raised again with context, outside any eval');
	like($said, qr/While checking:.*Could not read the record/s, 'saying both');

	($exit, $said) = in_a_process(
		'eval { bail({state => "refused"}, "Could not read the record") }; die $@;');
	is($exit, NOPERM, 'raised again bare, with die');
	is(scalar(() = $said =~ /\[FATAL\]/g), 1, 'saying it once');

	($exit, $said) = in_a_process(
		'eval { bail("a plain failure") }; die $@;');
	is($exit, 1, 'an error that names no code, raised again bare, exits 1');

	($exit, $said) = in_a_process('bail({exitcode => CONFIG}, "No such kit");');
	is($exit, CONFIG, 'and a bail outside any eval exits its own code, as it always did');

	($exit, $said) = in_a_process('bail({state => "invalid"}, "Not a record");');
	is($exit, DATAERR, 'or the code its state earns');

	($exit, $said) = in_a_process('die "a library died\n";');
	like($said, qr/a library died/, 'a plain die nobody caught still dies as perl has it');
};

done_testing;
