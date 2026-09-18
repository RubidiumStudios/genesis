#!/usr/bin/env perl
# Proves T292: a control commit a marker names is dropped from R by a rewrite
# that got past the protection, and the status reports the breach, naming the
# unreachable commit and the environment whose marker names it.
#
# A marker is a bare sha with no ancestry link to the deployment branch,
# because propagation copies files and never commits, so the marker means
# something only while a ref still reaches the commit it names.  The branch
# protection is meant to make this impossible, and this is the one report that
# says so when a rewrite gets past the protection anyway.
#
# The fixture is what the reader has to answer for.  Copy A wrote the dropped
# commit, so its objects are still in copy A's own database once the rewrite
# has run, and the guard below asserts exactly that.  What has gone is every
# ref that reached it: R was rewritten, and copy A's control caught up with
# the rewrite the way an operator's clone does when it pulls.  A reader that
# asked whether the object was there would answer yes for that clone and
# report no breach at all, which is why the question is reachability.
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

sub plain {
	# The tree with every SGR sequence taken out, which is what the words of
	# a line are asserted against.  NOCOLOR is set above and the renderer
	# honours it, so this ordinarily changes nothing.  It is here because a
	# colour escape ends in the letter m, so a word boundary can never hold
	# in front of a coloured name, and a line that met one would fail for a
	# reason that had nothing to do with the words.
	my ($tree) = @_;
	$tree =~ s/\e\[[0-9;]*m//g;
	return $tree;
}

subtest 'a rewritten control orphans a marker and the status says so' => sub {
	# Five assertions, one guard on the fixture, and one restoration for each
	# of the two commands.
	plan tests => 8;

	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml', 'ops/extra.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');

	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	my $c2 = commit_on_control($h, files => {'ops/extra.yml' => "---\nextra\n"}, push => 1);
	deliver($h, 'lab', control => $c2);
	certify($h, 'lab', control_commit => $c2);
	fixture_applied($h, control => $c2);
	fixture_pipeline_record($h, 'lab');

	# The rewrite the protection should have refused, and then the clone
	# catching up with it.  The fetch alone moves the tracking ref and leaves
	# copy A's own control standing on the dropped commit, which is a ref
	# that still reaches it, so the reset is what makes the commit
	# unreachable here as it already is on R.
	rewrite_control($h, drop => $c2);
	refresh($h, 'a');
	run({dir => $h->a, onfailure => 'Failed to catch copy A up with the rewrite'},
		'git', 'reset', '--hard', sprintf('origin/%s', $h->control));

	# The guard that says which question the rows below are asking.  Git
	# keeps a dropped commit as a loose object until it collects it, so the
	# object is still here and a reader that asked about the object would
	# answer yes.  Every assertion after this one is about the refs instead.
	ok(run({dir => $h->a, passfail => 1, stderr => 0},
			'git', 'cat-file', '-e', "$c2^{commit}"),
		'copy A still holds the dropped commit as a loose object');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'the command still reports every environment');
	like(plain($out), qr/\Qlab's marker names control@\E[0-9a-f]{7}/,
		'the breach names the environment whose marker is orphaned');
	like(plain($out), qr/the remote no longer holds/,
		'the breach says the commit cannot be fetched');

	my ($json) = run_genesis($h, 'pipeline-status', '--json');
	my $record = decode_json($json);
	# The list is defaulted rather than dereferenced outright, so a record
	# that carries no breach report at all fails this row instead of dying
	# inside it and taking the assertion after it with it.
	is(scalar @{$record->{breaches} || []}, 1,
		'the record carries exactly one breach');
	is($record->{breaches}[0]{env}, 'lab', 'the breach names lab');
};

subtest 'an intact control reports no breach' => sub {
	# One assertion and one restoration.
	plan tests => 2;

	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');
	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, 'lab', control => $c1);
	fixture_applied($h, control => $c1);
	fixture_pipeline_record($h, 'lab');
	refresh($h, 'a');

	my ($json) = run_genesis($h, 'pipeline-status', '--json');
	is_deeply(decode_json($json)->{breaches}, [],
		'an append-only control reports nothing');
};

done_testing;
