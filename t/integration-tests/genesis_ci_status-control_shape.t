#!/usr/bin/env perl
# Proves T345's status half and T350's status clause: pipeline-status reports
# control's shape wherever the operator stands, names the control commit that
# shape was read at, and says where the local control branch stands against
# it, so an operator standing on an unpublished change to the shape sees that
# it is not in effect (D112).
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

# lab, then qa following lab, then prod following qa, published on control.
sub chain {
	my $h = ready_harness(envs => ['lab', 'qa', 'prod'], kit => 'omega-v2.7.0');
	write_env_file($h, 'qa',   pipeline => {prior_env => 'lab'});
	write_env_file($h, 'prod', pipeline => {prior_env => 'qa'});
	push_from($h, 'a', $h->control);
	refresh($h, 'a');
	return $h;
}

sub row { my ($json, $env) = @_; return (grep {$_->{env} eq $env} @{$json->{environments}})[0] }

subtest "a feature branch's shape is not the report's" => sub {
	# Five rows, and one for each run's own restoration assertion.
	plan tests => 7;

	my $h = chain();
	my $tip = $h->git('a')->sha('origin/' . $h->control);
	local_branch($h, 'feature/reshape', at => $h->control);
	stand_on($h, 'feature/reshape');
	write_env_file($h, 'prod', pipeline => {prior_env => 'lab'});
	require Genesis::Config;
	my $config = Genesis::Config->new($h->a . '/.genesis/config');
	$config->set('pipeline.enabled' => 0);
	$config->save;
	run({dir => $h->a}, 'git', 'commit', '-q', '-am', 'switch the pipeline off here');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
	is($exit, 0, 'the report runs, since control has the pipeline on');
	my $json = decode_json($out);
	is(row($json, 'prod')->{prior_env}, 'qa',
		"prod follows qa, control's answer, not the branch's lab");
	is($json->{control}{shape_commit}, $tip,
		'and the record names the control commit the shape was read at');

	my ($text) = run_genesis($h, 'pipeline-status');
	like($text, qr/control: \S+\@\Q@{[substr($tip, 0, 7)]}\E/,
		'the header names that commit');
	unlike($text, qr/local control is/,
		'and says nothing of local control, which stands where the remote does');
};

subtest 'local control ahead of the remote is named, and its change is not in effect' => sub {
	# Five rows, and one for each run's own restoration assertion.
	plan tests => 7;

	my $h = chain();
	my $tip = $h->git('a')->sha('origin/' . $h->control);
	stand_on($h, $h->control);
	write_env_file($h, 'prod', pipeline => {prior_env => 'lab'});

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
	my $json = decode_json($out);
	is(row($json, 'prod')->{prior_env}, 'qa', 'prod still follows qa, as the remote has it');
	is($json->{control}{shape_commit}, $tip, 'read at the remote\'s commit');
	is_deeply([@{$json->{control}{local}}{qw/state ahead behind/}], ['ahead', 1, 0],
		'and the record says local control is one commit ahead');

	my ($text) = run_genesis($h, 'pipeline-status');
	like($text, qr/local control is 1 commit ahead of control\@\Q@{[substr($tip, 0, 7)]}\E/,
		'the report says so under the header');
	like($text, qr/not in effect until (it is )?pushed/, 'and that its change is not in effect');
};

subtest 'local control behind the remote is named' => sub {
	# Three rows, and one for each run's own restoration assertion.
	plan tests => 5;

	# The remote moves one commit on, and the local branch is set back to
	# where it stood, which is a clone that has not pulled.
	my $h = chain();
	stand_on($h, $h->control);
	my $tip = commit_on_control($h, files => {'ops/teammate.yml' => "---\nteammate: 1\n"},
		message => 'control moves on the remote', push => 1);
	run({dir => $h->a}, 'git', 'reset', '-q', '--hard', 'HEAD~1');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
	my $json = decode_json($out);
	is($json->{control}{shape_commit}, $tip, 'the shape is read at the remote\'s new commit');
	is_deeply([@{$json->{control}{local}}{qw/state ahead behind/}], ['behind', 0, 1],
		'and the record says local control is one commit behind it');

	my ($text) = run_genesis($h, 'pipeline-status');
	like($text, qr/local control is 1 commit behind control\@\Q@{[substr($tip, 0, 7)]}\E/,
		'the report says so under the header');
};

done_testing;
