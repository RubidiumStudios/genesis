#!/usr/bin/env perl
# Proves the setup half of T57, T85, T97, and T100: the harness can amend a
# tip, make a branch R never had, take the control branch away entirely,
# rename the remotes, cut a branch no delivery made, write one config key,
# and arm a push to R for the middle of the next run.
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

subtest 'an amended tip keeps the old message in the body' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $control = $h->git('a')->sha($h->control);
	my $first = deliver($h, 'qa', control => $control);

	my $amended = amend_tip($h, $h->slug('qa'),
		subject => 'Correct the instance count');

	isnt($amended, $first, 'the tip is a different commit');
	my ($subject) = run({dir => $h->r}, 'git', 'log', '-1', '--format=%s',
		$h->slug('qa'));
	chomp $subject;
	is($subject, 'Correct the instance count', 'with the new subject');
	is(harness_marker($h, $h->slug('qa')), $control,
		'and the marker pushed down into the body');
};

subtest 'a branch R never had, and a control branch that exists nowhere' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], vault => 0);
	local_branch_only($h, 'qa');

	ok(exists refs_in($h->a)->{'refs/heads/' . $h->slug('qa')},
		'copy A carries the deployment branch');
	is(remote_sha($h, $h->slug('qa')), undef, 'and R has never had it');

	my $g = make_harness(envs => ['qa'], vault => 0);
	unset_control($g);
	is(remote_sha($g, $g->control), undef, 'control is gone from R');
	isnt(branch_of($g->a), $g->control, 'and copy A stands somewhere else');
};

subtest 'the remotes can be renamed and the upstream cleared' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);
	set_remotes($h, copy => 'a',
		remotes  => {dev => $h->r, origin => $h->r},
		upstream => 0);

	my ($remotes) = run({dir => $h->a}, 'git', 'remote');
	chomp $remotes;
	is_deeply([sort split /\n/, $remotes], ['dev', 'origin'],
		'the copy carries both remotes');

	my $upstream = run({dir => $h->a, passfail => 1}, 'git', 'config',
		'--get', 'branch.' . $h->control . '.remote');
	ok(!$upstream, 'and the control branch has no upstream');

	my $git = set_remotes($h, copy => 'a', upstream => 'dev');
	isa_ok($git, 'Service::Git', 'set_remotes hands back the handle');
};

subtest 'one config key, a plain branch, and an armed push to R' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $path = set_repo_config($h, 'pipeline.source_control.control_requires_pr', 1);
	like($path, qr{\.genesis/config$}, 'the config file is named back');
	like(slurp($h->a . '/' . $path), qr/control_requires_pr/,
		'and it carries the key');

	my $sha = local_branch($h, 'rolling/qa', push => 1);
	is(remote_sha($h, 'rolling/qa'), $sha,
		'a branch no delivery made stands on R');

	init_branch($h, 'qa');
	refresh($h, 'a', $h->slug('qa'));
	my $armed = move_on_r_at($h, $h->slug('qa'), at => 'push');
	isnt(remote_sha($h, $h->slug('qa')), $armed,
		'the armed commit has not reached R yet');
};

done_testing;
