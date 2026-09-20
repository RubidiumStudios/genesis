#!/usr/bin/env perl
# Proves T315 and T316: the refresh creates a local ref from the tracking
# ref, skips no branch for being checked out, and never prunes.
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
use Genesis::CI::Preflight;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a branch R holds and L lacks comes down and reads in-sync' => sub {
	plan tests => 5;

	my $h    = make_harness(envs => ['qa', 'prod'], vault => 0);
	my $git  = $h->git('a');
	my $prod = $h->slug('prod');
	my $qa   = $h->slug('qa');

	init_branch($h, $_) for qw/qa prod/;
	refresh($h, 'a', $qa, $prod);
	delete_local($h, 'a', $prod);

	is(ref_in($h->a, "refs/heads/$prod"), undef, 'copy A lacks the branch');
	is($git->resolve_branch($prod)->{state}, 'no-local',
		'and it reads no-local while it does');

	my (undef, $result) = $git->fetch_branches([$qa, $prod, $h->control]);

	is(ref_in($h->a, "refs/heads/$prod"), ref_in($h->r, $prod),
		'the local ref is created from what the remote holds');
	is($git->resolve_branch($prod)->{state}, 'in-sync',
		'and the branch now reads in-sync');
	cmp_deeply($result->{created}, [$prod],
		'the refresh reports the one ref it created and no other');
};

subtest 'a branch nobody has is never created' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');

	my (undef, $result) = $git->fetch_branches([$h->slug('nowhere')]);

	is(ref_in($h->a, 'refs/heads/nowhere/bosh'), undef,
		'no local ref is invented for a branch the remote lacks');
	cmp_deeply($result->{absent}, [$h->slug('nowhere')],
		'and the refresh reports it as absent');
};

subtest 'the checked-out branch is refreshed like any other' => sub {
	plan tests => 3;

	my $h       = make_harness(envs => ['qa'], vault => 0);
	my $git     = $h->git('a');
	my $control = $h->control;

	stand_on($h, $control, copy => 'a');
	my $before_l = ref_in($h->a, "refs/heads/$control");
	my $published = publish_from_b($h,
		files   => {'ops/shared.yml' => "---\nfrom: the teammate\n"},
		message => 'a teammate publishes onto control',
	);

	my (undef, $result) = $git->fetch_branches([$control]);

	cmp_deeply($result->{fetched}, [$control],
		'the checked-out branch is in the refresh and not dropped from it');
	is(ref_in($h->a, "refs/remotes/origin/$control"), $published,
		'its tracking ref moved to what the remote holds');
	is(ref_in($h->a, "refs/heads/$control"), $before_l,
		'and its local ref stayed where the operator left it');
};

subtest 'the refresh never prunes' => sub {
	plan tests => 5;

	my $h    = make_harness(envs => ['qa', 'lab'], vault => 0);
	my $git  = $h->git('a');
	my $lab  = $h->slug('lab');

	init_branch($h, $_) for qw/qa lab/;
	refresh($h, 'a', $lab);
	my $stranded = local_only_commit($h, $lab,
		marker => 0, message => 'a commit only copy A has');

	delete_on_r($h, $lab);
	$git->fetch_branches([$lab, $h->control]);

	is(ref_in($h->a, "refs/heads/$lab"), $stranded,
		"copy A's local branch is still here after the teammate's delete");
	# A prune would take refs/remotes/origin/<lab> away with the branch, and
	# the query would then have one ref to read and would answer no-remote.
	# It answers against both refs instead, ahead by the one commit copy A
	# never pushed, which is the tracking ref saying it is still here.
	cmp_deeply($git->resolve_branch($lab),
		{state => 'ahead', ahead => 1, behind => 0, unverifiable => 0},
		'and it still reads against a tracking ref, which a prune would have taken');

	my @local_only = Genesis::CI::Preflight::local_only_commits($git, $lab);
	cmp_deeply([map { $_->{sha} } @local_only], [$stranded],
		'the no-prune query lists the commit only copy A has');

	# The marker reader answers a sha, a depth, and where it read from,
	# and a record that took all three would carry a key named after the
	# depth.  The key set is asserted rather than the four values, because
	# a fifth key is the whole defect and the values have their own rows.
	cmp_deeply([sort keys %{$local_only[0]}],
		[qw/marker sha short subject/],
		'and a record carries those four keys and no fifth');

	# The read is of the whole module rather than of the refresh subs, so
	# what it actually says is that the option appears nowhere in the file,
	# which is the wider claim and the one worth keeping as a tripwire.
	my $src = slurp('lib/Service/Git.pm');
	unlike($src, qr{--prune}, 'Service::Git names --prune nowhere at all');
};

done_testing;
