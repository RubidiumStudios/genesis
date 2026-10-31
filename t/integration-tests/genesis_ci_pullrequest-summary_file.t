#!/usr/bin/env perl
# Proves T458 (D132): `genesis propagate --summary-file` lists the pull
# requests a run opened or updated, one line each, in Slack's link markup,
# and leaves the file present and empty where it opened and updated none, so
# the pipeline's Slack put, which interpolates the file, sends nothing then.
#
# What the rows catch: a run that opened a pull request nobody hears of, a
# message per run that says nothing new, and a file a refused run left
# holding the last run's lines, which the put would send again.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub summary_lines {
	my ($file) = @_;
	return undef unless -f $file;
	return [grep {length} split /\n/, slurp($file)];
}

my $h    = ready(envs => ['prod'], kit => 'omega-v2.7.0');
my $file = "$h->{tmp}/summary/summary.txt";

subtest 'a run that opens a pull request lists it' => sub {
	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the prod instance count');
	refresh($h, 'a');
	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y', '--summary-file', $file);
	is($exit, 0, 'the run succeeds') or diag(unfolded($out, $err));
	my $lines = summary_lines($file);
	is(scalar(@{$lines || []}), 1, 'one line') or diag(explain($lines));
	like($lines && $lines->[0], qr/^prod: opened <\S+\|#\d+>, 1 commit$/,
		'naming the environment, the pull request as a link, and its commit');
};

my ($number) = (summary_lines($file) // [''])->[0] =~ /\|#(\d+)>/;

subtest 'a run that adds a commit to it lists it as updated' => sub {
	due_commit($h, 'prod', params => {instances => 3},
		message => 'Raise prod again');
	refresh($h, 'a');
	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y', '--summary-file', $file);
	is($exit, 0, 'the run succeeds') or diag(unfolded($out, $err));
	my $lines = summary_lines($file);
	is(scalar(@{$lines || []}), 1, 'one line') or diag(explain($lines));
	my $n = $number // 'none';
	like($lines && $lines->[0], qr/^prod: updated <\S+\|#\Q$n\E>, 2 commits$/,
		'the same pull request, now proposing both commits');
};

subtest 'a run that leaves it as it was lists nothing' => sub {
	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y', '--summary-file', $file);
	is($exit, 0, 'the run succeeds') or diag(unfolded($out, $err));
	ok(-f $file, 'the file is there');
	is(slurp($file), '', 'and empty');
};

subtest 'a refused run leaves the file empty' => sub {
	helper::put_file($file, "prod: opened <https://example.com/pull/1|#1>, 1 commit\n");
	commit_on_control($h, files => {'ops/unpushed.yml' => "---\nunpushed: 1\n"},
		message => 'an unpushed control commit', push => 0);
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '-y', '--summary-file', $file);
	is($exit, Genesis::Exit::DATAERR, 'the run refuses') or diag($err);
	ok(-f $file, 'the file is there');
	is(slurp($file), '', 'and empty, the last run\'s line gone');
};

done_testing;
