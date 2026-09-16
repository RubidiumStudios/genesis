#!/usr/bin/env perl
# Proves T147: the withdrawn flags are refused at exit 2, and --dry-run
# names, per environment and per control commit, the files that would land
# and whether each commit would be delivered or held and why.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the withdrawn flags are usage errors' => sub {
	# Two rows, and one more for each run's own restoration assertion.
	plan tests => 4;

	my $h = make_harness(envs => ['qa']);
	fixture_applied($h, control => $h->git('a')->sha($h->control));

	my (undef, undef, $push_exit) = run_genesis($h, 'propagate', '--no-push');
	is($push_exit, 2, '--no-push is refused');

	my (undef, undef, $commit_exit) =
		run_genesis($h, 'propagate', '--commit', 'deadbeef');
	is($commit_exit, 2, '--commit is refused');
};

subtest 'the preview names each commit, its files, and its verdict' => sub {
	# Nine rows, and one more for the run's own restoration assertion.
	plan tests => 10;

	my $h = ready_harness(envs => ['lab', 'qa'], kit => 'omega-v2.7.0',
		chained => 1, tracked => ['ops/shared.yml']);

	# The environment file as the harness laid it down, with one key added,
	# so the commit below changes a file qa's set holds and this file keeps
	# no second copy of the harness's own body.
	my $qa_yml = blob_at($h->a, $h->control, 'qa.yml');

	my $first = commit_on_control($h,
		files   => {'qa.yml' => $qa_yml . "leaf: 1\n"},
		message => 'Tune qa', push => 1);
	certify($h, 'lab', control_commit => $first);
	my $second = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: 3\n"},
		message => 'Bump shared ops', push => 1);

	my $tip_before = harness_marker($h, $h->slug('qa'));
	my $w = snapshot_w($h);

	# Both streams are read from the second value, because the run speaks
	# through info and everything Genesis says about itself goes to standard
	# error.
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');

	is($exit, 0, 'the preview succeeded');
	like($err, qr/This is a preview\.\s+Nothing will be written\./,
		'it says it is a preview before it says anything else');
	like($err, qr/^\s*qa\b/m, 'it names the environment');
	like($err, qr/^\s*qa:\s*would propagate/m,
		'an environment with commits due reads would propagate');
	like($err, qr/\Q@{[substr($first, 0, 7)]}\E.*would deliver/,
		'the first commit reads would deliver');
	like($err, qr/\Q@{[substr($first, 0, 7)]}\E[\s\S]*?\Qqa.yml\E/,
		'the files that would land are named');
	like($err, qr/\Q@{[substr($second, 0, 7)]}\E.*held/,
		'the second reads held with its reason');
	is(harness_marker($h, $h->slug('qa')), $tip_before,
		'the preview wrote nothing');
	assert_w_restored($w, 'propagate --dry-run');
};

done_testing;
