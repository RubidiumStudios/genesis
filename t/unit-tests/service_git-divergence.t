#!/usr/bin/env perl
# Proves T89: the divergence query answers with the six states, both counts,
# and the unverifiable flag, and the retired forced refspec has not come back.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Deep;

use Genesis;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

sub div {
	my ($h, $branch, %opts) = @_;
	return $h->git('a')->resolve_branch($branch, %opts);
}

# The six states the query can answer with.  An assertion helper, beside the
# test that uses it, because it is about what these rows mean rather than
# about what the tree holds.
my @STATES = qw/ahead behind diverged in-sync no-local no-remote/;

sub one_of_the_six {
	my ($answer, $what) = @_;
	my $state = ref($answer) eq 'HASH' ? ($answer->{state} // '') : '';
	ok(scalar(grep {$_ eq $state} @STATES),
		"$what answers one of the six states");
}

subtest 'the four counted states come from the two counts' => sub {
	plan tests => 8;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	cmp_deeply(div($h, $slug),
		{state => 'in-sync', ahead => 0, behind => 0, unverifiable => 0},
		'equal tips read in-sync');
	one_of_the_six(div($h, $slug), 'equal tips');

	local_only_commit($h, $slug, marker => 0, message => 'a local commit');
	cmp_deeply(div($h, $slug),
		{state => 'ahead', ahead => 1, behind => 0, unverifiable => 0},
		'a commit L alone holds reads ahead with its count');
	one_of_the_six(div($h, $slug), 'a commit L alone holds');

	my $h2    = make_harness(envs => ['qa'], vault => 0);
	my $slug2 = $h2->slug('qa');
	init_branch($h2, 'qa');
	refresh($h2, 'a', $slug2);
	move_on_r($h2, $slug2);
	refresh($h2, 'a', $slug2);
	cmp_deeply(div($h2, $slug2),
		{state => 'behind', ahead => 0, behind => 1, unverifiable => 0},
		'a commit T alone holds reads behind with its count');
	one_of_the_six(div($h2, $slug2), 'a commit T alone holds');

	my $h3    = make_harness(envs => ['qa'], vault => 0);
	my $slug3 = $h3->slug('qa');
	init_branch($h3, 'qa');
	refresh($h3, 'a', $slug3);
	diverge($h3, $slug3, local => 2, remote => 1);
	cmp_deeply(div($h3, $slug3),
		{state => 'diverged', ahead => 2, behind => 1, unverifiable => 0},
		'commits on both sides read diverged with both counts');
	one_of_the_six(div($h3, $slug3), 'commits on both sides');
};

subtest 'the two existence answers come before the counts' => sub {
	plan tests => 5;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	delete_local($h, 'a', $slug);
	cmp_deeply(div($h, $slug),
		{state => 'no-local', ahead => 0, behind => 0, unverifiable => 0},
		'T alone reads no-local');
	one_of_the_six(div($h, $slug), 'T alone');

	local_branch_only($h, 'lab');
	cmp_deeply(div($h, $h->slug('lab')),
		{state => 'no-remote', ahead => 0, behind => 0, unverifiable => 0},
		'L alone reads no-remote');
	one_of_the_six(div($h, $h->slug('lab')), 'L alone');

	is(div($h, 'nowhere/bosh'), undef,
		'a branch neither side has gets no state at all');
};

subtest 'a tag sharing a branch name is not that branch' => sub {
	plan tests => 1;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	delete_local($h, 'a', $slug);
	tag_branch($h, 'a', $slug, at => "refs/remotes/origin/$slug");

	# A reader built on `git rev-parse --verify` answers about this tag as
	# readily as about a branch, so it would call the branch local, take the
	# counts against a head that is not there, and turn a query that
	# promises to raise nothing into a bail.
	cmp_deeply(div($h, $slug),
		{state => 'no-local', ahead => 0, behind => 0, unverifiable => 0},
		'the tracking ref alone still has the branch');
};

subtest 'the unverifiable flag rides on every answer' => sub {
	plan tests => 2;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	my $stale = div($h, $slug, unverifiable => 1);
	is($stale->{state}, 'in-sync', 'the state is still read and reported');
	is($stale->{unverifiable}, 1,
		'the flag says the counts rest on a T nobody refreshed');
};

subtest 'the query asks refs and never the network' => sub {
	plan tests => 4;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	# The refresh is armed to die here rather than severed, and the
	# difference is the whole trap.  sever_remote answers a fetch with the
	# classified failure the real method answers with, which is a result this
	# query would simply ignore, so a severed remote would let a query that
	# fetched pass anyway.  A death cannot be ignored, so this arming is
	# sprung the moment the query reaches the remote.
	my $git = fault_git($h);
	fail_on($git, 'fetch_branches', 1, from => 1,
		message => 'the query reached the remote');

	my $answer = div($h, $slug);

	is($answer->{state}, 'in-sync', 'the answer comes back with no fetch');
	is_deeply([map {$_->[0]} step_log($git)], [],
		'and no watched git step ran at all');
	reset_steps($git);

	# The sweep is the second half of the claim, and it reads the sub's own
	# body rather than its behaviour, so it catches a fetch on a path this
	# fixture never takes.
	my $src = slurp('lib/Service/Git.pm');
	my ($body) = $src =~ m{sub resolve_branch \{(.+?)\n\}}s;
	# The capture is asserted before it is read, because a rename or a
	# reformat that stopped the pattern matching would leave it undefined
	# and the negation below would pass over nothing at all.
	ok(defined $body && length $body,
		'the body of resolve_branch was found to read');
	unlike($body, qr{fetch_branches|remote_branch_exists|ls-remote},
		'and the query neither fetches nor asks the remote');

	# The arming is cleared as well as the counts, because reset_steps empties
	# the log and the tally and leaves the armed step itself in the plan, and
	# an arming left standing here would be inherited by every row below.
	restore_remote($h);
};

subtest 'the source of resolve_branch quotes no seventh state' => sub {
	plan tests => 2;

	# Every answer read above is asserted to be one of the six, which says
	# nothing about a seventh the fixtures never reach.  This reads the
	# sub's own text for the states it can name, which is the only place
	# that decides the set, and it is a tripwire on that text rather than
	# on the behaviour.  Moving the ternary into a lookup table or naming
	# the states in constants breaks it without the set having changed, and
	# whoever does that updates it here.
	my $src = slurp('lib/Service/Git.pm');
	my ($body) = $src =~ m{sub resolve_branch \{(.+?)\n\}}s;
	ok(defined $body && length $body,
		'the body of resolve_branch was found to read');

	# The two early returns name their state in a pair, and the counted
	# four are the arms of one ternary, so both shapes are read and nothing
	# else quoted in the sub is mistaken for a state.
	my ($ternary) = $body =~ m{my \$state\s*=(.+?);}s;
	my %named = map {$_ => 1} (
		$body    =~ m{state\s*=>\s*'([a-z][a-z-]*)'}g,
		($ternary // '') =~ m{'([a-z][a-z-]*)'}g,
	);
	cmp_deeply([sort keys %named],
		[sort qw/ahead behind diverged in-sync no-local no-remote/],
		'the sub names these six states and no others');
};

# The sweep asks for the forced form the retired single-branch helper wrote,
# which is the one 7.1's own row names, and not for every refspec that ends
# at refs/heads.  The refresh still writes +refs/heads/<name>:refs/heads/<name>
# for a branch this clone lacks, and the design asks it to, because creating a
# local ref that was not there is not the same write as overwriting a local
# ref that was.  A sweep that caught both would refuse the creation the design
# requires and would say nothing more about the overwrite it exists to catch.
subtest 'the retired helper\'s forced overwrite has not come back' => sub {
	plan tests => 1;

	my $src = join('', map { slurp($_) }
		qw(lib/Service/Git.pm lib/Genesis/CI/Propagation.pm));
	my @forced = ($src =~ m{(\+refs/heads/[^:\s]+:refs/heads/\$branch)}g);
	cmp_deeply(\@forced, [],
		'no forced overwrite of a named local head is written anywhere');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
