#!/usr/bin/env perl
# Proves T199 and T200: genesis new refreshes control into T before its
# ancestry check, refreshes no deployment branch, fails at pre-flight
# naming the network when the remote is unreachable, and leaves every
# deployment branch's tip exactly where it was.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Genesis::Exit;

my $h = make_harness(envs => ['qa', 'prod'], type => 'bosh',
	kit => 'omega-v2.7.0');
init_branch($h, $_) for qw/qa prod/;
refresh($h, 'a');

my $git = $h->git('a');
my %tips_before = map {
	($h->slug($_) => [
		$git->sha('refs/heads/' . $h->slug($_)),
		$git->sha('refs/remotes/origin/' . $h->slug($_)),
	])
} qw/qa prod/;

# Every run below writes, either a commit or a staged file, so each passes
# restore => 0 and leaves the restoration assertion off.  The runner would
# otherwise compare a HEAD the command deliberately moved.
#
# The runs that only need the command to reach a write let it commit rather
# than staging under --no-commit, because the uncommitted-work check the
# command still carries reads a staged file as work in the way, so a second
# run in the same copy would meet the first run's staged environment file
# and refuse before it ever reached the refresh.
subtest 'control is refreshed into T before the ancestry check' => sub {
	# A teammate adds an environment file that copy A has never seen.
	publish_from_b($h, files => {'lab.yml' => "kit:\n  name: bosh\n"},
		message => 'Add environment lab');

	my $control_t_before = $git->sha('refs/remotes/origin/' . $h->control);

	stand_on($h, $h->control);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'new', 'prod2');

	isnt($git->sha('refs/remotes/origin/' . $h->control), $control_t_before,
		'control moved in T, so the command refreshed it');
	is($exit, 0, 'the run succeeded');
};

subtest 'no deployment branch is refreshed' => sub {
	# The teammate advances both deployment branches on R.
	move_on_r($h, $h->slug('qa'));
	move_on_r($h, $h->slug('prod'));

	stand_on($h, $h->control);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'new', 'prod3');
	is($exit, 0, 'the run succeeded');

	for my $env (qw/qa prod/) {
		my $slug = $h->slug($env);
		is($git->sha('refs/remotes/origin/' . $slug), $tips_before{$slug}[1],
			"${slug}'s remote-tracking ref did not move");
	}
};

subtest 'an unreachable remote fails at pre-flight naming the network' => sub {
	sever_remote($h);
	stand_on($h, $h->control);

	# This one refuses and writes nothing, so the runner's own assertion is
	# the right one and the row takes the default.
	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod4', '--no-commit');

	is($exit, Genesis::Exit::TEMPFAIL(),
		'the run failed at TEMPFAIL, which a re-run can fix');
	like($err, qr/the network or the remote is unreachable/i,
		'the failure names the class of remote error it was, '.
		'and not every remote error there is');
	ok(!-f $h->a . '/prod4.yml',
		'and it failed before writing anything');
	restore_remote($h);

	# There is one row here and not three.  The refusal reads the kind the
	# fetch result carries, and the harness can provoke the network kind
	# alone: sever_remote injects "Could not resolve host", and nothing in
	# it makes a remote reject credentials or fail for a reason the
	# classifier cannot name.  An auth row wants a fixture the harness does
	# not have, and it is named as a gap rather than faked here.
};

subtest 'the command touches no deployment branch' => sub {
	stand_on($h, $h->control);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'new', 'prod5');
	is($exit, 0, 'the run succeeded');

	is($git->current_branch, $h->control,
		'the commit landed on the branch the operator stood on');
	my ($subject) = $git->log_subjects($h->control, limit => 1);
	like($subject, qr/prod5/,
		'and the environment file was committed there');

	for my $env (qw/qa prod/) {
		my $slug = $h->slug($env);
		is($git->sha('refs/heads/' . $slug), $tips_before{$slug}[0],
			"${slug}'s local ref did not move");
	}
};

subtest 'it writes and commits on a feature branch too' => sub {
	# The branch is cut from the refreshed tip rather than from copy A's
	# own control ref, which the rows above committed to and which the
	# teammate's published commit is missing from.  A feature branch that
	# does not carry what control carries is refused, and this row is
	# about where the command writes rather than about that refusal.
	my $feature = 'add-prod6';
	$git->create_branch($feature, 'refs/remotes/origin/' . $h->control);
	stand_on($h, $feature);

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'new', 'prod6');
	is($exit, 0, 'the run succeeded on a feature branch');
	is($git->current_branch, $feature,
		'the operator is still on the feature branch');
	my ($subject) = $git->log_subjects($feature, limit => 1);
	like($subject, qr/prod6/,
		'and the commit landed there');

	for my $env (qw/qa prod/) {
		my $slug = $h->slug($env);
		is($git->sha('refs/heads/' . $slug), $tips_before{$slug}[0],
			"${slug}'s local ref still did not move");
	}
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
