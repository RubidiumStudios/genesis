#!/usr/bin/env perl
use strict;
use warnings;

# The deploy path's yes/no questions: --yes answers them, a controlling
# terminal asks them, and anything else stops with a message that says how
# to proceed, instead of waiting on a question written into a pipe.

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Output;

use Genesis;
use_ok 'Genesis::Commands::Env';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

my $question = "Upload the new cloud config to the BOSH director? [y|n]";

subtest '--yes answers without asking' => sub {
	plan tests => 2;
	no warnings 'redefine';
	local *Genesis::Commands::Env::in_controlling_terminal = sub { die "must not be consulted\n" };
	my ($result, $out, $err);
	($out, $err) = output_from { $result = Genesis::Commands::Env::_deploy_confirm($question, yes => 1) };
	is($result, 1, 'the answer is yes');
	is($out.$err, '', 'nothing is printed');
};

subtest 'a controlling terminal is asked' => sub {
	plan tests => 3;
	no warnings 'redefine';
	local *Genesis::Commands::Env::in_controlling_terminal = sub { 1 };
	my $result;

	set_stdin("y\n");
	my ($out, $err) = output_from { $result = Genesis::Commands::Env::_deploy_confirm($question, yes => 0) };
	reset_stdin();
	is($result, 1, 'a yes at the terminal is a yes');
	like($err, qr/Upload the new cloud config/, 'the question is asked');

	set_stdin("n\n");
	output_from { $result = Genesis::Commands::Env::_deploy_confirm($question, yes => 0, default => 1) };
	reset_stdin();
	is($result, 0, 'a no at the terminal is a no');
};

subtest 'without a terminal or --yes the deploy stops at once' => sub {
	plan tests => 2;
	no warnings 'redefine';
	local *Genesis::Commands::Env::in_controlling_terminal = sub { 0 };
	set_stdin("y\n");
	throws_ok {
		output_from { Genesis::Commands::Env::_deploy_confirm($question, yes => 0) }
	} qr/Cannot ask "Upload the new cloud config to the BOSH director\?" without a controlling terminal.*--yes/s,
		'stops with the question and the way to answer it';
	my $unread = <STDIN>;
	reset_stdin();
	is($unread, "y\n", 'nothing was read from standard input');
};

# ---------------------------------------------------------------------------
# a question written into a pipe is never answered
# ---------------------------------------------------------------------------
# The reported hang was `genesis <env> deploy --dry-run 2>&1 | tee log`, which
# printed its first lines and then stopped.  A question had gone into the pipe
# where nobody saw it, and the deploy sat on a read that was never going to
# return.  The subtests above hand the prompt an exhausted STDIN, which cannot
# tell a read that returns nothing from a read that never returns at all.
# This one holds the write end of the pipe open so a read really would block,
# and gives the call a deadline: if the deploy asks, the alarm fires and the
# test fails rather than hanging the suite with it.
subtest 'a question is refused rather than read from a pipe that never answers' => sub {
	plan tests => 4;

	pipe(my $reader, my $writer) or die "cannot create a pipe: $!";
	open my $stdin_was, '<&', \*STDIN or die "cannot save STDIN: $!";
	open STDIN, '<&', $reader or die "cannot put the pipe on STDIN: $!";

	ok(!Genesis::Term::in_controlling_terminal(), 'STDIN is a pipe, so there is no controlling terminal');

	my $err;
	{
		local $SIG{ALRM} = sub { die "blocked on a read that will never return\n" };
		alarm 10;
		eval {
			output_from { Genesis::Commands::Env::_deploy_confirm($question, yes => 0, default => 1) };
			1;
		};
		$err = $@;
		alarm 0;
	}

	# Restored before the assertions so a failure reports rather than
	# leaving the suite reading from a pipe nobody writes to.
	open STDIN, '<&', $stdin_was or die "cannot restore STDIN: $!";
	close $stdin_was;

	unlike($err, qr/blocked on a read/, 'the deploy does not wait on the pipe');
	like($err, qr/without a controlling terminal/, 'it stops and says why instead');

	# Nothing was consumed, so an answer written now is still the first thing
	# in the pipe.  A prompt that read and discarded a line would fail here
	# even though it did not block.
	print $writer "y\n";
	close $writer;
	my $unread = <$reader>;
	close $reader;
	is($unread, "y\n", 'and reads nothing from standard input on the way out');
};

done_testing;
