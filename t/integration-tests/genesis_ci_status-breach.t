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
# has run, and the guard below asserts exactly that.  Copy A's own control
# still reaches it too, because a refresh moves the remote-tracking refs and
# leaves a local branch where it stands.  That is the clone an operator
# actually runs this command in, and it is the clone the reading has to get
# right: the question is what R holds, so a reader that counted local heads
# would answer yes here and report no breach at all.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Encode ();
use JSON::PP qw/decode_json/;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub env_line {
	# The one rendered row an environment's name opens, and its index in the
	# report, selected by the indent that opens a row as well as by the name,
	# because the header above the table names environments too.
	my ($tree, $name) = @_;
	my @lines = split(/\n/, $tree);
	my ($index) = grep { plain($lines[$_]) =~ /^\s{2,}\Q$name\E\s/ } 0 .. $#lines;
	return defined($index) ? (plain($lines[$index]), $index) : ('', -1);
}

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
	# Eleven assertions, two of which are guards on the fixture, one more
	# guard on the exit, and one restoration for each of the two commands.
	plan tests => 13;

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

	# The rewrite the protection should have refused, and then the fetch an
	# operator's clone makes afterwards.  Nothing is reset: the fetch moves
	# origin/control off the dropped commit and leaves copy A's own control
	# standing on it, which is the clone the reading has to get right.
	rewrite_control($h, drop => $c2);
	refresh($h, 'a');

	# The first guard says which question the rows below are asking.  Git
	# keeps a dropped commit as a loose object until it collects it, so the
	# object is still here and a reader that asked about the object would
	# answer yes.
	ok(run({dir => $h->a, passfail => 1, stderr => 0},
			'git', 'cat-file', '-e', "$c2^{commit}"),
		'copy A still holds the dropped commit as a loose object');

	# The second says that a local ref still reaches it, which is what makes
	# this fixture discriminate.  A reader that counted local heads as well
	# as remote-tracking refs would report no breach here at all, and every
	# assertion below it would fail.
	ok(run({dir => $h->a, passfail => 1, stderr => 0},
			'git', 'merge-base', '--is-ancestor', $c2, $h->control),
		"and copy A's own control still reaches it");

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	# A guard.  Every assertion below it reads standard output, and a
	# command that had come to refuse a breached repository would print
	# nothing there and fail them all for a reason that had nothing to do
	# with the report.
	is($exit, 0, 'the command still reports every environment');
	is($err, '', 'and says nothing on standard error');
	# The commit is named rather than matched loosely, because a renderer
	# that printed the environment's deployed sha, or another row's marker,
	# would satisfy any seven hexadecimal characters.
	my $named = sprintf(q{lab%ss marker names control@%s},
		chr(39), substr($c2, 0, 7));
	like(plain($out), qr/\Q$named\E/,
		'the breach names the environment and the commit its marker names');
	like(plain($out), qr/the remote no longer holds/,
		'the breach says the commit cannot be fetched');

	# The row takes the class of the worst thing on it, and a marker naming
	# a commit nothing can fetch is the worst thing there is.  Colour is off
	# in this file, so the glyph is the half of the class a reader can see.
	# It is a multibyte symbol and the output arrives as bytes, so the line
	# is decoded before it is read: the red class draws a cross where the
	# settled class draws a tick.
	my ($line, $row_at) = env_line($out, 'lab');
	like(Encode::decode_utf8($line), qr/^\s+lab\s+\S+\s+\S+\s+\x{2718}/,
		'and the breached row carries the glyph of the red class');

	# The line is about the repository rather than about one row of it, so
	# it stands under the table rather than in the middle of it.
	my @lines = map {plain($_)} split(/\n/, $out);
	my ($breach_at) = grep {$lines[$_] =~ /marker names control@/} 0 .. $#lines;
	cmp_ok($breach_at // -1, '>', $row_at,
		'and the breach lands beneath the table it belongs to');

	my ($json) = run_genesis($h, 'pipeline-status', '--json');
	my $record = decode_json($json);
	# The list is defaulted rather than dereferenced outright, so a record
	# that carries no breach report at all fails this row instead of dying
	# inside it and taking the assertion after it with it.
	is(scalar @{$record->{breaches} || []}, 1,
		'the record carries exactly one breach');
	is($record->{breaches}[0]{env}, 'lab', 'the breach names lab');
	is($record->{breaches}[0]{control_commit}, $c2,
		'and names the commit the rewrite dropped, not another sha of the row');
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
