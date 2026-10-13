#!/usr/bin/env perl
# Proves D115's prompt timeouts as noted on 2026-10-07 and 2026-10-13: a
# prompt asked while a run holds the switch lock gives up when its time is up,
# rather than holding the clone for a terminal nobody is at, and the time is
# ten minutes unless GENESIS_PROMPT_TIMEOUT names another number of seconds.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Output;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

use_ok 'Genesis::UI';

subtest 'a prompt nobody answers gives up when its time is up' => sub {
	plan tests => 2;

	my $answer  = 'unanswered';
	my $started = time;
	output_from {
		$answer = eval {
			with_silent_stdin(sub {
				no warnings 'once';
				local $Genesis::UI::PROMPT_TIMEOUT = 1;
				Genesis::UI::prompt_for_boolean("Proceed? [y|n]", 0);
			});
		} // ($@ ? "died: $@" : undef);
	};

	ok(!defined $answer, 'it answers nothing') or diag($answer);
	cmp_ok(time - $started, '<', 5, 'within its time, not the guard');
};

subtest 'the time is ten minutes unless the environment says otherwise' => sub {
	plan tests => 2;

	local $ENV{GENESIS_PROMPT_TIMEOUT};
	delete $ENV{GENESIS_PROMPT_TIMEOUT};
	is(eval {Genesis::UI::prompt_timeout()}, 600, 'ten minutes by default');
	$ENV{GENESIS_PROMPT_TIMEOUT} = 7;
	is(eval {Genesis::UI::prompt_timeout()}, 7,
		'or the seconds GENESIS_PROMPT_TIMEOUT names');
};

done_testing;
