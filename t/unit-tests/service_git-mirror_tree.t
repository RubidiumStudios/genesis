#!/usr/bin/env perl
# The tree a delivery would land, which the preview takes from one commit and
# hands to the next as its base.  Two things therefore have to hold.  What
# comes back has to be a tree and not git talking, because a caller that hands
# git's own sentence on asks the next delivery to diff against a tree nobody
# wrote.  And the whole set has to reach the index, because a set that stops
# at whatever a pipe will hold is a delivery missing its tail with nothing
# said about it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use POSIX qw/WNOHANG/;
use Test::More;

use Genesis;
use Genesis::Exit qw/DATAERR/;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# A git first on the path that answers write-tree with the body the row wants
# and passes every other command through to the real one.  The wrapper is how
# a row reaches an answer git itself will not give on demand.
my $real_git = (grep {-x $_} map {"$_/git"} split(/:/, $ENV{PATH}))[0];
plan skip_all => "git is required to exercise Service::Git::mirror_tree"
	unless $real_git;

sub shimmed_git {
	my ($body) = @_;

	my $bin = helper::workdir() . sprintf('/shim-%06d', int(rand(1_000_000)));
	helper::mkdir_or_fail($bin);
	helper::put_file("$bin/git", <<SH);
#!/bin/bash
if [[ "\$1" == "write-tree" ]]; then
$body
fi
exec "$real_git" "\$@"
SH
	chmod 0755, "$bin/git" or die "chmod shim git: $!";
	return $bin;
}

subtest 'the tree holds the set and nothing beside it' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');
	my $sha = $git->sha('HEAD');

	my $tree = $git->mirror_tree($sha, 'qa.yml');
	like($tree, qr/^[0-9a-f]{40}$/, 'the answer is a tree');
	is_deeply([$git->ls_tree($tree, '.')], ['qa.yml'],
		'and it holds the one path the set named');
};

subtest 'a warning git writes beside the sha stays out of the answer' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');
	my $sha = $git->sha('HEAD');

	# The same set read twice, once through a git that complains on the way
	# and once through the real one, so the row says what the complaint did
	# to the answer rather than only that the answer looked odd.
	my $clean = $git->mirror_tree($sha, 'qa.yml');

	my $bin = shimmed_git(
		"\techo \"warning: unable to access '/nowhere/.gitconfig'\" >&2\n" .
		"\texec \"$real_git\" \"\$\@\"");

	my $tree = do {
		local $ENV{PATH} = "$bin:$ENV{PATH}";
		$git->mirror_tree($sha, 'qa.yml');
	};

	like($tree, qr/^[0-9a-f]{40}$/,
		'the answer is forty hex characters and nothing else');
	is($tree, $clean, 'and it is the tree the same set writes in quiet');
};

subtest 'an answer that is not a sha is refused at DATAERR' => sub {
	plan tests => 3;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');
	my $sha = $git->sha('HEAD');

	# git exits zero and says something that is not a tree, which is the one
	# shape a read of the status alone cannot catch.
	my $bin = shimmed_git("\techo 'not a tree at all'\n\texit 0");

	my ($err, $exit) = bail_from(sub {
		local $ENV{PATH} = "$bin:$ENV{PATH}";
		$git->mirror_tree($sha, 'qa.yml');
	});

	like($err, qr/\Q$sha\E/, 'the refusal names the commit it was mirroring');
	like($err, qr/not a tree at all/, 'and hands back what git said');
	is($exit, DATAERR, 'and it exits DATAERR');
};

subtest 'a set larger than a pipe is staged whole' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');

	# Two thousand paths make a listing of some hundred and forty kilobytes,
	# which is more than a pipe holds, and a pipe filled before the child is
	# spawned stops there with nobody reading the other end.
	my $count = 2000;

	# That many loose objects is enough for git to start a housekeeping run
	# of its own in the background, which then repacks them while the
	# temporary repository is being taken down and fills the run with
	# complaints about files that are already gone.
	run({dir => $h->a}, 'git', 'config', 'gc.auto', '0');

	helper::mkdir_or_fail($h->a . '/bulk');
	helper::put_file($h->a . "/bulk/file-$_.yml", "---\nn: $_\n")
		for (1 .. $count);
	run({dir => $h->a}, 'git', 'add', '--', 'bulk');
	run({dir => $h->a}, 'git', 'commit', '-m', 'A set larger than a pipe');
	my $sha = $git->sha('HEAD');

	# The read runs in a child, because a caller that blocks in write blocks
	# there for good and no alarm takes it out again.  The parent gives it a
	# minute and then takes the answer off disk.
	my $answer = $h->{tmp} . '/mirror-tree-bulk';
	my $pid = fork();
	die "fork failed: $!\n" unless defined $pid;
	unless ($pid) {
		my $tree = eval {$git->mirror_tree($sha, 'bulk/')};
		helper::put_file($answer, ($tree // 'nothing came back') . "\n");
		POSIX::_exit(0);
	}

	my $finished = 0;
	for (1 .. 600) {
		last if $finished = (waitpid($pid, WNOHANG) == $pid);
		select(undef, undef, undef, 0.1);
	}
	unless ($finished) {
		kill 'KILL', $pid;
		waitpid($pid, 0);
	}
	ok($finished, 'the staging finishes rather than blocking on a full pipe');

	my $tree = '';
	if ($finished) {
		$tree = slurp($answer) // '';
		chomp $tree;
	}
	my @listed = $tree =~ /^[0-9a-f]{40}$/ ? $git->ls_tree($tree, '.') : ();
	is(scalar(@listed), $count, 'and every path of the set is in the tree');
};

# What one refusal said and what it would have exited, since bail leaves
# neither behind for a row to read.  It asserts about this file's rows and
# builds nothing, so it lives here rather than in the harness.
sub bail_from {
	my ($code) = @_;

	my @raised;
	my $died;
	{
		no warnings 'redefine';
		local *Service::Git::bail = sub {push @raised, [@_]; die "refused\n"};
		eval {$code->(); 1} or $died = $@;
	}
	unless (@raised) {
		diag("nothing was refused, and the code died with: $died")
			if defined $died;
		return ('', undef);
	}

	my @args = @{$raised[0]};
	my $opts = ref($args[0]) eq 'HASH' ? shift(@args) : {};
	my ($format, @rest) = @args;

	return (sprintf($format, @rest), $opts->{exitcode});
}

done_testing;
