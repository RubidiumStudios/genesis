#!/usr/bin/env perl
# `genesis new` refuses a staged index naming the files, ignores an unstaged
# edit, and skips both checks under --no-commit, while a switching command
# refuses the same unstaged edit.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Genesis;
use Genesis::Exit;

# make_harness runs fixture_vault itself, so it is not run again here.
my $h = make_harness(envs => ['qa'], type => 'bosh', kit => 'omega-v2.7.0');
init_branch($h, 'qa');
refresh($h, 'a');
my $git = $h->git('a');

subtest 'a staged index is refused, naming the files' => sub {
	# This one refuses and writes nothing, so the runner's own restoration
	# assertion is the right one and the row takes the default.
	stand_on($h, $h->control);
	my $staged = stage_unrelated($h, 'notes.txt');

	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod');

	is($exit, Genesis::Exit::DATAERR(),
		'the staged index is refused');
	like(unfolded($err), qr/There are staged changes in this repository/,
		'in the words the new rule uses');
	like(unfolded($err), qr/\Q$staged\E/,
		'and the refusal names the staged file');
	ok(!-f $h->a . '/prod.yml',
		'no environment file was written');

	Genesis::run({dir => $h->a}, 'git', 'reset', '-q');
	unlink $h->a . "/$staged";
};

subtest 'an unstaged edit is ignored' => sub {
	stand_on($h, $h->control);
	my $edited = modify_unrelated($h, 'qa.yml');

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'new', 'prod');

	is($exit, 0, 'the run proceeded');
	my ($subject) = $git->log_subjects($h->control, limit => 1);
	like($subject, qr/prod/, 'and committed the environment file');

	my $status = $git->status;
	like($status->{$edited} // '', qr/^ M$/,
		'the unstaged edit is still unstaged and uncommitted');

	Genesis::run({dir => $h->a}, 'git', 'checkout', '--', $edited);
};

subtest '--no-commit skips both checks' => sub {
	stand_on($h, $h->control);
	my $staged = stage_unrelated($h, 'notes2.txt');
	my $edited = modify_unrelated($h, 'qa.yml');
	my $head = $git->sha('HEAD');

	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'new', 'prod2', '--no-commit');

	is($exit, 0, 'the run proceeded with a staged index');
	unlike(unfolded($err), qr/\Q$staged\E/, 'and raised no refusal');
	is($git->sha('HEAD'), $head, 'it made no commit');

	my $status = $git->status;
	like($status->{'prod2.yml'} // '', qr/^A/,
		'the environment file is staged and left there');
	like($status->{$staged} // '', qr/^A/,
		'the unrelated staged file is untouched');

	Genesis::run({dir => $h->a}, 'git', 'reset', '-q');
	Genesis::run({dir => $h->a}, 'git', 'checkout', '--', $edited);
	unlink $h->a . "/$staged", $h->a . '/prod2.yml';
};

subtest 'a switching command refuses the same unstaged edit' => sub {
	# This is what makes the qualifier load-bearing rather than
	# decorative.  The same edit that genesis new proceeds through is one
	# a session's begin refuses, because its abort must discard only what
	# it wrote.
	stand_on($h, $h->control);
	my $edited = modify_unrelated($h, 'qa.yml');

	my ($out, $err, $exit) = run_genesis($h, 'qa', 'info');

	isnt($exit, 0, 'the switching command refused');
	like(unfolded($err), qr/\Q$edited\E/, 'naming the modified file');

	Genesis::run({dir => $h->a}, 'git', 'checkout', '--', $edited);
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
