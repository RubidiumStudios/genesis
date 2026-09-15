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

subtest 'the four counted states come from the two counts' => sub {
	plan tests => 4;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	cmp_deeply(div($h, $slug),
		{state => 'in-sync', ahead => 0, behind => 0, unverifiable => 0},
		'equal tips read in-sync');

	local_only_commit($h, $slug, marker => 0, message => 'a local commit');
	cmp_deeply(div($h, $slug),
		{state => 'ahead', ahead => 1, behind => 0, unverifiable => 0},
		'a commit L alone holds reads ahead with its count');

	my $h2    = make_harness(envs => ['qa'], vault => 0);
	my $slug2 = $h2->slug('qa');
	init_branch($h2, 'qa');
	refresh($h2, 'a', $slug2);
	move_on_r($h2, $slug2);
	refresh($h2, 'a', $slug2);
	cmp_deeply(div($h2, $slug2),
		{state => 'behind', ahead => 0, behind => 1, unverifiable => 0},
		'a commit T alone holds reads behind with its count');

	my $h3    = make_harness(envs => ['qa'], vault => 0);
	my $slug3 = $h3->slug('qa');
	init_branch($h3, 'qa');
	refresh($h3, 'a', $slug3);
	diverge($h3, $slug3, local => 2, remote => 1);
	cmp_deeply(div($h3, $slug3),
		{state => 'diverged', ahead => 2, behind => 1, unverifiable => 0},
		'commits on both sides read diverged with both counts');
};

subtest 'the two existence answers come before the counts' => sub {
	plan tests => 3;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	delete_local($h, 'a', $slug);
	cmp_deeply(div($h, $slug),
		{state => 'no-local', ahead => 0, behind => 0, unverifiable => 0},
		'T alone reads no-local');

	local_branch_only($h, 'lab');
	cmp_deeply(div($h, $h->slug('lab')),
		{state => 'no-remote', ahead => 0, behind => 0, unverifiable => 0},
		'L alone reads no-remote');

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
	plan tests => 2;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	sever_remote($h);
	my $answer = div($h, $slug);
	restore_remote($h);

	is($answer->{state}, 'in-sync', 'the answer comes back with no remote');

	my $src = slurp('lib/Service/Git.pm');
	my ($body) = $src =~ m{sub resolve_branch \{(.+?)\n\}}s;
	unlike($body, qr{fetch_branches|remote_branch_exists|ls-remote},
		'the query neither fetches nor asks the remote');
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
