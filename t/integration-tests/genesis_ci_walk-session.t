#!/usr/bin/env perl
# Proves T157: the run switches to control inside its session, restores the
# branch the operator stood on, refuses nobody for standing off control,
# turns away a copy whose control branch is on the remote alone, and reads
# the topology control carries even when it only previews.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/run/;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a run from a feature branch walks and restores' => sub {
	plan tests => 4;

	my $h = ready_harness(delivered => [], certified => ['lab'],
		kit => 'omega-v2.7.0');
	run({dir => $h->a}, 'git', 'checkout', '-b', 'feature/tune-qa');
	stand_on($h, 'feature/tune-qa');

	my $w = snapshot_w($h);
	my (undef, $err, $exit) = run_genesis($h, {restore => 0}, 'propagate');

	isnt($exit, Genesis::Exit::DATAERR, 'standing off control is no refusal');
	unlike($err, qr/must be run from/, 'the old refusal is gone');
	is(branch_of($h->a), 'feature/tune-qa',
		'the operator is back on the feature branch');
	assert_w_restored($w, 'propagate from a feature branch');
};

subtest 'the walk reads control and not the branch it was run from' => sub {
	# Three rather than two, because this row lets run_genesis assert the
	# restoration in its own words rather than asking for it again here.
	plan tests => 3;

	my $h = ready_harness(delivered => [], certified => ['lab'],
		kit => 'omega-v2.7.0');
	# The change is appended to the file control already carries, so the
	# environment keeps the shape the topology is read out of and the only
	# thing this row varies is which branch the run reads it from.
	my $due = commit_on_control($h,
		files   => {'qa.yml' => slurp($h->a . '/qa.yml') . "\n# tuned\n"},
		message => 'Tune qa',
		push    => 1,
	);
	run({dir => $h->a}, 'git', 'checkout', '-b', 'feature/elsewhere');
	run({dir => $h->a}, 'git', 'rm', '-q', 'qa.yml');
	run({dir => $h->a}, 'git', 'commit', '-qm',
		'remove qa on the feature branch');
	stand_on($h, 'feature/elsewhere');

	run_genesis($h, 'propagate');

	# Read off the branch the run wrote to rather than out of its report,
	# because the file the feature branch dropped is the one the delivery
	# has to carry, and only the tree says whether it does.
	ok(in_set('qa.yml', @{tree_of($h->r, $h->slug('qa'))}),
		'the walk delivered the file control holds');
	is(harness_marker($h, $h->slug('qa')), $due,
		'the delivery names the control commit and not the feature branch');
};

subtest 'a copy with control only on the remote is turned away' => sub {
	# Four rather than three, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 4;

	my $h = ready_harness(delivered => [], certified => ['lab'],
		kit => 'omega-v2.7.0');
	my $control = $h->control;
	# The local ref goes while the copy stands on it, which leaves control
	# unborn here and on the remote.  The refresh writes the local ref for a
	# branch this clone lacks, except for the branch the working tree is
	# standing on, because git refuses to fetch into the ref HEAD points at,
	# so this is the shape in which the ref is still missing by the time the
	# pre-flight asks for it.
	delete_local($h, 'a', $control);

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR,
		'a control branch this clone lacks is refused as data');
	like($err, qr/not in this clone/,
		'the refusal names the clone that lacks the branch');
	ok(!defined ref_in($h->a, "refs/heads/$control"),
		'the run wrote no control ref of its own');
};

subtest 'a dry run reads the topology control carries' => sub {
	# Three rather than two, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 3;

	my $h = ready_harness(delivered => [], certified => ['lab'],
		kit => 'omega-v2.7.0');
	commit_on_control($h,
		files   => {'qa.yml' => slurp($h->a . '/qa.yml') . "\n# tuned\n"},
		message => 'Tune qa',
		push    => 1,
	);
	# The feature branch drops the environment file, so qa is in the
	# topology control carries and in no other.  A dry run that read the
	# branch the operator stood on would have nothing to say about qa.
	run({dir => $h->a}, 'git', 'checkout', '-b', 'feature/elsewhere');
	run({dir => $h->a}, 'git', 'rm', '-q', 'qa.yml');
	run({dir => $h->a}, 'git', 'commit', '-qm',
		'remove qa on the feature branch');
	stand_on($h, 'feature/elsewhere');

	my ($err) = (run_genesis($h, 'propagate', '--dry-run'))[1];

	# Two, because nothing has been delivered to qa, so the seeding commit
	# is due beside the one this row laid down.
	like($err, qr{^\s*qa:\s+would deliver 2 commits}m,
		'the preview names the environment only control knows about');
	unlike($err, qr/No environments with pipeline metadata found/,
		'the topology was not read off the feature branch');
};

done_testing;
