#!/usr/bin/env perl
# `genesis new` commits the environment file, and a commit takes everything
# the index already holds, so staged work that belongs to something else
# would be swept into the environment's own commit.  These rows hold the
# refusal at the top of the command, beside the branch check, where an
# operator can act on it before anything is written, and they hold that an
# unstaged edit is left alone because it never reaches the commit.
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

# The first row is the inversion, because an unstaged edit never enters the
# commit and refusing it would protect nothing.
subtest 'an unstaged change is no longer in the way' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $dirty = modify_unrelated($h, 'qa.yml');

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'new', 'lab');

	is($exit, 0, 'the command proceeds');
	ok(-f $h->a . '/lab.yml', 'and writes the environment it was asked for');

	my $status = $h->git('a')->status;
	like($status->{$dirty} // '', qr/^ M$/,
		'while the edit is still unstaged and uncommitted');
};

# The second row keeps its refusal and reads the words the index check uses,
# because the rule it holds did not change and its text did.
subtest 'a staged change is refused too' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $staged = stage_unrelated($h, 'ops/pending.yml');

	my (undef, $err, $exit) = run_genesis($h, {restore => 0}, 'new', 'lab');

	isnt($exit, 0, 'the command refuses');
	like(unfolded($err), qr/There are staged changes in this repository/,
		'in the words the index check uses');
	like(unfolded($err), qr/\Q$staged\E/, 'naming the staged file');
};

subtest 'an untracked file is not in the way' => sub {
	plan tests => 2;

	# D84 again: an operator's scratch file blocks no session, so it blocks
	# no command either, and this row is what keeps the two readings the
	# same.  An untracked path reports two question marks, so the index
	# check skips it exactly as is_clean did.  The run goes on to do the
	# rest of `genesis new`, which needs answers this row does not give it,
	# so what is asserted is that it got past the refusal rather than that
	# it finished.
	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	helper::put_file($h->a . '/scratch.txt', "notes to self\n");

	my (undef, $err) = run_genesis($h, {restore => 0},
		'new', 'lab');

	unlike(unfolded($err), qr/There are staged changes in this repository/,
		'the scratch file is not read as staged work');
	ok(-f $h->a . '/scratch.txt', 'and it is still there afterwards');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
