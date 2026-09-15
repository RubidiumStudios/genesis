#!/usr/bin/env perl
# `genesis new` prepares the environment's branch at the end of its work, and
# that preparation opens a branch session, which refuses a tree with
# uncommitted changes.  Met there, the refusal arrives after the environment
# file has been written and committed onto control.  These rows hold it at
# the top of the command, beside the branch check, where an operator can act
# on it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'an unstaged change is refused before anything is written' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $dirty = modify_unrelated($h, 'qa.yml');

	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'new', 'lab', '--no-fetch');

	isnt($exit, 0, 'the command refuses');
	like($err, qr/Working tree has uncommitted changes/,
		'in the words the session uses');
	like($err, qr/\Q$dirty\E/, 'naming the file that is in the way');
	ok(!-f $h->a . '/lab.yml',
		'and nothing was written for the environment it refused');
};

subtest 'a staged change is refused too' => sub {
	plan tests => 2;

	# Staged and unstaged are one thing to the session, which reads both
	# through is_clean, so the command reads both the same way.
	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $staged = stage_unrelated($h, 'ops/pending.yml');

	my (undef, $err, $exit) = run_genesis($h, {restore => 0},
		'new', 'lab', '--no-fetch');

	isnt($exit, 0, 'the command refuses');
	like($err, qr/\Q$staged\E/, 'naming the staged file');
};

subtest 'an untracked file is not in the way' => sub {
	plan tests => 2;

	# D84 again: an operator's scratch file blocks no session, so it blocks
	# no command either, and this row is what keeps the two readings the
	# same.  The run goes on to do the rest of `genesis new`, which needs
	# answers this row does not give it, so what is asserted is that it got
	# past the refusal rather than that it finished.
	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	helper::put_file($h->a . '/scratch.txt', "notes to self\n");

	my (undef, $err) = run_genesis($h, {restore => 0},
		'new', 'lab', '--no-fetch');

	unlike($err, qr/Working tree has uncommitted changes/,
		'the scratch file is not read as uncommitted work');
	ok(-f $h->a . '/scratch.txt', 'and it is still there afterwards');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
