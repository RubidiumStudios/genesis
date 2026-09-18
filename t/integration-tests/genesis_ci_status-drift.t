#!/usr/bin/env perl
# Proves T277 and T283: both axes are reported at once, and the drifted cell
# names every file that differs from the branch's snapshot along with the
# hand commit that changed them.
#
# The two axes are independent because the model has two of them.  An
# environment may be awaiting a deployment and carrying a hand edit at the
# same time, and a report that folded either into the other would say one of
# those things and leave the operator to guess the rest.
#
# Which assertions here discriminate and which guard is said beside each.
# The hand commit's sha reached the record in the snapshot-flag task rather
# than in this one, so the two assertions that read it are this file's
# discriminators and the fold assertions around them are guards: the renderer
# that folded the two axes into one string was deleted when the read model
# landed, so nothing in the tree can fail them today.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use JSON::PP qw/decode_json/;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub env_row {
	my ($record, $name) = @_;
	my ($row) = grep { $_->{env} eq $name } @{$record->{environments}};
	return $row;
}

sub plain {
	# The tree with every SGR sequence taken out, which is what the words of
	# a row are asserted against.  NOCOLOR is set above and the renderer
	# honours it, so this ordinarily changes nothing.  It is here because a
	# colour escape ends in the letter m, so a word boundary can never hold
	# in front of a coloured name, and a row that met one would fail for a
	# reason that had nothing to do with the words.
	my ($tree) = @_;
	$tree =~ s/\e\[[0-9;]*m//g;
	return $tree;
}

sub env_line {
	# The one line of the tree that belongs to this environment, selected by
	# its leading indent as well as its name, so a header carrying the name
	# could not stand in for it.
	my ($tree, $name) = @_;
	my ($line) = grep { /^\s+\Q$name\E\s/ } split(/\n/, plain($tree));
	return $line // '';
}

subtest 'two undeployed markers and a hand commit read on both axes' => sub {
	# Four assertions and one restoration for each of the two commands.
	plan tests => 6;

	my $h = make_harness(envs => ['lab'], provider => 'manual',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');

	# One certified commit and two delivered above it, which is T277's
	# branch: two markers the environment has not deployed.
	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, 'lab', control => $c1);
	certify($h, 'lab', control_commit => $c1);

	my $c2 = commit_on_control($h, files => {'ops/shared.yml' => "---\ntwo\n"}, push => 1);
	deliver($h, 'lab', control => $c2);
	my $c3 = commit_on_control($h, files => {'ops/shared.yml' => "---\nthree\n"}, push => 1);
	deliver($h, 'lab', control => $c3);

	fixture_applied($h, control => $c3);
	fixture_pipeline_record($h, 'lab');
	my $hand = hand_commit($h, $h->slug('lab'),
		files => {'ops/shared.yml' => "---\nby hand\n"});
	refresh($h, 'a');

	my ($json) = run_genesis($h, 'pipeline-status', '--json');
	my $row = env_row(decode_json($json), 'lab');

	# A guard.  The certification axis was read from the walk's own record
	# when the read model landed, so this word stood before the snapshot axis
	# existed.  It is here because the assertion below it only means
	# something while this one holds: the two axes are proved independent by
	# reading both off one row, and a row that had lost its reading would
	# prove nothing about the pair.
	is($row->{reading}, 'pending-deploy',
		'the certification axis reads pending-deploy for the undeployed markers');
	is($row->{drifted}{commit}, $hand,
		'the snapshot axis names the hand commit at the same time');

	my ($tree) = run_genesis($h, 'pipeline-status');
	my $line = env_line($tree, 'lab');
	# Two guards.  The renderer that printed one folded string per row went
	# with the old command, so no tree today can carry one axis and lose the
	# other.  They stand because T277's whole claim is about the pair, and an
	# edit that let either word displace the other would break here and
	# nowhere else.
	like($line, qr/awaiting deployment.*drifted/,
		'the tree prints both readings on the one row');
	unlike($line, qr/\bpending\b.*\bpending\b/,
		'neither axis is folded into the other');
};

subtest 'the drifted cell names every file that differs' => sub {
	# Three assertions and one restoration for each of the two commands.
	plan tests => 5;

	my $h = make_harness(envs => ['lab'], provider => 'manual',
		kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml', 'ops/extra.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');
	my $c1 = commit_on_control($h,
		files => {'ops/shared.yml' => "---\none\n", 'ops/extra.yml' => "---\nextra\n"},
		push  => 1);
	deliver($h, 'lab', control => $c1);
	certify($h, 'lab', control_commit => $c1);
	fixture_applied($h, control => $c1);
	fixture_pipeline_record($h, 'lab');

	my $hand = hand_commit($h, $h->slug('lab'), files => {
		'ops/shared.yml' => "---\nby hand\n",
		'ops/extra.yml'  => "---\nby hand too\n",
	});
	refresh($h, 'a');

	my ($json) = run_genesis($h, 'pipeline-status', '--json');
	my $row = env_row(decode_json($json), 'lab');

	is_deeply([sort @{$row->{drifted}{files}}], ['ops/extra.yml', 'ops/shared.yml'],
		'both changed files are named');
	is($row->{drifted}{commit}, $hand, 'the hand commit that changed them is named');

	my ($tree) = run_genesis($h, 'pipeline-status');
	# The detail reads as T281 and the design's canonical sample quote it,
	# which is the wording the snapshot-flag task's repairs landed.
	like(env_line($tree, 'lab'),
		qr/drifted \[ops\/extra\.yml, ops\/shared\.yml differs: hand commit\]/,
		'the tree lists both files in the one bracket');
};

done_testing;
