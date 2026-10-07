#!/usr/bin/env perl
# Proves T346: pipeline-apply runs only with control checked out and in step
# with the remote.  Off control it refuses naming the branch it found and
# control, ahead or behind it refuses in D30's words, and each refusal writes
# nothing; in step it applies and records the commit the remote holds (D113).
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# What the remote holds, every ref and the commit it names, so a refusal can be
# shown to have created and pushed nothing.
sub remote_refs {
	my ($h) = @_;
	my ($out) = run({dir => $h->a}, 'git', 'ls-remote', $h->r);
	return $out;
}

subtest 'a feature branch cut from control is refused' => sub {
	# Five rows, and the run's own restoration assertion.
	plan tests => 6;

	my $h = make_harness(envs => ['qa']);
	local_branch($h, 'feature/reshape', at => $h->control);
	stand_on($h, 'feature/reshape');
	my $before = remote_refs($h);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = unfolded($out, $err);

	is($exit, Genesis::Exit::DATAERR, 'the apply refuses at DATAERR');
	like($said, qr{feature/reshape}, 'naming the branch it found');
	like($said, qr{git checkout control}, 'and control, by name, as the way out');
	is(remote_refs($h), $before, 'no branch was created or pushed');
	no_secret($h->applied_path, 'and no applied record was written');
};

subtest 'control ahead of the remote is refused as unpushed' => sub {
	# Four rows, and the run's own restoration assertion.
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);
	stand_on($h, $h->control);
	commit_on_control($h, files => {'ops/local.yml' => "---\nlocal: 1\n"},
		message => 'not pushed yet');
	my $before = remote_refs($h);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = unfolded($out, $err);

	is($exit, Genesis::Exit::DATAERR, 'the apply refuses at DATAERR');
	like($said, qr{is ahead of origin/control by 1 commit, which is unpublished},
		"in D30's words for ahead");
	is(remote_refs($h), $before, 'no branch was created or pushed');
	no_secret($h->applied_path, 'and no applied record was written');
};

subtest 'control behind the remote is refused as stale' => sub {
	# Four rows, and the run's own restoration assertion.
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);
	stand_on($h, $h->control);
	commit_on_control($h, files => {'ops/teammate.yml' => "---\nteammate: 1\n"},
		message => 'control moves on the remote', push => 1);
	run({dir => $h->a}, 'git', 'reset', '-q', '--hard', 'HEAD~1');
	my $before = remote_refs($h);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = unfolded($out, $err);

	is($exit, Genesis::Exit::DATAERR, 'the apply refuses at DATAERR');
	like($said, qr{is behind origin/control by 1 commit, so it is stale},
		"in D30's words for behind");
	is(remote_refs($h), $before, 'no branch was created or pushed');
	no_secret($h->applied_path, 'and no applied record was written');
};

subtest 'control in step with the remote applies, and records its commit' => sub {
	# Two rows, and the run's own restoration assertion.
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	stand_on($h, $h->control);
	my $tip = $h->git('a')->sha('origin/' . $h->control);

	my (undef, $err, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply proceeds') or diag($err);
	is(secret($h->applied_path . ':control_commit'), $tip,
		'and records the commit the remote holds for control');
};

done_testing;
