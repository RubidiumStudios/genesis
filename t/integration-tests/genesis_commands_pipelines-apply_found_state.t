#!/usr/bin/env perl
# Proves T429 (D124): the apply says of every write whether it was new,
# changed, or already in place, and makes no write where nothing changes.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

# ruleset_writes - how many rulesets the double has been sent so far
#
# The call log is cumulative across runs, so a row about one run counts
# before and after it.  A GET is a read and never counts.
sub ruleset_writes {
	my ($gh) = @_;
	return scalar grep {
		defined $_->{url} && $_->{url} =~ m{/rulesets}
			&& ($_->{method} // '') =~ /^(?:POST|PUT)$/
	} gh_calls($gh);
}

sub control_sha {
	my ($h) = @_;
	my ($sha) = run({dir => $h->a}, 'git', 'rev-parse', $h->control);
	chomp $sha;
	return $sha;
}

subtest 'a first apply finds nothing in place' => sub {
	# Six rows, and one more for the run's own restoration assertion.
	plan tests => 7;

	my $h = make_harness(envs => ['qa'], provider => 'manual', github => 1);
	push_from($h, 'a', $h->control);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the apply exits 0');

	like($said, qr{created \Qqa/bosh\E}, 'the branch is created');
	like($said, qr{protected \Q@{[$h->control]}\E}, 'control is protected');
	like($said, qr{protected \Qqa/bosh\E}, 'the branch is protected');
	like($said, qr{recorded the applied pipeline at}, 'the pipeline is recorded');
	unlike($said, qr/\balready\b/, 'and nothing is said to be in place');
};

subtest 'an unchanged re-run finds everything in place and writes nothing' => sub {
	# Ten rows, and one more for each of the three runs' restoration
	# assertions.
	plan tests => 13;

	my $h  = make_harness(envs => ['qa'], provider => 'manual', github => 1);
	my $gh = $h->gh;
	push_from($h, 'a', $h->control);
	run_genesis($h, 'pipeline-apply');

	my $writes = ruleset_writes($gh);
	my $at     = secret($h->applied_path . ':at');
	sleep 1; # an `at` rewritten in the same second would read unchanged

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the re-run exits 0');

	like($said, qr{already standing \Qqa/bosh\E}, 'the branch is already standing');
	like($said, qr{already protected \Q@{[$h->control]}\E}, 'control is already protected');
	like($said, qr{already protected \Qqa/bosh\E}, 'the branch is already protected');
	like($said, qr{already recorded the applied pipeline at},
		'the applied pipeline is already recorded');
	like($said, qr{already recorded qa with 0 dependencies},
		'and the environment is already recorded');
	unlike($said, qr{\b(?:created|updated)\b}, 'nothing is said to be new or changed');

	is(ruleset_writes($gh), $writes, 'no ruleset was sent');
	is(secret($h->applied_path . ':at'), $at,
		'the applied record was not rewritten, so its time stands');

	my ($dry) = unfolded(run_genesis($h, 'pipeline-apply', '--dry-run'));
	like($dry, qr{already protected \Qqa/bosh\E.*already recorded the applied pipeline}s,
		'the dry run finds the same');
};

subtest 'a re-run after a change says what changed' => sub {
	# Eleven rows, and one more for each of the three runs' restoration
	# assertions.
	plan tests => 14;

	my $h  = make_harness(envs => ['qa'], provider => 'manual', github => 1);
	my $gh = $h->gh;
	push_from($h, 'a', $h->control);
	run_genesis($h, 'pipeline-apply');
	my $was = control_sha($h);

	write_env_file($h, 'qa', pipeline => {require_pr => 'true'});
	push_from($h, 'a', $h->control);
	my $now = control_sha($h);

	my $writes = ruleset_writes($gh);
	my ($dry) = unfolded(run_genesis($h, 'pipeline-apply', '--dry-run'));
	like($dry, qr{would update protection on \Qqa/bosh\E, adding pull_request},
		'the dry run would update the branch, naming the rule it adds');
	like($dry, qr{already protected \Q@{[$h->control]}\E},
		'and finds control already protected');
	like($dry, qr{would update the applied pipeline, moving control from \Q@{[substr($was,0,8)]}\E to \Q@{[substr($now,0,8)]}\E},
		'and would move the applied record\'s control commit');
	is(ruleset_writes($gh), $writes, 'the dry run sent no ruleset');
	is(secret($h->applied_path . ':control_commit'), $was,
		'and wrote no record');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the re-run exits 0');
	like($said, qr{updated protection on \Qqa/bosh\E, adding pull_request},
		'the branch\'s protection is updated, naming the rule it adds');
	like($said, qr{already protected \Q@{[$h->control]}\E},
		'control is already protected');
	like($said, qr{updated the applied pipeline at \S+, moving control from \Q@{[substr($was,0,8)]}\E to \Q@{[substr($now,0,8)]}\E},
		'the applied record is updated from the old control commit to the new');
	is(ruleset_writes($gh), $writes + 1, 'one ruleset was sent');
	is(secret($h->applied_path . ':control_commit'), $now,
		'and the record carries the new control commit');
};

done_testing;
