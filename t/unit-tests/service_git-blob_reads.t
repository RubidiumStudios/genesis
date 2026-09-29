#!/usr/bin/env perl
# read_blobs answers what a commit holds at a set of paths, in one git
# process and without touching HEAD, the index or the working tree, which is
# how control's hierarchy files are written out for the merged read (D117).
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Exception;

use Genesis;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Counts the git processes a read spawns, by wrapping the run Service::Git
# calls through.
sub runs_during(&) {
	my ($code) = @_;
	my $runs = 0;
	no warnings 'redefine';
	my $real = \&Service::Git::run;
	local *Service::Git::run = sub { $runs++; goto &$real };
	my @answer = $code->();
	return ($runs, @answer);
}

sub head_state {
	my ($git) = @_;
	my ($status) = run({dir => $git->root}, 'git', 'status', '--porcelain=v2', '--branch');
	return $status;
}

subtest 'read_blobs answers what a commit holds, in one git process' => sub {
	plan tests => 7;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');
	my $sha = $h->commit_on_control(
		files   => {'site.yml' => "---\nsite: 1\n", 'qa.yml' => "---\nqa: 1\n  \n"},
		message => 'two files to read back');

	# The working tree moves on after the commit, so an answer read from it
	# rather than from the commit would show.
	put_file($h->a . '/site.yml', "---\nsite: 2\n");
	my $before = head_state($git);

	my ($runs, $blobs) = runs_during {
		$git->read_blobs($sha, 'site.yml', 'qa.yml', 'absent.yml')
	};

	is($runs, 1, 'every path is read by one git process');
	is($blobs->{'site.yml'}{content}, "---\nsite: 1\n",
		"a path's content is the commit's, not the working tree's");
	is($blobs->{'qa.yml'}{content}, "---\nqa: 1\n  \n",
		'and the last blob read keeps its trailing whitespace exactly');
	my ($expected) = run({dir => $git->root}, 'git', 'rev-parse', "$sha:site.yml");
	is($blobs->{'site.yml'}{sha}, $expected,
		'each path carries the blob sha the commit holds it at');
	ok(!exists $blobs->{'absent.yml'},
		'a path the commit does not hold is absent from the answer, not an error');
	is(head_state($git), $before,
		'HEAD, the index and the working tree are as they were');
	is_deeply([sort keys %$blobs], ['qa.yml', 'site.yml'],
		'and nothing else is answered');
};

subtest 'read_blobs refuses a ref git cannot resolve' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');

	# Every path of an unresolvable ref reads as missing, which is the
	# answer an empty commit would give, so the ref is asked for in the same
	# process and a missing ref refuses rather than answering nothing.
	throws_ok { $git->read_blobs('no-such-branch', 'qa.yml') }
		qr/Cannot read .*no-such-branch/s,
		'a ref git cannot resolve refuses, naming the ref';
	my ($runs, $blobs) = runs_during { $git->read_blobs('HEAD') };
	is_deeply([$runs, $blobs], [0, {}],
		'and no paths asks git nothing and answers nothing');
};

done_testing;
