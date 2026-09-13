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

subtest 'the armed push moves R in the middle of the run' => sub {
	plan tests => 4;

	my $h      = make_harness(envs => ['qa'], vault => 0);
	my $branch = $h->slug('qa');
	my $base   = init_branch($h, 'qa');
	refresh($h, 'a', $branch);

	# Copy A needs work of its own, so the push the child makes is a real one
	# that has to reach R rather than a no-op git answers on its own.
	my $mine = commit_on_control($h, branch => $branch,
		files => {'mine.yml' => "---\nmine: true\n"}, push => 0);

	my $armed = move_on_r_at($h, $branch, at => 'push');
	is(remote_sha($h, $branch), $base, 'R still stands where the run expects');

	my ($out) = _push_in_child($h, $branch);

	is(remote_sha($h, $branch), $armed,
		'the armed action moved R at the push step');
	like($out, qr/result:0/,
		"copy A's own push still ran and found R moved");
	isnt(remote_sha($h, $branch), $mine, 'so its commit never reached R');
};

# _push_in_child - push one branch from a child perl, under the environment a
# spawned command runs in.  It is machinery the row above needs rather than
# repository state, so it sits beside it.  The child prints the result rather
# than exiting on it, because a wrapper that ran the armed action and then
# failed to delegate would answer undef and exit just as a rejected push does.
sub _push_in_child {
	my ($h, $branch) = @_;
	return run({
			dir      => $h->a,
			stderr   => 0,
			passfail => 0,
			env      => {
				GENESIS_HARNESS_GIT_PLAN => $ENV{GENESIS_HARNESS_GIT_PLAN},
				GENESIS_HARNESS_GIT_LOG  => $ENV{GENESIS_HARNESS_GIT_LOG},
				PERL5OPT => join(' ',
					'-I' . $helper::TOPDIR . '/t', '-I' . $helper::TOPDIR . '/lib',
					'-MHarness::Propagation::Git'),
			},
		}, 'perl', '-e',
		'use Service::Git;
		 my $r = Service::Git->new($ARGV[0])->push("origin", $ARGV[1]);
		 print "result:", (defined $r->{$ARGV[1]} ? $r->{$ARGV[1]} : "none"), "\n";',
		$h->a, $branch);
}

subtest 'a second harness arms its own plan, not the first harness plan' => sub {
	plan tests => 4;

	my $one = make_harness(envs => ['qa'], vault => 0);
	init_branch($one, 'qa');
	refresh($one, 'a', $one->slug('qa'));
	move_on_r_at($one, $one->slug('qa'), at => 'push');
	my $first = $ENV{GENESIS_HARNESS_GIT_PLAN};

	my $two = make_harness(envs => ['dev'], vault => 0);
	init_branch($two, 'dev');
	refresh($two, 'a', $two->slug('dev'));
	move_on_r_at($two, $two->slug('dev'), at => 'push');
	my $second = $ENV{GENESIS_HARNESS_GIT_PLAN};

	isnt($second, $first, 'the second harness armed a plan file of its own');
	my ($b_one, $b_two) = ($one->b, $two->b);
	like(slurp($second), qr/\Q$b_two\E/,
		'whose armed push runs in its own copy B');
	like(slurp($first), qr/\Q$b_one\E/, 'and the first harness keeps its own');
	unlike(slurp($first), qr/\Q$b_two\E/,
		'which the second one never wrote into');
};

subtest 'the seeded pipeline section takes the shapes the option names' => sub {
	plan tests => 9;

	my $on = make_harness(envs => ['qa'], vault => 0,
		source_control => {control_requires_pr => 'true'});
	my ($enabled, $rc) = load_yaml_file($on->a . '/.genesis/config');
	is($rc, 0, 'the seeded configuration parses');
	is($enabled->{pipeline}{enabled}, 1, 'the default is an enabled pipeline');
	is($enabled->{pipeline}{provider}{type}, 'manual', 'carrying the provider');
	is($enabled->{pipeline}{mode}, 'direct', 'and the mode');
	is($enabled->{pipeline}{source_control}{control_requires_pr}, 'true',
		'with the source_control keys the harness was declared with');

	my ($off) = load_yaml_file(make_harness(envs => ['qa'], vault => 0,
		pipeline => 0)->a . '/.genesis/config');
	ok(!$off->{pipeline}{enabled}, 'zero is a section whose enabled is false');
	ok(exists $off->{pipeline}{provider}, 'and the section is written anyway');

	my ($none) = load_yaml_file(make_harness(envs => ['qa'], vault => 0,
		pipeline => 'none')->a . '/.genesis/config');
	ok(!exists $none->{pipeline}, 'the string none writes no section at all');

	my ($keys) = load_yaml_file(make_harness(envs => ['qa'], vault => 0,
		pipeline => {track_dependencies => 1})->a . '/.genesis/config');
	is($keys->{pipeline}{track_dependencies}, 1,
		'and a hashref sets the repository-wide keys');
};

subtest 'an arrayref renders as a YAML list at either depth' => sub {
	plan tests => 7;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $path = write_env_file($h, 'qa',
		genesis  => {min_version => '3.2.0', features => ['a', 'b']},
		pipeline => {track_dependencies => ['x', 'y'], auto => 1},
		commit   => 0);

	my $body = slurp($h->a . '/' . $path);
	like($body, qr/^  features:\n    - a\n    - b$/m,
		'a list under genesis is written as a list');
	like($body, qr/^    track_dependencies:\n      - x\n      - y$/m,
		'and so is one a level deeper');
	like($body, qr/^  min_version: 3\.2\.0$/m, 'a scalar is still a scalar');

	my ($env, $rc) = load_yaml_file($h->a . '/' . $path);
	is($rc, 0, 'the file parses');
	is_deeply($env->{genesis}{pipeline}{track_dependencies}, ['x', 'y'],
		'and the list reads back as the list it was given');

	# A site file used to carry nested entries with no genesis key above them,
	# which is a file no YAML reader will load at all.
	my $site = write_env_file($h, 'qa', site => 'ops',
		pipeline => {auto => 1}, commit => 0);
	my ($merged, $src) = load_yaml_file($h->a . '/' . $site);
	is($src, 0, 'a site file carrying nested entries parses too');
	is($merged->{genesis}{pipeline}{auto}, 1, 'with the genesis key above them');
};

done_testing;
