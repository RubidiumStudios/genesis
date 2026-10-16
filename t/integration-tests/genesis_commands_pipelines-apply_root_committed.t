#!/usr/bin/env perl
# Proves T373: pipeline-apply requires its deployment root committed, and only
# its own (D112 and D113, both noted 2026-10-16).  An uncommitted change in the
# root is one problem in the apply's single refusal, beside control ahead of
# the remote; an uncommitted change in another root of the same repository is
# no problem of this apply's.
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

sub remote_refs {
	my ($h) = @_;
	my ($out) = run({dir => $h->a}, 'git', 'ls-remote', $h->r);
	return $out;
}

# The manual provider keeps fly out of it; bosh/ is the root under test and
# vault/ stands beside it.
sub harness {
	my $h = make_harness(envs => ['lab', 'qa', 'prod'], fanned => 'lab',
		provider => 'manual', root => 'bosh');
	commit_on_control($h, files => {'vault/notes.yml' => "--- {}\n"},
		message => 'a second root beside bosh', push => 1);
	return $h;
}

subtest 'an uncommitted change in the root is refused with the rest' => sub {
	# Five rows, and the run's own restoration assertion.
	plan tests => 6;

	my $h = harness();
	commit_on_control($h, files => {'bosh/README.md' => "a local note\n"},
		message => 'not pushed yet');
	write_env_file($h, 'prod', pipeline => {prior_env => 'qa'}, commit => 0);
	my $before = remote_refs($h);

	my ($out, $err, $exit) = run_genesis($h, {dir => 'bosh'}, 'pipeline-apply');
	my $said = unfolded($out, $err);

	is($exit, Genesis::Exit::DATAERR, 'the apply refuses at DATAERR');
	like($said, qr{uncommitted changes.*bosh/prod\.yml}, 'naming the uncommitted file');
	like($said, qr{ahead of origin/\S+ by 1 commit}, 'and the unpushed commit, in the same refusal');
	is(remote_refs($h), $before, 'no branch was created or pushed');
	no_secret($h->applied_path, 'and no applied record was written');
};

subtest "another root's uncommitted change is not this apply's" => sub {
	# One row, and the run's own restoration assertion.
	plan tests => 2;

	my $h = harness();
	mkfile_or_fail($h->a . '/vault/notes.yml', "--- {changed: true}\n");

	my ($out, $err, $exit) = run_genesis($h, {dir => 'bosh'}, 'pipeline-apply');
	is($exit, 0, 'the apply in bosh/ proceeds') or diag($err);
};

done_testing;
