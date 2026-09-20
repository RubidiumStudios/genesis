#!/usr/bin/env perl
# Proves T281: detail sits in square brackets after the word it qualifies,
# each phrase component takes its own colour class, and the row's glyph and
# name take the worst class present, which here is the red of drifted.
#
# The third row settles whether the illegal initial state D96 refuses
# applies to a command that resolves nothing.  A hand commit the operator's
# own clone has not published is the state D33 legalises and the state
# drift_for exists to report, so a
# report that refused it would refuse to explain the one thing it was written
# to explain.
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
use Genesis::CI::Status;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# Genesis::Term reads TERM once, at load, and emits 38;5;<id> wherever the
# name matches 256color, at lib/Genesis/Term.pm:283.  The child inherits this
# process's TERM, so the row pins a low-colour terminal and the decoder below
# reads one encoding rather than whichever one the machine happens to have.
$ENV{TERM} = 'xterm';

sub env_row {
	my ($record, $name) = @_;
	my ($row) = grep { $_->{env} eq $name } @{$record->{environments}};
	return $row;
}

sub plain {
	# The line with every SGR sequence taken out, which is what the words of
	# a row are asserted against.  A colour escape ends in the letter m, so a
	# coloured name has a word character immediately in front of it and a
	# pattern anchored on a word boundary could never match one.
	my ($line) = @_;
	$line =~ s/\e\[[0-9;]*m//g;
	return $line;
}

sub classes_in {
	# Returns the markup letter guarding each coloured run of the line, in
	# order, by reading the SGR sequences csprintf emitted.
	my ($line) = @_;
	my %by_code = (32 => 'G', 33 => 'Y', 34 => 'B', 31 => 'R', 30 => 'K', 36 => 'C');
	my @classes;
	while ($line =~ /\e\[([0-9;]+)m/g) {
		for my $code (split /;/, $1) {
			push @classes, $by_code{$code} if $by_code{$code};
		}
	}
	return @classes;
}

# The environment file the manual row wants, which is the one the harness
# seeds with the manual declaration added.  It is written through the harness
# and published, because a writer that commits without pushing leaves control
# ahead of its remote and the report would then be about a repository no
# teammate has.
sub declare_manual {
	my ($h, $env) = @_;
	write_env_file($h, $env, pipeline => {
		manual                 => 'true',
		track_additional_files => ['ops/shared.yml'],
	});
	push_from($h, 'a', $h->control);
	return $h;
}

subtest 'one row carries deployed, drifted, and [manual]' => sub {
	# Seven assertions and one restoration.
	plan tests => 8;

	delete local $ENV{NOCOLOR};
	my $h = make_harness(envs => ['lab'], provider => 'concourse',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	declare_manual($h, 'lab');
	init_branch($h, 'lab');
	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, 'lab', control => $c1);
	certify($h, 'lab', control_commit => $c1);
	fixture_applied($h, control => $c1, provider => 'concourse');
	fixture_pipeline_record($h, 'lab');
	hand_commit($h, $h->slug('lab'), files => {'ops/shared.yml' => "---\nby hand\n"});
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'the command exits zero');

	my ($row) = grep { plain($_) =~ /^\s+lab\b/ } split(/\n/, $out);
	my $words = plain($row);
	like($words, qr/deployed; drifted \[ops\/shared\.yml differs: hand commit\]/,
		'the drift detail sits in brackets after the word it qualifies');
	like($words, qr/\[manual\]\s*$/, '[manual] trails the phrase as a marker');

	my @classes = classes_in($row);
	is($classes[0], 'R', "the row's name takes the worst class present, which is red");
	# A guard.  The record task already gave each component its own class, so
	# green stood on this word before the drift did, and the row would pass
	# against it.  It is here because the worst-class rule above only means
	# something if the components beside it kept their own colours.
	ok(scalar(grep { $_ eq 'G' } @classes),
		'the settled word deployed keeps its own green');
	ok(scalar(grep { $_ eq 'K' } @classes),
		"[manual] keeps its own dim class rather than the row's");
	is($err, '', 'and the report says nothing on standard error');
};

subtest 'the five classes map onto the markup Genesis::Term already has' => sub {
	# A guard over the class table and the ranking the record task landed.
	# The worst-class rule the row above proves rests on both, so an edit
	# that renamed a class or reordered the ranking would make that row fail
	# for a reason nothing here named.  These three say the reason.
	plan tests => 3;

	is_deeply(\%Genesis::CI::Status::CLASS_MARKUP,
		{settled => 'G', in_flight => 'Y', on_ice => 'B', wrong => 'R', inert => 'K'},
		'the five classes map onto the five markup letters');

	is(Genesis::CI::Status::worst_class([settled => 'deployed'], [wrong => 'drifted']),
		'wrong', 'wrong outranks settled');
	is(Genesis::CI::Status::worst_class([inert => '[manual]'], [on_ice => 'held']),
		'on_ice', 'on ice outranks inert');
};

subtest 'a hand commit nobody published is reported rather than refused' => sub {
	# Five assertions and one restoration.
	plan tests => 6;

	my $h = make_harness(envs => ['lab'], provider => 'manual',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');
	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);

	# The delivery is written from copy A, so the operator's own clone stands
	# on the commit the marker names and the hand commit below is the one
	# thing its deployment branch holds that the remote does not.
	deliver($h, 'lab', copy => 'a', control => $c1);
	certify($h, 'lab', control_commit => $c1);
	fixture_applied($h, control => $c1);
	fixture_pipeline_record($h, 'lab');
	my $by_hand = hand_commit($h, $h->slug('lab'), copy => 'a', push => 0,
		files => {'ops/shared.yml' => "---\nby hand\n"});

	# The commit above left the clone standing on the deployment branch, and
	# the branch class refuses a command run from there for its own reason.
	# This row is about the branch's history rather than about where the
	# operator is standing, so the clone goes back to control first.
	stand_on($h, $h->control);
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
	is($exit, 0, 'the report does not refuse the state it was written to report');

	my ($row) = grep { $_->{env} eq 'lab' } @{decode_json($out)->{environments}};
	is_deeply($row->{drifted}{files}, ['ops/shared.yml'],
		'the drift names every file that differs from the snapshot');
	is($row->{drifted}{commit}, $by_hand,
		'and it names the newest hand commit above the snapshot');
	is($err, '', 'and the refusal it used to raise is not on standard error');
	like($out, qr/"manual"\s*:\s*false/,
		"the manual flag is the encoder's own boolean rather than a number");
};

subtest 'a branch the remote has never had reads as local only' => sub {
	# Four assertions and one restoration for each of the two commands.
	plan tests => 6;

	my $h = make_harness(envs => ['lab'], provider => 'manual',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	fixture_pipeline_record($h, 'lab');

	# A deployment branch is derived from control and never originates
	# locally, so one this clone holds and the remote has never had was cut
	# by a person.  No run may start from it, and the report says so rather
	# than refusing to describe the repository at all.
	local_branch_only($h, 'lab');
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
	is($exit, 0, 'the report describes the state rather than refusing it');

	# A guard.  The pre-flight classified this state before anything here
	# read it, and the walk copied it into the divergence cell, so the
	# assertion passed on arrival.  It is here because the line below reads
	# that cell, and a renderer given the wrong state would otherwise fail
	# for a reason nothing named.
	my $row = env_row(decode_json($out), 'lab');
	is($row->{divergence}{state}, 'no-remote',
		'the record carries the state the pre-flight classified');

	my ($tree) = run_genesis($h, 'pipeline-status');
	my ($line) = grep { plain($_) =~ /^\s+lab\b/ } split(/\n/, $tree);
	like(plain($line), qr/local only \[the remote has no such branch; [^\]]+\]/,
		'the line names the state and the remedy in one sentence');
	unlike(plain($line), qr/unrelated/,
		'and it is not read as a branch with an unrelated history');
};

subtest 'a branch sharing no ancestor with the remote reads as unrelated' => sub {
	# Four assertions and one restoration for each of the two commands.
	plan tests => 6;

	my $h = make_harness(envs => ['lab'], provider => 'manual',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	fixture_pipeline_record($h, 'lab');

	# Both sides hold the name and neither holds a commit the other does, so
	# no divergence state tells this apart from an ordinary one.  The
	# pre-flight asked the ancestry question and the record carries its
	# answer.
	unrelated_branch($h, 'lab');
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
	is($exit, 0, 'the report describes the state rather than refusing it');

	like($out, qr/"unrelated"\s*:\s*true/,
		"the record says the two histories share nothing, in the encoder's ".
		"own boolean");

	my ($tree) = run_genesis($h, 'pipeline-status');
	my ($line) = grep { plain($_) =~ /^\s+lab\b/ } split(/\n/, $tree);
	like(plain($line), qr/unrelated \[no ancestor in common with the remote's; [^\]]+\]/,
		'the line names the state and the remedy in one sentence');
	unlike(plain($line), qr/local only/,
		'and it is not read as a branch the remote has never had');
};

done_testing;
