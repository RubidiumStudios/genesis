#!/usr/bin/env perl
# Proves T137, T138, and T176: three due commits arrive as three deliveries
# in control order, files that change together travel together, and the
# snapshot invariant is asserted after every delivered commit.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'three due commits become three deliveries in control order' => sub {
	# Six rather than five, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 6;

	my $h = ready_harness(delivered => ['qa'], certified => ['lab', 'qa'],
		kit => 'omega-v2.7.0');
	my @due;
	for my $n (1 .. 3) {
		push @due, commit_on_control($h,
			files   => {'qa.yml' =>
				"---\nkit:\n  name: dev\ngenesis:\n  env: qa\nn: $n\n"},
			message => "Tune qa, step $n",
			push    => 1,
		);
		certify($h, 'lab', control_commit => $due[-1]);
	}

	my (undef, undef, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, 0, 'the run succeeded');

	my @subjects = subjects_of($h, $h->slug('qa'), 3);
	is(scalar(@subjects), 3, 'three commits landed');
	for my $i (0 .. 2) {
		my $short = substr($due[$i], 0, 7);
		like($subjects[$i], qr/\Qcontrol\E\@\Q$short\E/,
			"delivery $i names control commit $i");
	}
};

subtest 'files that change together travel in one commit' => sub {
	plan tests => 4;

	my $h = ready_harness(delivered => ['qa'], certified => ['lab', 'qa'],
		kit => 'omega-v2.7.0');
	# qa tracks the shared ops file, because the propagation set holds the
	# ops files an environment declares and the ones the kit's blueprint
	# names, and the kit here names none.
	my $both = commit_on_control($h,
		files => {
			'ops/shared.yml' => "---\nshared: 2\n",
			'qa.yml'         => "---\nkit:\n  name: dev\ngenesis:\n"
			                  . "  env: qa\n  pipeline:\n"
			                  . "    track_additional_files:\n"
			                  . "    - ops/shared.yml\nleaf: 2\n",
		},
		message => 'Bump shared ops and tune qa',
		push    => 1,
	);
	certify($h, 'lab', control_commit => $both);

	run_genesis($h, {answers => ['y']}, 'propagate');

	my ($names) = run({dir => $h->a}, 'git', 'show', '--name-only',
		'--format=', "refs/remotes/origin/".$h->slug('qa'));
	my @files = sort grep {/\S/} split /\n/, $names;
	is(scalar(@files), 2, 'one commit carries both files');
	is($files[0], 'ops/shared.yml', 'the shared file is in it');
	is($files[1], 'qa.yml', 'the leaf file is in it');
};

subtest 'the snapshot invariant holds after every delivered commit' => sub {
	plan tests => 4;

	my $h = ready_harness(delivered => ['qa'], certified => ['lab', 'qa'],
		kit => 'omega-v2.7.0');
	my @due;
	for my $n (1 .. 3) {
		push @due, commit_on_control($h,
			files   => {'qa.yml' =>
				"---\nkit:\n  name: dev\ngenesis:\n  env: qa\nn: $n\n"},
			message => "Tune qa, step $n",
			push    => 1,
		);
		certify($h, 'lab', control_commit => $due[-1]);
	}

	run_genesis($h, {answers => ['y']}, 'propagate');

	my ($log) = run({dir => $h->a}, 'git', 'log', '--format=%H', '-3',
		'refs/remotes/origin/'.$h->slug('qa'));
	my @commits = reverse grep {/\S/} split /\n/, $log;
	for my $i (0 .. 2) {
		assert_snapshot_invariant($h, 'qa',
			commit => $commits[$i],
			name   => "qa at delivery $i",
		);
	}
};

subtest 'an environment that takes a pull request is delivered onto its own branch' => sub {
	plan tests => 4;

	# pr mode writes genesis.pipeline.require_pr on the environment file,
	# which is the per-environment key that says a delivery has to arrive as
	# a proposal rather than as a push.
	my $h = ready_harness(envs => ['qa'], mode => 'pr',
		kit => 'omega-v2.7.0');
	# The kit is triggering content of every environment's set, so the
	# commit routes to qa without the environment file being rewritten and
	# the require_pr declaration lost with it.
	my $due = commit_on_control($h,
		files   => {'dev/notes.txt' => "a note beside the kit\n"},
		message => 'Note something beside the kit',
		push    => 1,
	);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');
	isnt(harness_marker($h, $h->slug('qa')), $due,
		'nothing reached the deployment branch');
	is(harness_marker($h, $h->pr_branch('qa'), copy => 'r'), $due,
		'and the pull request branch carries the aggregate instead');
	like($err, qr/qa: propagated/,
		'the environment reads as delivered rather than passed over');
};

done_testing;
