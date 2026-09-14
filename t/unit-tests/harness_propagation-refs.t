#!/usr/bin/env perl
# Proves T309: a publish moves the pushing copy's remote-tracking ref, and the
# other copy's refs stay put until it fetches or pushes.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest "copy B's publish moves its own remote-tracking ref" => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $control = $h->control;

	is(upstream_of($h->b, $control), "origin/$control",
		"copy B's control branch tracks origin's, whatever the global config says");

	my $published = publish_from_b($h,
		files   => {'ops/shared.yml' => "---\nfrom: the teammate\n"},
		message => 'a teammate publishes',
	);

	is(ref_in($h->b, "refs/remotes/origin/$control"), $published,
		"copy B's remote-tracking ref moved with the push");

	my ($ahead, $behind) = counts($h->b, $control);
	is($ahead,  0, 'copy B reads zero ahead straight after the publish');
	is($behind, 0, 'copy B reads zero behind straight after the publish');
};

subtest "copy A's refs stay put until copy A fetches" => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $control = $h->control;

	my $before_t = ref_in($h->a, "refs/remotes/origin/$control");
	my $published = publish_from_b($h,
		files   => {'ops/shared.yml' => "---\nfrom: the teammate\n"},
		message => 'a teammate publishes',
	);

	is(ref_in($h->a, "refs/remotes/origin/$control"), $before_t,
		"copy A's remote-tracking ref has not moved");

	refresh($h, 'a', $control);
	is(ref_in($h->a, "refs/remotes/origin/$control"), $published,
		"copy A's remote-tracking ref moves once copy A fetches");

	my ($ahead, $behind) = counts($h->a, $control);
	is($ahead,  0, 'copy A is not ahead');
	is($behind, 1, 'copy A reads one behind');
};

subtest "copy A's own publish moves copy A's tracking ref" => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $control = $h->control;

	publish_from_b($h, files => {'ops/shared.yml' => "---\n"}, message => 'theirs');
	refresh($h, 'a', $control);
	run({dir => $h->a, onfailure => 'Failed to fast-forward copy A'},
		'git', 'merge', '--ff-only', "origin/$control");

	my $mine = commit_on_control($h,
		files   => {'ops/mine.yml' => "---\nfrom: the operator\n"},
		message => 'the operator publishes',
		push    => 1,
	);

	is(ref_in($h->a, "refs/remotes/origin/$control"), $mine,
		"copy A's remote-tracking ref moved with its own push");

	my ($ahead, $behind) = counts($h->a, $control);
	is("$ahead $behind", '0 0', 'copy A reads in-sync with no second refresh');
};

subtest 'a divergence with no local commits still reads behind' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $branch = $h->slug('qa');
	# Copy A is left without the branch, which is the shape that shows where
	# the branch is cut from: a branch cut after the teammate publishes
	# starts at the teammate's tip and reads in-sync.
	delete_local($h, 'a', $branch);
	refresh($h, 'a', $branch);
	refresh($h, 'b', $branch);

	diverge($h, $branch, local => 0, remote => 2);
	my ($ahead, $behind) = counts($h->a, $branch);
	is($ahead, 0, 'copy A wrote nothing of its own');
	is($behind, 2, 'and it stands two commits behind what the teammate published');
};

done_testing;
