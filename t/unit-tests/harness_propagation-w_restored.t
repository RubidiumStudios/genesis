#!/usr/bin/env perl
# Proves T3: assert_w_restored compares all five parts of working state and
# fails naming what differed, against four fixture commands, and that a run
# through run_genesis hands back the exit code the command really exited with.
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
sub outcome_of {
	my ($w, $name) = @_;
	my $builder = Test::Builder->create;
	$builder->output(\my $out);
	$builder->failure_output(\my $err);
	$builder->todo_output(\my $todo);
	my $passed = do {
		local $Harness::Propagation::BUILDER = $builder;
		assert_w_restored($w, $name);
	};
	# A passing assertion writes nothing to either handle, so both are taken
	# as empty rather than concatenated while still undefined.
	return ($passed ? 1 : 0, ($out // '') . ($err // ''));
}

subtest 'a command that switches and returns passes' => sub {
	plan tests => 1;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $w = snapshot_w($h);
	fixture_command($h, 'restores')->();
	my ($passed) = outcome_of($w, 'switches and returns');

	ok($passed, 'the assertion passes when every part is restored');
};

subtest 'a command left on another branch fails naming the branch' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $w = snapshot_w($h);
	fixture_command($h, 'leaves_branch')->();
	my ($passed, $said) = outcome_of($w, 'left on another branch');

	ok(!$passed, 'the assertion fails');
	like($said, qr/branch/, 'it names the branch as what differed');
};

subtest 'a command that leaves a file staged fails naming the index' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);

	my $w = snapshot_w($h);
	fixture_command($h, 'leaves_staged')->();
	my ($passed, $said) = outcome_of($w, 'left a file staged');

	ok(!$passed, 'the assertion fails');
	like($said, qr/index/, 'it names the index as what differed');
};

subtest 'a command whose directory the switch removed fails naming the cwd' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);

	my $w = snapshot_w($h);
	fixture_command($h, 'loses_cwd')->();
	my ($passed, $said) = outcome_of($w, 'sat in a removed directory');

	ok(!$passed, 'the assertion fails');
	like($said, qr/directory/, 'it names the current directory as what differed');
};

subtest 'a run answers the exit code the command really exited with' => sub {
	# The four are the restoration the run asserts for itself and the three
	# rows below it.
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], vault => 0);

	my ($out, $err, $rc) = run_genesis($h, 'no-such-command');

	isnt($rc, 0, 'an unrecognised command fails');
	like($err, qr/no-such-command/,
		'the second value is the error the command wrote');

	# Genesis exits 2 on a usage error, and a code shifted a second time
	# would read as 0 here, which is what this row is for.
	is($rc, 2, 'the code is the one the command exited with');
};

done_testing;
