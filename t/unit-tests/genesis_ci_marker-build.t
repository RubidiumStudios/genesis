#!/usr/bin/env perl
# Proves T78's builder half, the one marker builder.  A direct-mode delivery
# onto qa/bosh writes "[pipeline] control@<sha> -> qa", and it writes exactly
# what the builder renders.  The sweep that proves no other site under lib/
# or bin/ spells the subject by hand lands with the last task to touch those
# files, once every writer and every reader has been pointed at this module.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use_ok 'Genesis::CI::Marker';
use_ok 'Genesis::CI::Propagation';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the builder renders the subject D34 fixes' => sub {
	plan tests => 3;

	is(Genesis::CI::Marker::build('a1b2c3d4e5f6', 'qa'),
		'[pipeline] control@a1b2c3d4e5f6 -> qa',
		'the subject names the control commit and the receiving environment');

	is(Genesis::CI::Marker::build('a1b2c3d', 'lmelt-vsphere-canwest-1-mgmt'),
		'[pipeline] control@a1b2c3d -> lmelt-vsphere-canwest-1-mgmt',
		'the sha is written exactly as the caller resolved it');

	is(Genesis::CI::Marker::build('a1b2c3d', 'qa'),
		'[pipeline] control@a1b2c3d -> qa',
		'the environment is its own name and never the deployment slug');
};

subtest 'a direct-mode delivery writes the built subject' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	my $short = substr($control, 0, 12);

	my $git = $h->git('a');
	stand_on($h, $h->slug('qa'));
	Genesis::CI::Propagation::_apply_propagation_commit(
		$git, 'qa', $control, $short, {changed => ['qa.yml'], deleted => []});

	my ($subject) = run({dir => $h->a}, 'git', 'log', '-1', '--format=%s',
		$h->slug('qa'));
	chomp $subject;

	is($subject, Genesis::CI::Marker::build($short, 'qa'),
		'the writer committed exactly what the builder renders');
	is($subject, "[pipeline] control\@$short -> qa",
		'and that subject is the one the design fixes');

	stand_on($h, $h->control);
};

done_testing;
