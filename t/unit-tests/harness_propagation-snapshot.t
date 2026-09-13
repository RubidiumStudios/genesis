#!/usr/bin/env perl
# Proves T4: the snapshot assertion compares the whole propagation set against
# the source the delivery was taken from, and names the file that differs.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Builder;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Run the assertion against a private Test::Builder so a deliberate failure is
# read as a result rather than failing this file.
sub invariant_outcome_of {
	my ($h, $env, %opts) = @_;
	my $builder = Test::Builder->create;
	$builder->output(\my $out);
	$builder->failure_output(\my $err);
	$builder->todo_output(\my $todo);
	my $passed = do {
		local $Harness::Propagation::BUILDER = $builder;
		assert_snapshot_invariant($h, $env, %opts);
	};
	# A passing assertion writes nothing to either handle, so both are taken
	# as empty rather than concatenated while still undefined.
	return ($passed ? 1 : 0, ($out // '') . ($err // ''));
}

subtest 'a faithful delivery passes' => sub {
	plan tests => 1;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $control = commit_on_control($h,
		files => {
			'qa.yml'         => "---\nkit: dev\n",
			'ops/shared.yml' => "---\nshared: true\n",
		},
		message => 'change qa',
		push    => 1,
	);
	deliver($h, 'qa', control => $control, copy => 'a');

	my ($passed) = invariant_outcome_of($h, 'qa');
	ok($passed, 'the branch mirrors the marker\'s control commit');
};

subtest 'one file left at its old content fails naming that file' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: was\n"},
		message => 'the old content',
		push    => 1,
	);
	my $control = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: is\n", 'qa.yml' => "---\nkit: dev\n"},
		message => 'the new content',
		push    => 1,
	);

	deliver($h, 'qa', control => $control, copy => 'a',
		corrupt => {'ops/shared.yml' => "---\nshared: was\n"});

	my ($passed, $said) = invariant_outcome_of($h, 'qa');
	ok(!$passed, 'the assertion fails');
	like($said, qr{ops/shared\.yml}, 'it names the file that differs');
	unlike($said, qr{qa\.yml}, 'it does not name a file that matches');
};

subtest 'a leftover path outside the set fails' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	deliver($h, 'qa', control => $control, copy => 'a', keep => ['init']);

	my ($passed, $said) = invariant_outcome_of($h, 'qa');
	ok(!$passed, 'the assertion fails on a path the set no longer holds');
	like($said, qr{\binit\b}, 'it names the leftover path');
};

done_testing;
