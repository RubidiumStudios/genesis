#!/usr/bin/env perl
# Proves T307, that `genesis pipeline-status` shows the needs-clearing phrase
# with the reason, who set the hold as <user>@<hostname>, and when, and that
# the deploy names the same hold with the same reason, so the run's report,
# the status table, and the deploy tell one story.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

subtest 'the three readers print one story' => sub {
	# Sixteen rows.  Twelve are this subtest's own, one of which is the
	# status command's restoration assertion made in the row's own words
	# under restore => 0, and four more are the restoration assertions
	# run_genesis makes for the delivery, the hold, the preview, and the
	# deploy.
	#
	# The identity rows are the ones that discriminate.  The needs-clearing
	# phrase and the blocked-commits count are both printed by the tree as it
	# stands, so a reader that named neither who set the hold nor when would
	# pass every other row in this file.
	plan tests => 16;

	# The deploy is the real one, taken to success, because the hold line
	# this row is about is printed by the deploy's pre-flight and only a
	# pipeline-enabled deploy runs one.  deployable_prod owns the five things
	# a spawned deploy needs, and the delivery below puts the environment
	# file it writes onto prod's own branch, which is the branch the deploy
	# stands on.
	my $domain = 'prod.example.com';
	my $h = deployable_prod(base_domain => $domain,
		delivered => ['prod'], certified => ['prod']);
	run_genesis($h, 'propagate', '-y');

	run_genesis($h, 'prod', 'pipeline-hold', 'waiting on the capacity report');
	# The due commit is written through the same builder the harness wrote
	# prod.yml with, so the file keeps the base_domain the environment is
	# deployed with.  A body composed here would write the file whole and
	# take that value off it.
	due_commit($h, 'prod',
		params  => {base_domain => $domain, instances => 3},
		message => 'raise the instance count');

	my $record = $h->env_path('prod').'/hold';
	my $who    = sprintf('%s@%s',
		secret("$record:user"), secret("$record:hostname"));
	my $at     = secret("$record:at");

	my $w = snapshot_w($h);
	my ($status, $serr, $status_exit) = run_genesis($h, {restore => 0},
		'pipeline-status');
	assert_w_restored($w, 'the status restored working state');
	is($status_exit, 0, 'the status command succeeded')
		or diag(unfolded($status, $serr));

	my $said = unfolded($status, $serr);
	like($said, qr/held, needs clearing \(waiting on the capacity report\)/,
		'the status shows the needs-clearing phrase with the reason');
	like($said, qr/\Q$who\E/, 'and who set it as user@hostname');
	like($said, qr/\Q$at\E/, 'and when it was set');
	# The environment's own name in the command, because the sentence falls
	# back to a placeholder for a record that carries none, and a row that
	# read the identity alone would pass on a table printing `genesis <env>
	# pipeline-release` at every held row.
	like($said, qr/genesis prod pipeline-release/,
		'and the one command that clears it');

	my ($report, $rerr, undef) = run_genesis($h, 'propagate', '--dry-run');
	my $printed = unfolded($report, $rerr);
	like($printed, qr/held, needs clearing \(waiting on the capacity report\)/,
		"the run's report prints the same phrase");
	like($printed,
		qr/1 commit is blocked until this hold is released with .genesis prod pipeline-release./,
		'and the detail line names the count and the command that clears it');

	my ($deploy, $derr, $deploy_exit) = run_genesis($h, 'prod', 'deploy', '-y');
	my $warned = unfolded($deploy, $derr);
	is($deploy_exit, 0, 'the deploy succeeded') or diag($warned);
	like($warned, qr/waiting on the capacity report/,
		"the deploy names the same hold");
	like($warned, qr/genesis prod pipeline-release/,
		'and points at the one command that clears it');
	like($warned, qr/\Q$who\E/, 'and names who set it, as the other two do');
};

done_testing;
