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

done_testing;
