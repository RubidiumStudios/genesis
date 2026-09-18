#!/usr/bin/env perl
# Proves T266 and T183: the pull request branch is pushed against the tip the
# run read before it rebuilt the branch, a branch somebody moved on R since
# then has that one push rejected while every other branch publishes, and a
# branch the remote has never had is pushed against the empty object name.
#
# Both rows below propagate twice over a branch R already carries, which is
# the rewrite the expected tip exists to permit, and neither of them could
# reach its own subject if that second push were refused as a
# non-fast-forward.  That is the condition T261's second half stands on rather
# than the clause itself, which is asserted in
# genesis_ci_pullrequest-title.t, so no row here reads a marker, a title, or a
# supersedes list.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a branch moved on R has its own push rejected' => sub {
	plan tests => 8;

	my $h   = ready(envs => ['qa', 'prod'], kit => 'omega-v2.7.0');
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('prod');

	due_commit($h, 'qa',   params => {instances => 2},
		message => 'Raise the qa instance count');
	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the prod instance count');
	refresh($h, 'a');
	run_genesis($h, 'propagate', '-y');

	# The pull request that first run opened for prod, taken off the pointer
	# the run wrote rather than guessed at, so the last assertion can say
	# which pull request the second run left alone.
	my $number = record_at($h, $h->env_path('prod').'/proposed')->{number};

	due_commit($h, 'qa',   params => {instances => 3},
		message => 'Raise qa again');
	due_commit($h, 'prod', params => {instances => 3},
		message => 'Raise prod again');
	refresh($h, 'a');

	# How much of the call log belongs to the run that stood the fixture up,
	# so what is counted below is what the rejected run itself sent.
	my $already = scalar(() = gh_calls($h->{gh}));

	# Copy B moves the pull request branch on R behind this clone's back,
	# which is the window D51's expected tip exists to close.  Copy A's own
	# remote-tracking ref still names the first run's commit, and that is the
	# value the arm reads and the publish leases against.
	my $moved = move_on_r($h, $pr);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded($out, $err);

	# The commit copy B pushed carries no marker, so the arm's discard report
	# names it and the publish's own qualifier is appended behind that one
	# rather than written over it.  The pattern allows what stands between
	# the two, and stops at the colon that would start another environment's
	# line, so it cannot read the phrase off a neighbour.
	like($said, qr/prod: publish rejected,[^:]*\Q$pr\E moved on R/,
		'prod records publish rejected, naming the moved ref');
	like($said, qr/qa: propagated/, 'while qa publishes');
	isnt($exit, 0, 'and the run reports the partial result');

	refresh($h, 'a', $pr);
	is($git->sha("origin/$pr"), $moved, "R still carries copy B's commit");
	is($git->sha($pr), $moved, "and prod's branch in L was reset to T");

	my @sent = gh_calls($h->{gh});
	splice(@sent, 0, $already);
	my @writes = grep {($_->{method} // 'GET') ne 'GET'} @sent;
	is(scalar(grep {($_->{url} // '') =~ m{/pulls/$number$}} @writes), 0,
		'and the pull request whose branch never published was left alone');
};

subtest 'a branch the remote has never had leases the empty object name' => sub {
	plan tests => 8;

	my $h    = ready(envs => ['qa', 'prod'], kit => 'omega-v2.7.0');
	my $held = $h->pr_branch('qa');
	my $new  = $h->pr_branch('prod');

	# qa alone is due on the first run, so it ends with a pull request branch
	# on R and prod ends with none.  The two specs the second run's publish is
	# handed then name two different expected values.
	due_commit($h, 'qa', params => {instances => 2},
		message => 'Raise the qa instance count');
	refresh($h, 'a');
	run_genesis($h, 'propagate', '-y');

	refresh($h, 'a', $held);
	my $read = $h->git('a')->sha("origin/$held");

	due_commit($h, 'qa',   params => {instances => 3},
		message => 'Raise qa again');
	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the prod instance count');
	refresh($h, 'a');

	my $git = fault_git($h);
	run_genesis($h, 'propagate', '-y');

	my ($call)  = grep {$_->[0] eq 'push'} step_log($git);
	my %args    = @{$call}[1 .. $#$call];
	my %spec_of = map {($_->{branch} => $_)} @{$args{refs} || []};

	is($spec_of{$held}{expect}, $read, 'qa leases the tip its own refresh read');
	ok(exists $spec_of{$new}{expect},
		'prod is handed an expected tip of its own');
	is($spec_of{$new}{expect}, undef,
		'which is nothing at all, because R had no such branch, and that is '.
		'what _push_one leases as Service::Git::NULL_SHA');

	# Green on arrival, and a guard: the baseline sends no lease whatever, so
	# a first push lands either way.  It stays here because it is what reddens
	# an expected_tip that answered a value for a branch the remote has never
	# had, which git refuses outright as stale info.
	ok(remote_sha($h, $new), "and prod's branch reached R all the same");

	# Green on arrival, both of these: Task 16.1 already classes the pull
	# request branch and the publish already sends one call for the whole set.
	# They guard the two assertions above, which read the class and the count
	# they name.
	is($spec_of{$new}{kind}, 'pr', 'and both go as pull request branches');
	is(scalar(grep {$_->[0] eq 'push'} step_log($git)), 1,
		'one publish call carried every ref, each on its own push');
};

done_testing;

# vim: fdm=marker:foldlevel=0:noet
