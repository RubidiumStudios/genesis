#!/usr/bin/env perl
# Proves the reading half of T1: the fourteen shared readers answer one way
# about a ref, a tip, a sha on R, a repository's refs, its current branch, a
# commit's paths, a commit's contents, a file, R's branch list, a clone made
# now, a branch's last subjects, every local head, whether a commit is
# reachable on R, and a record set's newest entry.
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
	plan tests => 7;

	my $h = make_harness(envs => ['qa'], vault => 0);

	is(ref_in($h->a, 'no/such/branch'), undef,
		'a ref that does not exist reads undef');
	is(remote_sha($h, 'no/such/branch'), undef,
		'and so does a branch R has never had');
	is(tip_of($h, 'no/such/branch'), undef, 'and a tip in copy A');
	is_deeply(files_at($h, 'no/such/branch'), {},
		'a commit that is not there reads an empty set of files');
	is(slurp($h->a . '/no-such-file'), undef, 'and a missing file reads undef');

	my $unborn = helper::workdir() . '/unborn';
	helper::mkdir_or_fail($unborn);
	run({dir => $unborn}, 'git', 'init', '-q');

	is(branch_of($unborn), undef,
		'a repository with no commits names no branch');
	is_deeply(refs_in($unborn), {}, 'and lists no refs at all');
};

# Proves the second reading half of T1: the six later readers answer for R's
# branch list, a fresh clone, a branch's recent subjects, a record set's
# newest entry, every local head, and whether a commit is reachable on R.
subtest 'the six later readers answer about the fixture' => sub {
	# The eleven are the ten rows below and the restoration that the one
	# run asserts for itself.
	plan tests => 11;

	my $h = make_harness(envs => ['lab', 'qa'], vault => 0);
	init_branch($h, 'lab');
	init_branch($h, 'qa');
	refresh($h, 'a');

	is_deeply(branches_on_r($h), [$h->control, $h->slug('lab'), $h->slug('qa')],
		'branches_on_r names R\'s branches, short and sorted');

	my $clone = fresh_clone($h);
	isnt($clone, $h->a, 'fresh_clone is a third clone, not copy A');
	# A clone holds R's branches as remote-tracking refs and stands on one
	# local head of its own, so the comparison is against what it tracks.
	# Its origin/HEAD is a symbolic ref onto one of those and names no
	# branch R does not already have.
	is_deeply(branches_on_r($h), [sort
			map {substr($_, length 'refs/remotes/origin/')}
			grep {!m{^refs/remotes/origin/HEAD$}}
			keys %{refs_in($clone, prefix => 'refs/remotes/origin')}],
		'and it sees what R holds');

	commit_on_control($h, files => {'qa.yml' => "---\none\n"},
		message => 'First change', push => 1);
	my $second = commit_on_control($h, files => {'qa.yml' => "---\ntwo\n"},
		message => 'Second change', push => 1);
	refresh($h, 'a');

	is_deeply([subjects_of($h, $h->control, 2)],
		['First change', 'Second change'],
		'subjects_of reads the last subjects in the order they were committed');

	is_deeply([subjects_of($h, 'no/such/branch', 2)], [],
		'and a branch nobody has reads back as no subjects at all');

	ok(reachable_on_r($h, $second), 'a pushed commit is reachable on R');

	my $local = local_only_commit($h, $h->control, marker => 0,
		files => {'never-pushed.yml' => "---\nlocal: true\n"});
	ok(!reachable_on_r($h, $local), 'and one that was never pushed is not');

	# The list is read for its contents and not only against itself, because
	# a reader that answered an empty list every time would pass a
	# comparison of one call against another and say nothing.
	my $before = heads_in($h);
	ok(scalar(grep {$_ eq 'refs/heads/' . $h->control . " $local"} @$before),
		'heads_in names the control branch as its ref name and its sha');

	run_genesis($h, 'pipeline-status');
	is_deeply(heads_in($h), $before,
		'a command that writes no ref leaves the whole list where it was');

	local_branch($h, 'scratch');
	is_deeply(heads_in($h), [@$before, "refs/heads/scratch $local"],
		'and a branch made since reads back beside it, so a row can compare');
};

subtest 'the newest entry of a record set reads back nested' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);
	my $target = fixture_vault($h);
	my $control = $h->git('a')->sha($h->control);
	my $set = $h->env_path('qa') . '/deployments';

	# The harness's own record writers put one flat record at a path, so the
	# two dated entries of a record set are written here through safe rather
	# than through a fixture that cannot make more than one of them.
	for my $entry (['2026-09-12-100000', '2026-09-12 10:00:00 +0000'],
	               ['2026-09-13-100000', '2026-09-13 10:00:00 +0000']) {
		run({env => {SAFE_TARGET => $target},
		     onfailure => "Failed to write $set/$entry->[0]"},
			'safe', 'set', "$set/$entry->[0]",
			"git.commit=$control", "dated=$entry->[1]");
	}

	my $record = newest_record($h, $set);
	is($record->{git}{commit}, $control,
		'a dotted field reads back as a nested hashref');
	is($record->{dated}, '2026-09-13 10:00:00 +0000',
		'and the newest entry is the one answered');
	is(newest_record($h, $h->env_path('lab')), undef,
		'a path nothing was written to reads undef');

	# The harness's own writers lay one record down at the path itself, and
	# that record is a set of one.  It is written last, under the two dated
	# entries above, so the row proves which of the two shapes is preferred
	# where a path has both.
	certify($h, 'qa', commit => $control, control_commit => $control,
		at => '2026-09-11 10:00:00 +0000');

	my $one = newest_record($h, $h->env_path('qa'));
	is($one->{git}{control_commit}, $control,
		'a record sitting at the path itself reads back nested too');
	is($one->{dated}, '2026-09-11 10:00:00 +0000',
		'and it is the entry answered, rather than a child of the path');
};

done_testing;
