#!/usr/bin/env perl
# Proves T300, that `genesis pipeline-hold "<reason>"` with no environment
# argument holds every environment in the deployment root, that `genesis
# pipeline-release` clears every one of them, and that neither touches an
# environment of a second deployment root in the same repository.
#
# The two commands were written with their loops already over the environments
# the argument selects, so every row here reads behaviour that landed with the
# commands themselves and none of them drove it.  Each subtest says below it
# which of its rows discriminates and what turns that row red, and the report
# for this task carries the runs that proved each one.  T320 proves the other
# half of the two-root claim, that the two roots compose different slugs and
# different Exodus paths; what is proved here is that the two commands read one
# root's topology and write one root's paths.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the no-argument hold covers the root and stops there' => sub {
	# Six rows, the first of which is the restoration this row asserts in
	# its own words, which is why the run is given restore => 0.
	#
	# The two reason rows are what discriminate the covering: a hold whose
	# loop ran over nothing exits 0 and says nothing, and both of them go
	# red.  The naming row is what discriminates the stopping, and it counts
	# rather than matching a root, because both roots carry the same two
	# environment names and a name alone cannot say which root it came from.
	# An enumeration that walked into the nested root would name four
	# environments here instead of two, and the row goes red for it.  The
	# last row is a guard over the path composition T320 owns, and it holds
	# because each root's Exodus path carries that root's own type.
	plan tests => 6;

	my $h = two_roots();

	my $w = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'pipeline-hold', 'freezing the fleet for the audit');
	assert_w_restored($w, 'the hold restored working state');
	is($exit, 0, 'the command succeeded');

	for my $env (qw(lab prod)) {
		is(secret($h->env_path($env).'/hold:reason'),
			'freezing the fleet for the audit',
			"$env of the bosh root is held");
	}

	my @named = sort(unfolded($out, $err) =~ /Propagation to (\S+) is held/g);
	is_deeply(\@named, ['lab', 'prod'],
		'the run named the two environments of its own root and no others');

	no_secret $h->env_path('prod', type => 'vault').'/hold';
};

subtest 'the no-argument release clears the root and stops there' => sub {
	# Five rows, and one more for each of the three runs' own restoration
	# assertions.  The second root is named by the bare directory, because
	# run_genesis appends dir to the copy's own path.
	#
	# The two no_secret rows are what discriminate the covering: a release
	# whose loop ran over nothing leaves both records standing and both go
	# red.  The naming row is what discriminates the stopping, and it counts
	# for the reason the subtest above gives.  The last row is the guard
	# T320's path composition carries, as in the subtest above.
	plan tests => 8;

	my $h = two_roots();
	run_genesis($h, 'pipeline-hold', 'freezing the fleet for the audit');
	run_genesis($h, {dir => 'vault'},
		'prod', 'pipeline-hold', 'the vault root holds its own');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-release');
	is($exit, 0, 'the command succeeded');

	no_secret $h->env_path('lab').'/hold';
	no_secret $h->env_path('prod').'/hold';

	my @named = sort(unfolded($out, $err)
		=~ /Released the propagation hold on (\w+),/g);
	is_deeply(\@named, ['lab', 'prod'],
		'the run named the two environments of its own root and no others');

	is(secret($h->env_path('prod', type => 'vault').'/hold:reason'),
		'the vault root holds its own',
		"the other root's hold on the same environment name is untouched");
};

subtest 'the reason is still required without an environment' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	#
	# The wording row is the one that discriminates, as it is in the hold's
	# own file: an unrecognised command exits 2 and writes nothing, so the
	# exit row and the no_secret row would both stand without the command.
	plan tests => 4;

	my $h = two_roots();

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-hold');
	isnt($exit, 0, 'the command refused');
	like(unfolded($out, $err), qr/reason/i,
		'the refusal names the reason as required');
	no_secret $h->env_path('lab').'/hold';
};

subtest 'the whole-root forms refuse where the root selects nothing' => sub {
	# Eight rows, and one more for each of the two runs' own restoration
	# assertions.  Both commands are asked, because both read the root
	# through one sub and the POD promises the refusal for each of them.
	#
	# Every row discriminates: without the refusal each command's loop runs
	# over an empty list, exits 0, and prints nothing, which is the silent
	# success this subtest exists to keep out.  The two cause rows per
	# command hold the sentence to naming both of the things that put a root
	# in this state, since an operator whose pipeline is merely switched off
	# would otherwise be sent to read their environment files.
	plan tests => 10;

	my $h = make_harness(envs => ['prod'], pipeline => 0);

	my ($out, $err, $exit) = run_genesis($h,
		'pipeline-hold', 'freezing the fleet for the audit');
	is($exit, Genesis::Exit::CONFIG, 'it exits CONFIG');
	like(unfolded($out, $err), qr/No environments with pipeline metadata/i,
		'and says that the root selects none rather than holding nothing quietly');
	like(unfolded($out, $err), qr/pipeline\.enabled/,
		'and names the switched-off pipeline as one of the two causes');
	like(unfolded($out, $err), qr/genesis\.pipeline/,
		'and the undeclared metadata as the other');

	my ($said, $why, $refused) = run_genesis($h, 'pipeline-release');
	is($refused, Genesis::Exit::CONFIG, 'the release exits CONFIG too');
	like(unfolded($said, $why), qr/No environments with pipeline metadata/i,
		'and is refused in the same words, through the same sub');
	like(unfolded($said, $why), qr/pipeline\.enabled/,
		'naming the switched-off pipeline as the hold does');
	like(unfolded($said, $why), qr/genesis\.pipeline/,
		'and the undeclared metadata beside it');
};

subtest "the second root's own no-argument forms stop at that root" => sub {
	# Four rows, and one more for each of the three runs' own restoration
	# assertions.  The subtests above run both commands from the first root
	# and watch the second stay still; this one runs them from the second
	# root and watches the first, which is the other direction of the same
	# claim and the one an operator standing in a nested root meets.
	#
	# The vault rows are what discriminate the covering, and go red for a
	# loop that ran over nothing the way the rows above them do.  The two
	# rows that read the bosh reason are guards over the enumeration's scope
	# and over the path composition, which T320 owns: the topology is read
	# with a single-level listing of one root's own directory, and both
	# loops compose every path through that root's own Genesis::Top, so no
	# run here can cross into the other root for either row to catch.
	plan tests => 7;

	my $h = two_roots();
	run_genesis($h, 'pipeline-hold', 'freezing the fleet for the audit');
	run_genesis($h, {dir => 'vault'},
		'pipeline-hold', 'the vault root holds its own');

	is(secret($h->env_path('prod', type => 'vault').'/hold:reason'),
		'the vault root holds its own',
		'prod of the vault root is held');
	is(secret($h->env_path('prod').'/hold:reason'),
		'freezing the fleet for the audit',
		"and the first root's hold on the same name was not written over");

	run_genesis($h, {dir => 'vault'}, 'pipeline-release');

	no_secret $h->env_path('prod', type => 'vault').'/hold';
	is(secret($h->env_path('prod').'/hold:reason'),
		'freezing the fleet for the audit',
		"and the first root's hold outlived the second root's release");
};

done_testing;
