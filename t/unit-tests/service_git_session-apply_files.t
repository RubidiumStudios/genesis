#!/usr/bin/env perl
# Proves T110: the writer delivers one control commit to qa/bosh as a mirror,
# so the branch's tree equals the propagation set as it stood at the delivered
# commit and a path that dropped out of the set is gone from the branch.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Cwd ();
use Genesis;
use Genesis::CI::Marker;
use Genesis::Top;
use Service::Git;
use Service::Git::Session;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a delivery mirrors the set at the delivered commit' => sub {
	plan tests => 5;

	# The kit's blueprint names one repository-side fragment, so ops/extra.yml
	# is in the set for as long as control holds it, and the embedded genesis
	# is there so the eighth kind is a file rather than a name nothing tracks.
	my $h = make_harness(
		envs => ['qa'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, 'qa');

	# A control commit the branch is delivered from, and then one that deletes
	# the fragment, so a path leaves the set for a reason the working tree and
	# the delivered commit agree about.
	my $first = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: yes\n"},
		message => 'add the fragment the blueprint names',
		push    => 1,
	);
	deliver($h, 'qa', copy => 'a', control => $first);

	my $second = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => undef},
		message => 'delete the fragment the blueprint names',
		push    => 1,
	);

	# propagation_files reads the repository through Service::Git->new('.'),
	# which is the deployment root a command is run from, and the Top and the
	# environment are built before the session opens, because a deployment
	# branch is not a repository a Top can be opened on.
	my $was = Cwd::getcwd();
	chdir $h->a . '/bosh'
		or die "cannot enter the deployment root: $!\n";
	# The handle is built at the deployment root and not at the copy root,
	# because Service::Git keeps one instance per repository and fixes its
	# prefix at that first construction.  A handle built at the copy root
	# carries no prefix, and the set then comes back deployment-root-relative
	# and matches nothing the branch holds, which is not the shape a command
	# run from the deployment root has.
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	my $result = $session->apply_files($second,
		env     => $env,
		message => Genesis::CI::Marker::build($second, 'qa'),
	);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');
	chdir $was or die "cannot return to $was: $!\n";

	ok($result->{commit}, 'the writer reports a commit');

	my @expected = sort(propagation_set($h, 'qa', at => $second));
	is_deeply(tree_of($h->a, $h->slug('qa')), [@expected],
		"the branch's tree equals the set at the delivered commit");

	ok(!grep({$_ eq 'bosh/ops/extra.yml'} @{tree_of($h->a, $h->slug('qa'))}),
		'the path that dropped out of the set is gone from the branch');

	assert_snapshot_invariant($h, 'qa', copy => 'a',
		name => 'the delivered branch holds its source');
};

done_testing;
