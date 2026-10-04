#!/usr/bin/env perl
# Proves T345's deploy half: a re-parented environment is checked against its
# current predecessor.  prod follows lab on control at c1, where every
# environment is delivered and certified and qa and prod both track a shared
# ops file; control's c7 re-parents prod onto qa and changes that file, and qa
# has not certified c7, so the commit is in qa's undeployed set, prod has not
# received it, and prod.yml on prod/bosh still names lab.  The deploy reads
# the shape from control (D112), so its prior-env check reads qa's record and
# never lab's, its due-commits warning leaves out c7, which qa holds, and the
# environment file on the branch is left exactly as delivered, the branch
# being the authority for content and not for shape.
#
# The deploy passes --no-propagate, because a row about what the deploy read
# should not read the child's work as the deploy's own.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

subtest 'a re-parented environment is checked against its current predecessor' => sub {
	# Five rows, and one for the run's own restoration assertion.
	plan tests => 6;

	# bosh => 1 stands the director and the kit up before the seeding, so
	# the kit the deploy needs is committed with everything else.
	# lab and qa are both roots, so once prod follows qa, lab is no ancestor
	# of prod's at all and nothing about this deploy has reason to read it.
	# qa and prod both track the shared ops file, so a commit changing it is
	# in qa's set as well as prod's, and qa holds it until qa certifies it.
	my $shared = ['ops/shared.yml'];
	my $h = ready_harness(envs => ['lab', 'qa', 'prod'], bosh => 1);
	commit_on_control($h, files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'share an ops file');
	write_env_file($h, 'qa', pipeline => {track_additional_files => $shared});
	write_env_file($h, 'prod', pipeline => {prior_env => 'lab',
		track_additional_files => $shared});
	push_from($h, 'a', $h->control);
	my $c1 = $h->git('a')->sha($h->control);
	for my $env (qw/lab qa prod/) {
		deliver($h, $env, control => $c1);
		certify($h, $env, control_commit => $c1);
	}

	# c7 re-parents prod onto qa and changes the shared file in one commit.
	write_env_file($h, 'prod', commit => 0, pipeline => {prior_env => 'qa',
		track_additional_files => $shared});
	my $c7 = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 2\n",
		          'prod.yml'       => slurp($h->a . '/prod.yml')},
		message => 'prod follows qa, and the shared file moves',
		push    => 1);

	# Read off R, which is what was delivered; the clone's own copy of the
	# branch is fast-forwarded to R by the deploy's pre-flight.
	my $slug = $h->slug('prod');
	my ($before) = run({dir => $h->r}, 'git', 'rev-parse', "refs/heads/$slug:prod.yml");

	my (undef, $err, $exit) = run_genesis($h,
		'prod', 'deploy', '--no-propagate', '-y', 'r');
	my $said = unfolded($err);
	is($exit, 0, 'the deploy ran');

	# The log is every vault path this run read.  The harness names an exodus
	# path with a leading slash and safe is handed one without, so the slash
	# is taken off both sides.
	my $log = vault_read_log($h);
	my %read = map {s{^/+}{}r => 1} @$log;
	(my $qa  = $h->env_path('qa')  . '/deployments') =~ s{^/+}{};
	(my $lab = $h->env_path('lab') . '/deployments') =~ s{^/+}{};
	ok($read{$qa}, "the prior-env check reads qa's record, control's predecessor")
		or diag("the paths this run read:\n" . join("\n", @$log));
	ok(!$read{$lab}, "and makes no read of lab's, the branch's")
		or diag("the paths this run read:\n" . join("\n", @$log));

	# qa has not certified c7, so c7 is not due for prod; a deploy that took
	# lab from the branch would find lab's certified commit past it and name it.
	unlike($said, qr/\Q@{[substr($c7, 0, 7)]}\E/,
		'the due-commits warning does not name c7, which qa holds') or diag($said);

	my ($after) = run({dir => $h->r}, 'git', 'rev-parse', "refs/heads/$slug:prod.yml");
	is($after, $before, 'prod.yml on prod/bosh is left exactly as delivered');
};

done_testing;
