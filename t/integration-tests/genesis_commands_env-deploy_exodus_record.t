#!/usr/bin/env perl
# Proves T225, the recorded dependency set being what the deploy actually
# read, which shrinks when a prerequisite goes; T330, the two timestamp forms
# staying apart; and T327, the failed exodus write after BOSH deployed
# exiting UNAVAILABLE.
#
# Every run passes --no-propagate, for the reason the due-commits and drifted
# files give, because the auto-cascade hands off to a child genesis propagate
# that a later step owns and that fails today, and a row about what the deploy
# recorded should not be reading the child's failure as the deploy's.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The environment file as the tracked tree writes it, with the prerequisite
# list the row wants.  A row that drops a prerequisite has to put the whole
# file back on the deployment branch, because that branch is what the deploy
# reads, and this keeps the two writes saying the same thing but for the list.
sub env_body {
	my ($h, @prereqs) = @_;
	return "---\nkit:\n  name:    dev\n  version: latest\n  features: []\n"
	     . "genesis:\n  env: qa\n  pipeline:\n    track_dependencies:\n"
	     . join('', map {"      - " . $h->slug($_) . "\n"} @prereqs);
}

subtest 'the recorded dependency set is what the deploy actually read' => sub {
	plan tests => 6;

	my $h = tracked_harness(qw/lab ops/);
	# This environment's director is named for the environment, so the
	# director fixture and the environment's own exodus record share one
	# path and a deploy's record write replaces the credentials.  They are
	# read here and written back below, so the second deploy can still find
	# the director the first one deployed to.
	my $director = record_at($h, $h->env_path('qa'));
	my ($err, $exit);
	(undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');
	is($exit, 0, 'the first deploy succeeded')
		or diag("what the deploy said:\n$err");

	# The set lives on the flat record at the environment's exodus base,
	# which is what last_read_dependencies reads and what the staleness
	# query compares the compiled set against.
	my $flat = record_at($h, $h->env_path('qa'));
	is_deeply([sort split(/\s*,\s*/, $flat->{dependencies_read} // '')],
		[sort ($h->slug('lab'), $h->slug('ops'))],
		'it recorded both prerequisites it read, as deployment slugs');

	# The file goes on the deployment branch by hand, because that branch is
	# what the deploy reads and a rewrite on control alone would not reach
	# it until a propagate had routed it there.
	hand_commit($h, $h->slug('qa'),
		files   => {edited_file($h, 'qa') => env_body($h, 'lab')},
		message => 'stop tracking a prerequisite');
	refresh($h, 'a', $h->control, $h->slug('qa'));
	fixture_director($h, 'qa', url => $director->{url});
	(undef, $err, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');
	# Green when it was written, because this deploy already succeeded
	# unasserted.  It stays as a guard against a later step breaking the
	# second deploy, which the row below would otherwise report as a wrong
	# dependency set rather than as a deploy that never ran.
	is($exit, 0, 'the second deploy succeeded')
		or diag("what the deploy said:\n$err");

	$flat = record_at($h, $h->env_path('qa'));
	is_deeply([split(/\s*,\s*/, $flat->{dependencies_read} // '')],
		[$h->slug('lab')],
		'and the second deploy recorded the smaller set');
};

subtest 'the two timestamp forms stay apart' => sub {
	# Every row here was green when it was written, and the subtest stays as
	# a guard rather than as a proof of anything this task wrote.  What it
	# catches is a later step writing a time held as a value in the path's
	# short numeric form, or an entry name in the value's form, or an ISO
	# form anywhere, which is the one distinction D58 exists to keep.
	#
	# The plan is six rather than four, because the record and the times it
	# holds are now asserted before their form is judged.  A record that
	# carried neither time would otherwise pass the two form rows having
	# read nothing, and a missing record would die in the map rather than
	# fail.
	plan tests => 6;

	my $h = tracked_harness();
	run_genesis($h, 'qa', 'deploy', '--no-propagate', '-y', 'r');

	my $set    = $h->env_path('qa').'/deployments';
	my $record = newest_record($h, $set);
	isnt($record, undef, 'the deploy wrote a record to read');
	my @times = grep {defined} map {$record->{$_}} qw/started completed/;
	ok(scalar(@times), 'and the record holds at least one time as a value');

	my ($dated) = reverse sort @{record_keys($h, $set)};
	like($dated, qr/^\d{14}$/,
		'the timestamp in the path is the short numeric UTC form');

	my @bad = grep {
		$_ !~ /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [-+]\d{4}$/
	} @times;
	is_deeply(\@bad, [], 'every time held as a value is in EXODUS_TIME_FORMAT');

	my @iso = grep {$_ =~ /T\d{2}:\d{2}:\d{2}/} @times;
	is_deeply(\@iso, [], 'and no value carries an ISO form');
};

subtest 'a failed exodus write after BOSH deployed names its own code' => sub {
	plan tests => 4;

	my $h = tracked_harness();
	# The writes are refused and the reads go on answering, because a deploy
	# whose vault stopped reading refuses long before BOSH, and this row is
	# about the write that fails once BOSH has deployed.
	break_vault_writes($h, $h->env_path('qa'));

	# restore => 0 and no assertion, because the deploy leaves through a
	# refusal and its cache stays in the tree behind it, so there is nothing
	# to assert back.
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '--no-propagate', '-y', 'r');

	is($exit, Genesis::Exit::UNAVAILABLE, 'it exits UNAVAILABLE')
		or diag("what the deploy said:\n$err");
	# The row below and the last row of this subtest were green when they
	# were written, because the message they replaced already said
	# "deployed" and already named the vault.  They stay as guards against a
	# later step dropping either half from a message whose whole job is to
	# carry both facts at once.  The row between them is the one carrying
	# D98's own words, and it was red.
	like(unfolded($out.$err), qr/deployed/i,
		'it reports the deployment as done');
	like(unfolded($err), qr/record was not written/i,
		'it says the record was not written');
	like(unfolded($err), qr/vault/i, 'and what to do about it');
	restore_vault($h);
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
