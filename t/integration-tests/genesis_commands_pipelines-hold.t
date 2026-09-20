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
	# more for each of the two refused runs, which assert their restoration
	# for themselves.
	plan tests => 12;

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
	# which is the likeliest mistake this command invites.  It matches
	# neither of the two readings, so both names stay undefined and it meets
	# the one refusal this command has, the one that asks for a reason, whose
	# sentence names the quoting for exactly this caller.
	#
	# These three rows are guards over what the operator meets, and none of
	# them can fail while any refusal stands in that position: the exit code
	# and the usage block are command_usage's whatever sentence it was given.
	# The row below them is the one that reads the sentence itself.
	my ($said, $why, $refused) = run_genesis($h,
		'pipeline-hold', 'prod', 'waiting', 'on', 'capacity');
	is($refused, 2, 'an unquoted reason is refused with the usage code');
	like(unfolded($said, $why),
		qr/Usage: genesis pipeline-hold \[<env>\] "<reason>"/,
		'and answered with this command\'s own usage');
	is(secret("$path:reason"), 'waiting on the capacity report',
		'and left the standing record as it was');

	# command_usage prints the sentence it was given only outside a test
	# run, taking the whole branch at Genesis::Commands:994 when
	# GENESIS_TESTING is set, so the one run in this file that reads a
	# refusal's own words is made with the variable taken away.  Everything
	# else about the run is unchanged, and it is the only reading under
	# which an operator ever meets the sentence.
	my ($told, $how) = do {
		delete local $ENV{GENESIS_TESTING};
		# Taking GENESIS_TESTING away also takes away the vault's reason not
		# to prompt.  Stdout is a pipe here, so the vault finds no
		# controlling terminal and asks for nothing either way, and this
		# line says so rather than leaving it to how the run is plumbed.
		local $ENV{GENESIS_NONINTERACTIVE} = 1;
		run_genesis($h, 'pipeline-hold', 'prod', 'waiting', 'on', 'capacity');
	};
	like(unfolded($told, $how), qr/reason of more than one word has to be quoted/,
		'and told to quote a reason of several words');
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

subtest 'a file of the root named alone is a mistyped environment' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	#
	# Genesis reads an environment out of `<env>.yml` alone, so a root that
	# also holds a `prod.yaml` gives an operator two spellings and only one
	# of them resolves.  Named on its own the other one used to be read as a
	# reason, which held every environment in the root and wrote the
	# filename in as why, so all four rows below fail without the refusal.
	#
	# The run is made with GENESIS_TESTING taken away, for the reason the
	# first subtest gives: the sentence that names the file is the point of
	# this refusal, and command_usage prints it only outside a test run.
	plan tests => 5;

	my $h = held_prod_delivered(envs => ['lab', 'prod']);
	$h->commit_on_control(
		files   => {'prod.yaml' => "---\nstray: true\n"},
		message => 'Leave a stray file beside prod',
		push    => 1,
	);

	my ($out, $err, $exit) = do {
		delete local $ENV{GENESIS_TESTING};
		# Taking GENESIS_TESTING away also takes away the vault's reason not
		# to prompt.  Stdout is a pipe here, so the vault finds no
		# controlling terminal and asks for nothing either way, and this
		# line says so rather than leaving it to how the run is plumbed.
		local $ENV{GENESIS_NONINTERACTIVE} = 1;
		run_genesis($h, 'pipeline-hold', 'prod.yaml');
	};
	is($exit, 2, 'the call is refused with the usage code');
	like(unfolded($out, $err), qr/prod\.yaml.*is a file in this deployment root/,
		'and the refusal names the file rather than reading it as a reason');

	no_secret $h->env_path('prod').'/hold';
	no_secret $h->env_path('lab').'/hold';
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
	# Six rows, and one more for each of the two runs' own restoration
	# assertions.  The double is the one held_prod stood, because a second
	# one built over it would discard whatever the builder set on the first.
	#
	# The last four rows are about the hold and not about a path that is
	# missing.  The run reaches the pull request arm for this environment
	# and the arm reads the hold: the walk sends the due commit to held and
	# leaves nothing pending, Genesis::CI::PullRequest::deliver reads that
	# held list before it decides whether to retire the branch, and the
	# idempotent word it answers for an environment with nothing due is set
	# aside where anything is held, so the report settles the environment as
	# held instead.  What the four say together is that the hold is what
	# stopped the pull request, the listings row being what says the arm was
	# taken at all.  With the walk's own apply_hold taken out the commit
	# stays pending, the arm opens a pull request and pushes its branch, and
	# three of the four go red.
	#
	# The first two rows are this task's own, and neither could pass before
	# the command existed: the hold has to be settable in a repository whose
	# environments deliver by pull request, and the record it wrote has to
	# still be standing once the run has been past.
	plan tests => 8;

	my $h  = held_prod_delivered(mode => 'pr', github => 1);
	my $gh = $h->{gh};

	# Laid through the harness rather than out of a body of this row's own,
	# because the run reads genesis.pipeline.require_pr out of the very file
	# the commit writes.  A body composed here drops that key, and the whole
	# pull request arm goes with it: the run delivers straight to prod/bosh
	# and every row below is answered by an arm nobody meant to test.
	due_commit($h, 'prod', params => {instances => 2},
		message => 'raise the instance count');

	my (undef, undef, $held) = run_genesis($h,
		'prod', 'pipeline-hold', 'waiting on the capacity report');
	is($held, 0, 'the hold was recorded in a pull-request repository');

	my ($out, $err) = run_genesis($h, 'propagate', '-y');

	is(secret($h->env_path('prod').'/hold:reason'),
		'waiting on the capacity report',
		'the hold still stands once the run has been past');
	like(unfolded($out, $err),
		qr/prod: held, needs clearing \(waiting on the capacity report\)/,
		'the run settles prod as held rather than as an environment it has '.
		'nothing to say about');
	# A guard on the arm the two rows below are about.  Only an environment
	# the run delivers by pull request has its listings read, so a run that
	# took the direct arm asks nothing here, and without this row the two
	# below would be answered by an arm that opens no pull request because
	# it never goes near one.
	ok(scalar(grep {$_->{method} eq 'GET' && $_->{url} =~ m{/pulls}}
		gh_calls($gh)),
		'the run read the pull request listings, so it took that arm');
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
