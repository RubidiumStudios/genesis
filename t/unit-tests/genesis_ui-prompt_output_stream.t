#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Output;

# Where a prompt writes.  Questions, menus, and banners go to STDERR and to
# the controlling terminal, never to STDOUT, so a caller can pipe the
# command's output into a parser without a menu landing in it.  When there is
# no terminal to show the question on, the command stops with a message
# instead of waiting on an answer nobody was asked for.

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

use_ok 'Genesis::UI';

subtest 'prompt_for_choice writes its menu to standard error' => sub {
	plan tests => 5;

	set_stdin("2\n");
	my ($result, $out, $err);
	($out, $err) = output_from {
		$result = prompt_for_choice("Pick a color:", [qw(red green blue)]);
	};
	reset_stdin();

	is($result, 'green', 'the second item is selected');
	is($out, '', 'nothing is written to standard output');
	like($err, qr/Pick a color:/, 'the banner is on standard error');
	like($err, qr/1\) red.*2\) green.*3\) blue/s, 'the menu is on standard error');
	like($err, qr/Select choice/, 'the question is on standard error');
};

subtest 'prompt_for_choice keeps its default marker and echo off standard output' => sub {
	plan tests => 3;

	set_stdin("\n");
	my ($result, $out, $err);
	($out, $err) = output_from {
		$result = prompt_for_choice("Pick:", [qw(a b c)], 'b');
	};
	reset_stdin();

	is($result, 'b', 'the default is selected on an empty answer');
	is($out, '', 'nothing is written to standard output');
	like($err, qr/\(default\)/, 'the default marker is on standard error');
};

subtest 'prompt_for_choice section headers stay off standard output' => sub {
	plan tests => 3;

	set_stdin("1\n");
	my ($result, $out, $err);
	($out, $err) = output_from {
		$result = prompt_for_choice(
			"Pick:", [qw(a b c)], undef, ['---Group One---', 'First', 'Second', 'Third']
		);
	};
	reset_stdin();

	is($result, 'a', 'the first item after the header is selected');
	is($out, '', 'nothing is written to standard output');
	like($err, qr/Group One/, 'the section header is on standard error');
};

subtest 'the other prompts keep standard output clean too' => sub {
	plan tests => 4;

	my ($out, $err);

	set_stdin("1\n\n");
	($out, $err) = output_from { prompt_for_choices("Pick some:", [qw(a b c)]) };
	reset_stdin();
	is($out, '', 'prompt_for_choices writes nothing to standard output');

	set_stdin("hello\n");
	($out, $err) = output_from { prompt_for_line("Say something", "word", undef) };
	reset_stdin();
	is($out, '', 'prompt_for_line writes nothing to standard output');

	set_stdin("one\n\n");
	($out, $err) = output_from { prompt_for_list('line', "List some", "item") };
	reset_stdin();
	is($out, '', 'prompt_for_list writes nothing to standard output');

	set_stdin("y\n");
	($out, $err) = output_from { prompt_for_boolean("Continue? [y|n]", 1) };
	reset_stdin();
	is($out, '', 'prompt_for_boolean writes nothing to standard output');
};

subtest 'no terminal to ask on stops the command' => sub {
	plan tests => 3;
	no warnings 'redefine';
	local *Genesis::UI::__prompt_needs_terminal_copy = sub { 1 };
	local *Genesis::UI::__open_controlling_terminal  = sub { undef };

	set_stdin("2\n");
	throws_ok {
		output_from { prompt_for_choice("Pick:", [qw(red green blue)]) }
	} qr/Cannot reach a terminal to ask a question/, 'the command stops rather than asking';
	throws_ok {
		output_from { prompt_for_choice("Pick:", [qw(red green blue)]) }
	} qr/standard error attached to a terminal, or use --yes/, 'the message says how to proceed';
	my $unread = <STDIN>;
	reset_stdin();
	is($unread, "2\n", 'nothing was read from standard input');
};

subtest 'exhausted standard input with no terminal stops the command' => sub {
	plan tests => 3;

	# No terminal is attached and standard input is empty, so no answer is
	# ever coming; the prompt stops instead of looping on a closed pipe.
	set_stdin("");
	my ($out, $err);
	($out, $err) = output_from {
		eval { prompt_for_choice("Pick:", [qw(red green blue)]) };
	};
	my $failure = $@;
	reset_stdin();

	like($failure, qr/Cannot read an answer/, 'the command stops when nobody can answer');
	like($failure, qr/no terminal is attached/, 'the message says why');
	is($out, '', 'nothing is written to standard output');
};

subtest 'a terminal copy is written when standard error is redirected' => sub {
	plan tests => 3;
	no warnings 'redefine';

	# __prompt_print opens and closes the terminal on every call, so the mock
	# hands back a fresh handle onto the same buffer each time it is asked.
	my $tty_text = '';
	local *Genesis::UI::__prompt_needs_terminal_copy = sub { 1 };
	local *Genesis::UI::__open_controlling_terminal  = sub {
		open(my $fh, '>>', \$tty_text) or die "cannot open an in-memory terminal: $!";
		return $fh;
	};

	set_stdin("2\n");
	my ($result, $out, $err);
	($out, $err) = output_from {
		$result = prompt_for_choice("Pick a color:", [qw(red green blue)]);
	};
	reset_stdin();

	is($result, 'green', 'the second item is selected');
	is($out, '', 'nothing is written to standard output');
	like($tty_text, qr/Pick a color:.*1\) red.*2\) green.*Select choice/s,
		'the banner, the menu, and the question all reach the terminal');
};

done_testing;
