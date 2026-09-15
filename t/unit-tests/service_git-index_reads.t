#!/usr/bin/env perl
# The three index reads D82's two assertions are written on.  Each row proves
# that the answer comes from the index rather than from the working tree,
# which is the whole reason the writer checks its postcondition before it
# commits: at that moment the index is the delivery and the working tree is
# only what the checkouts happened to leave behind.
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

subtest 'ls_files answers about the index and not the working tree' => sub {
	plan tests => 4;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');

	ok(scalar(grep {$_ eq 'qa.yml'} $git->ls_files),
		'a path the commit and the index both hold is listed');

	# In the working tree and nowhere in the index, which is the operator's
	# scratch file the mirror must never read as a path of its own.
	helper::put_file($h->a . '/stranger.yml', "---\nstranger: true\n");
	ok(!grep({$_ eq 'stranger.yml'} $git->ls_files),
		'a file nobody staged is not listed, though the working tree holds it');

	run({dir => $h->a}, 'git', 'add', '--', 'stranger.yml');
	ok(scalar(grep {$_ eq 'stranger.yml'} $git->ls_files),
		'and it is listed once it is staged, though no commit holds it');

	# Gone from the working tree and still in the index, which is the other
	# direction of the same difference.
	unlink($h->a . '/qa.yml') or die "cannot remove qa.yml: $!\n";
	ok(scalar(grep {$_ eq 'qa.yml'} $git->ls_files),
		'a path deleted in the working tree alone is still listed');
};

subtest 'diff_cached_quiet compares the index with a ref' => sub {
	plan tests => 5;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $git  = $h->git('a');
	my $head = $git->sha('HEAD');

	ok($git->diff_cached_quiet($head),
		'a fresh index matches the commit it was read from');

	# The working tree alone has moved, so the answer must not, which is the
	# difference the first assertion of the check depends on.
	helper::put_file($h->a . '/qa.yml', "---\nkit: tampered\n");
	ok($git->diff_cached_quiet($head),
		'an edit nobody staged leaves the two agreeing');

	run({dir => $h->a}, 'git', 'add', '--', 'qa.yml');
	ok(!$git->diff_cached_quiet($head),
		'and staging that same edit makes them differ');

	ok($git->diff_cached_quiet($head, '.genesis'),
		'a pathspec the staged change sits outside of still agrees');

	my $err = do {local $@; eval {$git->diff_cached_quiet('nosuchref'); 1}; $@};
	like($err, qr/nosuchref/,
		'a ref git cannot read is named rather than read as a difference');
};

subtest 'diff_cached_names names the paths the index moved' => sub {
	plan tests => 3;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $git  = $h->git('a');
	my $head = $git->sha('HEAD');

	is_deeply([$git->diff_cached_names($head)], [],
		'a fresh index differs from its commit over nothing');

	# One path staged and one path edited in the working tree alone, so the
	# answer says which of the two a caller would have to report.
	helper::put_file($h->a . '/qa.yml', "---\nkit: staged\n");
	run({dir => $h->a}, 'git', 'add', '--', 'qa.yml');
	helper::put_file($h->a . '/.genesis/config', "---\nunstaged: true\n");

	is_deeply([$git->diff_cached_names($head)], ['qa.yml'],
		'the staged path is named and the working-tree edit beside it is not');

	is_deeply([$git->diff_cached_names($head, '.genesis')], [],
		'and a pathspec the staged path sits outside of names nothing');
};

done_testing;
