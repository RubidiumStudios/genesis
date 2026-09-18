#!/usr/bin/env perl
# Proves T285, T287, and T290: the stale header naming the changed
# environment and pipeline-apply, the disowned pipeline refused at CONFIG
# with no environment reported, and the discovery mark shown where the
# applied pipeline knows the environment and null where it does not.
#
# The three rows read one record.  pipeline-apply writes it, and what it says
# is the only thing standing between an operator and a report that looks
# healthy while the pipeline it describes has moved on, has never been told
# about an environment, or has been disowned by the configuration that still
# runs it.
#
# Which assertions discriminate and which guard is said beside each.
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
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

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

subtest 'a new environment file makes the pipeline stale' => sub {
	# Four assertions and one restoration for each of the two commands.
	plan tests => 6;

	# staged is the applied pipeline that has propagated nothing, and it
	# writes the vault, the applied record, the pipeline records, and the
	# init branches itself, so this row writes none of them again.  The kit
	# is named because an environment the walk loads needs one.
	my $h = staged(envs => ['lab'], kit => 'omega-v2.7.0');
	write_env_file($h, 'dev');
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'the command still reports');
	like(plain($out), qr/stale: dev configuration-changed/,
		'the header names the changed environment and the reason');
	like(plain($out), qr/genesis pipeline-apply/,
		'the header names the command that fixes it');

	# A commit that changes the repository's own configuration is the same
	# change to the defining paths, and it is what a moved deployment root
	# reaches the query as.
	my $g = staged(envs => ['lab'], kit => 'omega-v2.7.0');
	set_repo_config($g, 'pipeline.name', 'moved');
	refresh($g, 'a');

	my ($moved) = run_genesis($g, 'pipeline-status');
	like(plain($moved), qr/stale.*genesis pipeline-apply/s,
		'a commit that changes the configuration reads stale the same way');
};

subtest 'a disowned pipeline is refused and nothing is reported' => sub {
	# Four assertions and one restoration.
	plan tests => 5;

	my $h = staged(envs => ['lab'], kit => 'omega-v2.7.0');
	set_repo_config($h, 'pipeline.enabled', 0);
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, Genesis::Exit::CONFIG, 'the command refuses at CONFIG');
	like(unfolded($err), qr/the configuration disowns a pipeline that is still live/,
		'the refusal names the disowned pipeline');
	like(unfolded($err),
		qr/Set pipeline\.enabled: true again, or tear the pipeline down by hand/,
		'the refusal names the two remedies');
	# Nothing at all rather than no environment name.  A disabled pipeline
	# reports no environment whatever the refusal does, because the roster
	# the report walks is empty once the configuration turns the section off,
	# so a pattern looking for the name would pass against a command that
	# refused after it had printed its header.  What T287 is about is that
	# the report does not begin, and an empty stream is what says so.
	is($out, '', 'nothing is reported at all');
};

subtest 'the discovery mark belongs to environments the pipeline knows' => sub {
	# Two assertions and one restoration.
	plan tests => 3;

	my $h = make_harness(envs => ['lab', 'dev'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml']);
	fixture_vault($h);
	init_branch($h, $_) for qw/lab dev/;
	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, 'lab', control => $c1);
	fixture_applied($h, control => $c1);
	fixture_pipeline_record($h, 'lab', discovery => 'incomplete');
	refresh($h, 'a');

	my ($json) = run_genesis($h, 'pipeline-status', '--json');
	my $record = decode_json($json);
	my ($lab) = grep { $_->{env} eq 'lab' } @{$record->{environments}};
	my ($dev) = grep { $_->{env} eq 'dev' } @{$record->{environments}};

	is($lab->{discovery}, 'incomplete', 'the known environment carries the mark');
	# A guard.  The field is declared null on every record, so nothing in the
	# tree can fail this today.  It stands because the fill above it has a
	# wrong answer close at hand: an environment with no pipeline subpath is
	# one the applied pipeline does not know, while a record that exists and
	# names no mark reads complete, so a fill that reached for the reading
	# rather than for the record would write complete here.
	is($dev->{discovery}, undef,
		'an environment the applied pipeline does not know carries a null discovery');
};

done_testing;
