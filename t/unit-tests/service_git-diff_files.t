#!/usr/bin/env perl
# The structured diff, and the one answer it must never give.  A git that
# cannot take the diff writes its reason where the file names would be, and
# no line of that reason matches any of the three statuses the reader parses,
# so an unchecked read would answer an empty changed list and an empty
# deleted list.  Every caller reads that as nothing having changed, which on
# the drift warning is a hatch that has gone silent.
#
# The first subtest was green when it was written, the classification it
# reads having been there all along.  It earns its place by pinning that
# classification, which is what the second subtest's refusal protects: a
# reader that answered an empty diff would satisfy neither, and a reader
# that refused everything would satisfy only the second.
#
# The callers are the deploy's drifted warning at
# lib/Genesis/Commands/Env.pm, the publish at lib/Genesis/CI/Publish.pm, and
# the pipelines command at lib/Genesis/Commands/Pipelines.pm.  None of them
# reads an empty answer as anything but "nothing changed", so the refusal
# belongs here rather than at each of the three.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a diff git can take classifies what changed and what went' => sub {
	plan tests => 3;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');

	# One file that will survive the second commit and be edited by it, and
	# one that will not survive it at all, so both halves of the answer have
	# something in them.
	helper::put_file($h->a . '/doomed.txt', "here for now\n");
	run({dir => $h->a}, 'git', 'add', '--', 'doomed.txt');
	run({dir => $h->a, onfailure => 'Failed to lay the base commit'},
		'git', 'commit', '-q', '-m', 'lay a file down');
	my $base = $git->sha('HEAD');

	helper::put_file($h->a . '/qa.yml', "---\nkit: edited\n");
	run({dir => $h->a}, 'git', 'add', '--', 'qa.yml');
	run({dir => $h->a}, 'git', 'rm', '-q', '-f', '--', 'doomed.txt');
	run({dir => $h->a, onfailure => 'Failed to lay the second commit'},
		'git', 'commit', '-q', '-m', 'edit one and remove the other');

	my $diff = $git->diff_files($base, 'HEAD');
	is_deeply($diff->{changed}, ['qa.yml'], 'the edited file is changed');
	is_deeply($diff->{deleted}, ['doomed.txt'], 'the removed file is deleted');
	is_deeply([sort @{$diff->{all}}], ['doomed.txt', 'qa.yml'],
		'and all holds both of them');
};

subtest 'a diff git refuses is named rather than read as clean' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');

	my $err = do {
		local $@;
		eval {$git->diff_files('nosuchref', 'HEAD'); 1};
		$@;
	};
	ok($err, 'the read refuses rather than answering an empty diff');
	like($err, qr/nosuchref/,
		'and the refusal names the ref git could not resolve');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
