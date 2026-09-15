#!/usr/bin/env perl
# Proves T157: the run switches to control inside its session, restores the
# branch the operator stood on, refuses nobody for standing off control, and
# creates the local control ref from R where the copy lacks one.
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

subtest 'a copy with no local control ref creates it from R' => sub {
	plan tests => 3;

	my $h = ready_harness(delivered => [], certified => ['lab'],
		kit => 'omega-v2.7.0');
	my $control = $h->control;
	run({dir => $h->a}, 'git', 'checkout', '-b', 'feature/only');
	delete_local($h, 'a', $control);

	my $w = snapshot_w($h);
	my (undef, undef, $exit) = run_genesis($h, {restore => 0}, 'propagate');

	isnt($exit, Genesis::Exit::DATAERR, 'a missing local ref is no refusal');
	my ($local) = run({dir => $h->a, passfail => 0},
		'git', 'rev-parse', "refs/heads/$control");
	ok($local, 'the local control ref now exists');
	assert_w_restored($w, 'propagate with no local control ref');
};

done_testing;
