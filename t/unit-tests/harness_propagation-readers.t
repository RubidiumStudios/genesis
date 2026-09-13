#!/usr/bin/env perl
# Proves the reading half of T1: the eight shared readers answer one way
# about a ref, a tip, a sha on R, a repository's refs, its current branch,
# a commit's paths, a commit's contents, and a file.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';

# Genesis is imported before the harness because both of them export a sub
# called slurp, and the one this file is proving is the harness's.
use Genesis;

use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the readers agree with git about one repository' => sub {
	plan tests => 10;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	refresh($h, 'a', $h->control, $h->slug('qa'));

	my ($control) = run({dir => $h->a}, 'git', 'rev-parse', $h->control);
	chomp $control;

	is(ref_in($h->a, $h->control), $control, 'ref_in reads a ref by name');
	is(tip_of($h, $h->control), $control, "tip_of reads copy A's local ref");
	is(remote_sha($h, $h->control), $control, 'remote_sha reads R');
	is(branch_of($h->a), $h->control, 'branch_of names the current branch');

	my $refs = refs_in($h->r);
	ok(exists $refs->{'refs/heads/' . $h->slug('qa')},
		'refs_in lists every ref in a repository');

	ok(scalar(grep {m{^refs/remotes/}} keys %{refs_in($h->a)}),
		'and an unprefixed read of copy A takes in its remote-tracking refs');
	is_deeply(
		[grep {m{^refs/remotes/}} keys %{refs_in($h->a, prefix => 'refs/heads')}],
		[], 'while a prefix narrows the read to the one namespace');

	is_deeply(tree_of($h->r, $h->slug('qa')), ['init'],
		'tree_of lists a commit\'s paths');

	my $files = files_at($h, $h->slug('qa'));
	like($files->{init}, qr/genesis pipeline-apply/,
		'files_at reads a commit\'s paths with their contents');

	helper::put_file($h->a . '/scratch', "one line\n");
	is(slurp($h->a . '/scratch'), "one line\n", 'slurp reads a file whole');
};

subtest 'the remote option reads T rather than L' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $published = remote_sha($h, $h->control);

	my $home = commit_on_control($h,
		files => {'ops/unpushed.yml' => "---\nkept: home\n"},
		message => 'Add an ops file nobody has published');

	is(tip_of($h, $h->control), $home,
		'tip_of follows L when a commit stays in copy A');
	is(tip_of($h, $h->control, remote => 1), $published,
		'and the remote option reads T, which has not moved');
};

subtest 'the readers answer for what is absent' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], vault => 0);

	is(ref_in($h->a, 'no/such/branch'), undef,
		'a ref that does not exist reads undef');
	is(remote_sha($h, 'no/such/branch'), undef,
		'and so does a branch R has never had');
	is(tip_of($h, 'no/such/branch'), undef, 'and a tip in copy A');
	is_deeply(files_at($h, 'no/such/branch'), {},
		'a commit that is not there reads an empty set of files');
	is(slurp($h->a . '/no-such-file'), undef, 'and a missing file reads undef');
};

done_testing;
