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

# The environment file each row commits by hand.  It has to stay a valid
# environment file with its pipeline metadata intact, because the run reads
# the topology out of these files and an environment that no longer declares
# one drops out of the root the walk enumerates.  The counter is there
# because a commit needs a delta to make.
sub env_body {
	my ($n) = @_;
	return "---\nkit:\n  name:    dev\n  version: latest\n  features: []\n"
	     . "genesis:\n  env: prod\nn: $n\n";
}

# The kit goes with every shape, since a run that walks an environment loads
# it and an environment with no kit on disk cannot be loaded.  prod is
# delivered and certified at the seeding commit as well, because the rows
# below count what is due and a branch carrying no marker is walked from the
# commit that introduced the environment, which would put the seeding commit
# in every count.
sub held {
	return held_prod(kit => 'omega-v2.7.0',
		delivered => ['prod'], certified => ['prod'], @_);
}

subtest 'pipeline-hold writes the record with its four fields' => sub {
	# Six rows, the first of which is the restoration this row asserts in
	# its own words, which is why the run is given restore => 0.
	plan tests => 6;

	my $h = held();

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
};

subtest 'the reason is required' => sub {
	# Three rows, and one more for the restoration the run asserts for
	# itself, which run_genesis makes unless a row turns it off.
	plan tests => 4;

	my $h = held();

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

	my $h = held();
	my $before = remote_sha($h, $h->slug('prod'));

	for my $n (1, 2) {
		commit_on_control($h,
			files   => {'prod.yml' => env_body($n)},
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

	my $h  = held(mode => 'pr', github => 1);
	my $gh = $h->{gh};

	commit_on_control($h,
		files   => {'prod.yml' => env_body(1)},
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
	my ($exists) = run({dir => $h->{a}, passfail => 0, stderr => 0},
		'git', 'rev-parse', '--verify', '--quiet',
		'refs/remotes/origin/'.$h->pr_branch('prod'));
	ok(!$exists, 'no pull-request branch was pushed');
};

subtest 'dry-run shows what waits behind the hold' => sub {
	# Three rows, and one more for each of the two runs' own restoration
	# assertions.
	plan tests => 5;

	my $h = held();

	my @due;
	for my $n (1, 2) {
		push @due, commit_on_control($h,
			files   => {'prod.yml' => env_body($n)},
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

	my $h = held();
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
