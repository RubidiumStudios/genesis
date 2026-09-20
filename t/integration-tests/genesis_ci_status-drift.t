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
# The hand commit's sha reaches the record through the snapshot flag rather
# than through anything here, so the two assertions that read it are this
# file's discriminators and the fold assertions around them are guards.  The
# renderer that folded the two axes into one string was deleted when the read
# model landed, so nothing in the tree can fail them today.
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

subtest 'two undeployed markers and a hand commit read on both axes' => sub {
	# Five assertions and one restoration for each of the two commands.
	plan tests => 7;

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

	# A fourth control commit nobody delivered, so the routing summary has a
	# commit to count and the phrase carries the word pending.  Without one
	# the word appears nowhere in the line and the doubled-pending assertion
	# below would pass against any renderer at all.
	my $c4 = commit_on_control($h, files => {'ops/shared.yml' => "---\nfour\n"}, push => 1);

	fixture_applied($h, control => $c4);
	fixture_pipeline_record($h, 'lab');
	my $hand = hand_commit($h, $h->slug('lab'),
		files => {'ops/shared.yml' => "---\nby hand\n"});
	refresh($h, 'a');

	my ($json, $err) = run_genesis($h, 'pipeline-status', '--json');
	my $row = env_row(decode_json($json), 'lab');
	is($err, '', 'the report says nothing on standard error');

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
	#
	# The second one catches a narrower thing than the first.  Only the
	# routing summary writes the word pending, and it writes it once for the
	# undelivered commit above, so what this assertion refuses is a renderer
	# that wrote the word a second time out of the certification axis, whose
	# own word is awaiting deployment.
	like($line, qr/awaiting deployment.*drifted/,
		'the tree prints both readings on the one row');
	unlike($line, qr/\bpending\b.*\bpending\b/,
		'neither axis is folded into the other');
};

subtest 'the drifted cell names every file that differs' => sub {
	# Four assertions and one restoration for each of the two commands.
	plan tests => 6;

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

	my ($json, $err) = run_genesis($h, 'pipeline-status', '--json');
	my $row = env_row(decode_json($json), 'lab');
	is($err, '', 'the report says nothing on standard error');

	is_deeply([sort @{$row->{drifted}{files}}], ['ops/extra.yml', 'ops/shared.yml'],
		'both changed files are named');
	is($row->{drifted}{commit}, $hand, 'the hand commit that changed them is named');

	my ($tree) = run_genesis($h, 'pipeline-status');
	# Half novel and half a guard.  The two files joined into one bracket is
	# T283's own claim and nothing else asserts it, while the wording round
	# them, which reads differs: hand commit, came in with the snapshot flag
	# and is green on arrival.  It reads as T281 and
	# the design's canonical sample quote it.
	like(env_line($tree, 'lab'),
		qr/drifted \[ops\/extra\.yml, ops\/shared\.yml differs: hand commit\]/,
		'the tree lists both files in the one bracket');
};

done_testing;
