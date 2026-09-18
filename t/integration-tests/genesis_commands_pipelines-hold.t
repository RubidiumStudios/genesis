#!/usr/bin/env perl
# Proves T298, that `genesis prod pipeline-hold "<reason>"` writes the record
# with its four fields and refuses without a reason; T301, that a standing hold
# stops delivery in both modes while the branch stays deployable and --dry-run
# still shows what waits; and T302, that the held environment records held,
# needs clearing with the reason and the right detail line.
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

subtest 'pipeline-hold writes the record with its four fields' => sub {
	# Ten rows, the first of which is the restoration this row asserts in
	# its own words, which is why the run is given restore => 0, and one
	# more for the refused run, which asserts its restoration for itself.
	plan tests => 10;

	my $h = held_prod_delivered();

	my $w = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'prod', 'pipeline-hold', 'waiting on the capacity report');
	assert_w_restored($w, 'the hold restored working state');
	is($exit, 0, 'the command succeeded');

	my $path = $h->env_path('prod').'/hold';
	is(secret("$path:reason"), 'waiting on the capacity report',
		'the reason is the one the operator gave');
	have_secret "$path:user";
	have_secret "$path:hostname";
	have_secret "$path:at";

	# A reason of several words left unquoted arrives as several arguments,
	# which is the likeliest mistake this command invites.  These three rows
	# are guards over what the operator meets, and they do not separate the
	# refusal of more than two arguments from the refusal of a missing
	# reason: a call carrying four arguments matches neither reading, so it
	# reaches the missing-reason refusal anyway, and the two answer with the
	# same code and the same usage block.  What tells them apart is the
	# sentence command_usage is given, and that sentence is printed only
	# outside a test run.  What the rows do hold is that the call is turned
	# away and that nothing it said reached the record.
	my ($said, $why, $refused) = run_genesis($h,
		'pipeline-hold', 'prod', 'waiting', 'on', 'capacity');
	is($refused, 2, 'an unquoted reason is refused with the usage code');
	like(unfolded($said, $why),
		qr/Usage: genesis pipeline-hold \[<env>\] "<reason>"/,
		'and answered with this command\'s own usage');
	is(secret("$path:reason"), 'waiting on the capacity report',
		'and left the standing record as it was');
};

subtest 'the reason is required' => sub {
	# Three rows, and one more for the restoration the run asserts for
	# itself, which run_genesis makes unless a row turns it off.
	#
	# The wording row is the one that discriminates.  An unrecognised command
	# exits 2 and writes nothing, so the exit row and the no_secret row both
	# passed before the command existed, and only a refusal that names the
	# reason says the command is there and turning this call away.
	plan tests => 4;

	my $h = held_prod_delivered();

	my ($out, $err, $exit) = run_genesis($h, 'prod', 'pipeline-hold');
	isnt($exit, 0, 'the command refused');
	like(unfolded($out, $err), qr/reason/i,
		'the refusal names the reason as required');
	no_secret $h->env_path('prod').'/hold';
};

subtest 'a hold stops delivery in direct mode' => sub {
	# Five rows, one of which is this row's own restoration assertion, and
	# one more for the hold run, which asserts its restoration for itself.
	plan tests => 6;

	my $h = held_prod_delivered();
	my $before = remote_sha($h, $h->slug('prod'));

	for my $n (1, 2) {
		commit_on_control($h,
			files   => {'prod.yml' => env_body('prod', $n)},
			message => "change prod $n", push => 1);
	}

	run_genesis($h, 'prod', 'pipeline-hold', 'waiting on the capacity report');

	my $w = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'propagate', '-y');
	assert_w_restored($w, 'the run restored working state');
	is($exit, 0, 'the run finished');
	is(remote_sha($h, $h->slug('prod')), $before,
		'nothing new reached the deployment branch');
	like(unfolded($out, $err),
		qr/held, needs clearing \(waiting on the capacity report\)/,
		'the environment records held, needs clearing with the reason');
	unlike(unfolded($out, $err), qr/\bidempotent\b/,
		'a hold outranks idempotent, so the word never appears');
};

subtest 'a hold stops the pull request in PR mode' => sub {
	# Four rows, and one more for each of the two runs' own restoration
	# assertions.  The double is the one held_prod stood, because a second
	# one built over it would discard whatever the builder set on the first.
	#
	# The last two rows guard the pull-request path until that path exists.
	# The walk does not reach the hold in PR mode today, because propagate
	# records `not attempted, because delivery by pull request is not built
	# yet` and carries on past the environment before it reads the hold, so
	# what those rows hold true of is a run that opened nothing because it
	# opened nothing at all.  They say what the hold must go on meaning once
	# the path lands.  The first two rows are this task's own, and neither
	# could pass before the command existed: the hold has to be settable in
	# a repository whose environments deliver by pull request, and the
	# record it wrote has to still be standing once the run has been past.
	plan tests => 6;

	my $h  = held_prod_delivered(mode => 'pr', github => 1);
	my $gh = $h->{gh};

	commit_on_control($h,
		files   => {'prod.yml' => env_body('prod', 1)},
		message => 'change prod', push => 1);

	my (undef, undef, $held) = run_genesis($h,
		'prod', 'pipeline-hold', 'waiting on the capacity report');
	is($held, 0, 'the hold was recorded in a pull-request repository');

	run_genesis($h, 'propagate', '-y');

	is(secret($h->env_path('prod').'/hold:reason'),
		'waiting on the capacity report',
		'the hold still stands once the run has been past');
	is(scalar(grep {$_->{method} eq 'POST' && $_->{url} =~ m{/pulls}} gh_calls($gh)),
		0, 'no pull request was opened or updated');
	# --verify --quiet, because a bare rev-parse echoes the name it could not
	# resolve back on stdout and a row reading that would call an absent
	# branch present.
	my ($exists) = run({dir => $h->a, passfail => 0, stderr => 0},
		'git', 'rev-parse', '--verify', '--quiet',
		'refs/remotes/origin/'.$h->pr_branch('prod'));
	ok(!$exists, 'no pull-request branch was pushed');
};

subtest 'dry-run shows what waits behind the hold' => sub {
	# Three rows, and one more for each of the two runs' own restoration
	# assertions.
	#
	# The detail-line row is the one that discriminates.  A dry run with no
	# hold standing lists the same commits, so the row matching the first
	# waiting commit's sha would have passed before the command existed, and
	# the count of what the hold is blocking is what only a held environment
	# can say.  The sha instrument is the house one, and
	# genesis_ci_walk-hold_record.t proves the same clause the same way.
	plan tests => 5;

	my $h = held_prod_delivered();

	my @due;
	for my $n (1, 2) {
		push @due, commit_on_control($h,
			files   => {'prod.yml' => env_body('prod', $n)},
			message => "change prod $n", push => 1);
	}
	run_genesis($h, 'prod', 'pipeline-hold', 'waiting on the capacity report');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the preview finished');
	like($said, qr/\Q@{[substr($due[0], 0, 7)]}\E/,
		'the first waiting commit is listed');
	like($said, qr/2 commits are blocked until this hold is released/,
		'the detail line names the count');
};

subtest 'the outcome stands with nothing due' => sub {
	# Two rows, and one more for each of the two runs' own restoration
	# assertions.
	plan tests => 4;

	my $h = held_prod_delivered();
	run_genesis($h, 'prod', 'pipeline-hold', 'waiting on the capacity report');

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);
	like($said, qr/held, needs clearing \(waiting on the capacity report\)/,
		'the outcome stands whether or not anything is due');
	like($said,
		qr/nothing is due now, and anything that becomes due stays blocked/,
		'the nothing-due detail line is the one the design spells');
};

done_testing;
