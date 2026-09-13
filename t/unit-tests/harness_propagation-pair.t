#!/usr/bin/env perl
# Proves T1: the harness builds R, clones copy A and copy B, and a publish
# from copy B moves R while copy A's refs stay where they were.
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

subtest 'the harness builds a bare remote and two copies' => sub {
	plan tests => 9;

	my $h = make_harness(envs => ['qa'], vault => 0);

	ok(-d $h->r, 'R exists');
	my ($bare) = run({dir => $h->r}, 'git', 'rev-parse', '--is-bare-repository');
	chomp $bare;
	is($bare, 'true', 'R is a bare repository');

	ok(-d $h->a, 'copy A exists');
	ok(-d $h->b, 'copy B exists');

	my ($remote_a) = run({dir => $h->a}, 'git', 'remote', 'get-url', 'origin');
	chomp $remote_a;
	is($remote_a, $h->r, "copy A's remote points at R");

	my ($remote_b) = run({dir => $h->b}, 'git', 'remote', 'get-url', 'origin');
	chomp $remote_b;
	is($remote_b, $h->r, "copy B's remote points at R");

	ok(-f $h->a . '/.genesis/config',
		"the deployment root sits at copy A's own git root");
	ok(!-e $h->a . '/bosh',
		'the root was not left in a directory of its own below it');

	my $base = $h->a;
	$base =~ s{/[^/]+$}{};
	is_deeply([glob("$base/top-*")], [],
		'the scratch directory the root was built in is gone');
};

subtest 'a publish from copy B moves R and leaves copy A alone' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $control = $h->control;

	my $before_r = ref_in($h->r, $control);
	my $before_l = ref_in($h->a, "refs/heads/$control");
	my $before_t = ref_in($h->a, "refs/remotes/origin/$control");

	my $published = publish_from_b($h,
		files   => {'ops/shared.yml' => "---\nfrom: the teammate\n"},
		message => 'a teammate publishes',
	);

	isnt(ref_in($h->r, $control), $before_r, 'R moved');
	is(ref_in($h->r, $control), $published, 'R carries the published commit');
	is(ref_in($h->a, "refs/heads/$control"), $before_l,
		"copy A's local ref is unchanged until it fetches");
	is(ref_in($h->a, "refs/remotes/origin/$control"), $before_t,
		"copy A's remote-tracking ref is unchanged until it fetches");
};

subtest 'the readers answer for a ref that is not there' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);

	is_deeply(tree_of($h->a, 'refs/heads/nowhere'), [],
		'tree_of answers an empty list rather than a complaint from git');
	is(ref_in($h->a, 'refs/heads/nowhere'), undef,
		'ref_in answers undef');
};

done_testing;
