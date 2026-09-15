#!/usr/bin/env perl
# Proves T111: a control commit moves a flat repository's files under a bosh/
# deployment root, and the writer reads the set from that commit's tree, so it
# delivers the moved set under its new prefix, removes the root-level files the
# branch still held, and runs no rename detection at all.  The tracked list is
# read at the commit as well, so a path control has taken up again does not
# ride along with a delivery of the commit that dropped it, and the blueprint's
# repository-side fragments are enumerated on control by one sub that answers
# the same way whether or not the environment carries a loaded kit.
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
use Genesis::Env;
use Genesis::Top;
use Service::Git;
use Service::Git::Session;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

sub in_set {
	my ($path, @set) = @_;
	return scalar(grep {$_ eq $path} @set);
}

subtest 'the set is read at the delivered commit, not from the working tree' => sub {
	plan tests => 5;

	# A flat repository: the deployment root is the git root.  The ops file
	# travels because the environment tracks it by name, which is the kind
	# whose resolution has to follow the root when the root moves.
	my $h = make_harness(envs => ['qa'], root => '');
	fixture_vault($h);
	write_env_file($h, 'qa',
		pipeline => {track_additional_files => ['ops/thing.yml']});
	init_branch($h, 'qa');

	my $flat = commit_on_control($h,
		files   => {'ops/thing.yml' => "---\nthing: yes\n"},
		message => 'add an ops file',
	);
	deliver($h, 'qa', copy => 'a', control => $flat);

	# The restructure: every path moves under bosh/, which is the one
	# transition between the two layouts.
	my $held = files_at($h, $flat, copy => 'a');
	my %moved;
	$moved{"bosh/$_"} = $held->{$_} for keys %$held;
	$moved{$_} = undef for keys %$held;
	my $restructure = commit_on_control($h,
		files   => {%moved},
		message => 'move the deployment under bosh',
	);

	# The deployment root exists only from the restructure onward, and the
	# handle is built there rather than at the copy root, because Service::Git
	# keeps one instance per repository and fixes its prefix at that first
	# construction.  The Top and the environment are built before the session
	# opens, because a deployment branch is not a repository a Top can be
	# opened on.
	my $was = Cwd::getcwd();
	chdir $h->a . '/bosh'
		or die "cannot enter the deployment root: $!\n";
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = Genesis::Env->bare('qa', $top);

	my @expected = sort(propagation_set($h, 'qa', at => $restructure, root => 'bosh'));
	my @at = $env->propagation_files_at($restructure, git => $git);
	is_deeply([@at], [@expected],
		'the reader answers with the set as it stood at the commit');
	ok(!grep({m{^qa\.yml$}} @at), 'the root-level spelling is not in the set');

	# The same reader, standing in the same restructured tree, answers the
	# commit before the restructure with the flat spelling, which is the
	# reading a prefix taken from today's configuration cannot give.
	is_deeply([$env->propagation_files_at($flat, git => $git)],
		[sort(propagation_set($h, 'qa', at => $flat, root => ''))],
		'and at the commit before the restructure it answers the flat set');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));
	$session->apply_files($restructure,
		env     => $env,
		message => Genesis::CI::Marker::build($restructure, 'qa'),
	);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');
	chdir $was or die "cannot return to $was: $!\n";

	is_deeply(tree_of($h->a, $h->slug('qa')), [@expected],
		'the moved set lands under its new prefix and the root-level files are gone');
};

subtest 'no rename detection runs' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], root => 'bosh');
	fixture_vault($h);
	write_env_file($h, 'qa', root => 'bosh',
		pipeline => {track_additional_files => ['ops/old.yml']});
	init_branch($h, 'qa');

	my $before = commit_on_control($h,
		files   => {'bosh/ops/old.yml' => "---\nname: a\n"},
		message => 'add an ops file',
	);
	deliver($h, 'qa', copy => 'a', control => $before);

	# A commit that moves a file and edits it, which git's similarity
	# heuristic reads as a delete plus an add.  The tracked list follows the
	# file in the same commit, so the environment names the new path from the
	# commit onward and the old one from nowhere at all.
	write_env_file($h, 'qa', root => 'bosh', commit => 0,
		pipeline => {track_additional_files => ['ops/new.yml']});
	my $after = commit_on_control($h,
		files   => {'bosh/qa.yml'      => slurp($h->a . '/bosh/qa.yml'),
		            'bosh/ops/old.yml' => undef,
		            'bosh/ops/new.yml' => "---\nname: a\nedited: yes\n"},
		message => 'move and edit the ops file',
	);

	my $was = Cwd::getcwd();
	chdir $h->a . '/bosh'
		or die "cannot enter the deployment root: $!\n";
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = Genesis::Env->bare('qa', $top);

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));
	my $result = $session->apply_files($after,
		env     => $env,
		message => Genesis::CI::Marker::build($after, 'qa'),
	);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');
	chdir $was or die "cannot return to $was: $!\n";

	is_deeply([sort @{$result->{removed}}], ['bosh/ops/old.yml'],
		'the old path is removed as an ordinary path outside the set');
	ok(in_set('bosh/ops/new.yml', @{$result->{delivered}}),
		'and the new path is delivered as an ordinary path inside it');
};

subtest 'both readers name the blueprint fragments the same way' => sub {
	plan tests => 4;

	# The kit's blueprint names one repository-side fragment, which is the
	# kind D78 enumerates on control because that is where the kit lives.
	my $h = make_harness(envs => ['qa'], root => 'bosh',
		kit => 't/src/ops-blueprint');
	fixture_vault($h);
	my $control = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: fragment\n"},
		message => 'add the fragment the blueprint names',
	);

	my $was = Cwd::getcwd();
	chdir $h->a . '/bosh'
		or die "cannot enter the deployment root: $!\n";
	my $git    = Service::Git->new($h->a . '/bosh');
	my $top    = Genesis::Top->new($h->a . '/bosh');
	my $bare   = Genesis::Env->bare('qa', $top);
	my $loaded = $top->load_env('qa');

	my @from_bare = $bare->_blueprint_fragments($git);
	is_deeply([@from_bare], ['ops/extra.yml'],
		'the fragments are enumerated from the kit the environment declares');
	is_deeply([$loaded->_blueprint_fragments($git)], [@from_bare],
		'and a loaded kit names the same ones');

	ok(in_set('bosh/ops/extra.yml', $bare->propagation_files_at($control, git => $git)),
		'so the at-commit reader carries the fragment');
	ok(in_set('bosh/ops/extra.yml', $loaded->propagation_files),
		'and the working-tree reader carries it too');
	chdir $was or die "cannot return to $was: $!\n";
};

subtest 'a tracked path that fell out of the list is read at the commit' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], root => 'bosh',
		kit => 't/src/ops-blueprint');
	# The wider list tracks one path and a delivery carries it; the narrower
	# list drops it and leaves it on the branch until a delivery removes it.
	my $narrow = stale_set_delivery($h, copy => 'a', file => 'ops/tracked.yml');

	# Control takes the path up again, so the working tree and the commit
	# being delivered disagree about the set, which is the disagreement D69
	# settles in the commit's favour.
	write_env_file($h, 'qa', root => 'bosh',
		pipeline => {track_additional_files => ['ops/tracked.yml']});

	my $was = Cwd::getcwd();
	chdir $h->a . '/bosh'
		or die "cannot enter the deployment root: $!\n";
	my $git    = Service::Git->new($h->a . '/bosh');
	my $top    = Genesis::Top->new($h->a . '/bosh');
	my $env    = Genesis::Env->bare('qa', $top);
	my $loaded = $top->load_env('qa');

	ok(!in_set('bosh/ops/tracked.yml', $env->propagation_files_at($narrow, git => $git)),
		'the reader answers the narrowed list the delivered commit declares');
	ok(in_set('bosh/ops/tracked.yml', $loaded->propagation_files),
		'while a reader working from the working tree would keep the path');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));
	$session->apply_files($narrow,
		env     => $env,
		message => Genesis::CI::Marker::build($narrow, 'qa'),
	);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');
	chdir $was or die "cannot return to $was: $!\n";

	ok(!in_set('bosh/ops/tracked.yml', @{tree_of($h->a, $h->slug('qa'))}),
		'and the delivery removes the path the commit stopped tracking');
};

done_testing;
