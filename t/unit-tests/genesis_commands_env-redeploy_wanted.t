#!perl
# Proves the three arms of redeploy_wanted, which is the one reader of the
# question "is this run a redeploy".  A caller holding the deploy's own
# options hash reads the answer out of it, and a caller with no hash asks the
# command line.  Four spellings of one question are four chances for them to
# drift apart, so the arms are held here rather than left to whichever
# integration row happens to exercise one.
#
# Every row was green when it was written, the sub having landed with the
# flag that it answers for, and they are regression rows rather than a proof
# of anything new.  Red was produced by narrowing the body back to the
# command line alone, which reds the two hash rows, and the narrowing was
# undone afterwards.
#
# The root is passed as undef throughout, because the sub takes it and does
# not read it: it comes first so the call reads like the other questions the
# deploy asks of a run, and so that a later step can let a repository setting
# answer the question without rewriting every call site.  A row passing a
# real root would say that the root matters, which is the one thing these
# rows must not say.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use Genesis::Commands;
use Genesis::Commands::Env qw/redeploy_wanted/;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

require Genesis::Config;
Genesis::Init();

subtest 'the options hash answers where a caller has one' => sub {
	plan tests => 3;

	# The command line is set to the opposite of each hash below, so a row
	# that passed would have to be reading the hash and could not be reading
	# the command line by accident.
	local $Genesis::Commands::COMMAND_OPTIONS = {redeploy => 1};
	is(redeploy_wanted(undef, {redeploy => 0}), 0,
		'a hash whose redeploy is false answers no');

	$Genesis::Commands::COMMAND_OPTIONS = {};
	is(redeploy_wanted(undef, {redeploy => 1}), 1,
		'a hash whose redeploy is true answers yes');
	is(redeploy_wanted(undef, {}), 0,
		'and a hash with no redeploy key is an answer rather than an absence');
};

subtest 'the command line answers where a caller has no hash' => sub {
	plan tests => 2;

	local $Genesis::Commands::COMMAND_OPTIONS = {redeploy => 1};
	is(redeploy_wanted(undef), 1, 'the flag on the command line answers yes');

	$Genesis::Commands::COMMAND_OPTIONS = {};
	is(redeploy_wanted(undef), 0, 'and a command line without it answers no');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
