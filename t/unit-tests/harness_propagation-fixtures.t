#!/usr/bin/env perl
# Proves T2, the branch halves: the harness cuts each environment on R as the
# init branch the apply would leave, and a second deployment root sharing an
# environment name can be built beside the first.
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

subtest 'the harness cuts the init branch on R' => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $before = run({dir => $h->a}, 'git', 'rev-parse', '--abbrev-ref', 'HEAD');
	chomp $before;

	my $init = init_branch($h, 'qa');

	my ($sha) = run({dir => $h->r}, 'git', 'rev-parse', 'qa/bosh');
	chomp $sha;
	is($sha, $init, 'R carries qa/bosh at the init commit');

	is_deeply(tree_of($h->r, 'qa/bosh'), ['init'],
		'the init branch holds the init file alone');

	my ($subject) = run({dir => $h->r}, 'git', 'log', '-1', '--format=%s', 'qa/bosh');
	chomp $subject;
	is($subject, 'Initialize qa/bosh branch [ci skip]',
		'the init commit carries the subject the apply writes');

	my ($parents) = run({dir => $h->r}, 'git', 'log', '-1', '--format=%P', 'qa/bosh');
	chomp $parents;
	is($parents, '', 'the init commit is an orphan root');

	my $unrelated = run({dir => $h->r, passfail => 1},
		'git', 'merge-base', '--is-ancestor', $h->control, 'qa/bosh');
	ok(!$unrelated, 'it shares no history with control');

	my $after = run({dir => $h->a}, 'git', 'rev-parse', '--abbrev-ref', 'HEAD');
	chomp $after;
	is($after, $before, 'nothing was checked out in copy A');
};

subtest 'a delivery mirrors the set and carries the marker' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	my $delivered = deliver($h, 'qa', control => $control);

	my ($subject) = run({dir => $h->r}, 'git', 'log', '-1', '--format=%s', 'qa/bosh');
	chomp $subject;
	is($subject, sprintf('[pipeline] control@%s -> qa', substr($control, 0, 12)),
		'the delivery carries the marker naming its control commit');

	is(harness_marker($h, 'qa/bosh'), $control,
		"the harness's own marker read resolves the control commit");

	my $files = tree_of($h->r, $delivered);
	ok(!(grep {$_ eq 'init'} @$files), 'the delivery removed the init file');
};

subtest 'a second deployment root shares an environment name' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['lmelt-vsphere-canwest-1-mgmt'], vault => 0);
	add_deployment_root($h, type => 'vault',
		envs => ['lmelt-vsphere-canwest-1-mgmt']);

	init_branch($h, 'lmelt-vsphere-canwest-1-mgmt');
	init_branch($h, 'lmelt-vsphere-canwest-1-mgmt', type => 'vault');

	is($h->slug('lmelt-vsphere-canwest-1-mgmt'),
		'lmelt-vsphere-canwest-1-mgmt/bosh', 'the bosh root names its own slug');
	is($h->slug('lmelt-vsphere-canwest-1-mgmt', type => 'vault'),
		'lmelt-vsphere-canwest-1-mgmt/vault', 'the vault root names its own slug');

	for my $branch (qw(lmelt-vsphere-canwest-1-mgmt/bosh
	                   lmelt-vsphere-canwest-1-mgmt/vault)) {
		my $ok = run({dir => $h->r, passfail => 1},
			'git', 'show-ref', '--verify', '--quiet', "refs/heads/$branch");
		ok($ok, "R carries $branch");
	}
};

done_testing;
