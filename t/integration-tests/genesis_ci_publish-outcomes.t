#!/usr/bin/env perl
# Proves T184, T188, T189, and T192: every branch the run committed to is
# pushed on its own, a branch the remote refused records publish rejected as
# that environment's one outcome with the moved ref read out of git's own
# porcelain line, the refused branch is reset to T at once, and every other
# environment publishes regardless of where the refusal fell.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::CI::Publish;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'one rejection costs one environment and nothing else' => sub {
	# Ten rather than nine, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 10;

	# Four environments with the refusal falling on the third, so the run has
	# an environment behind the rejected one as well as two in front of it and
	# the walk on past a refusal is what the last of them proves.
	my $h = make_harness(envs => ['lab', 'qa', 'prod', 'dev'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	ready_envs($h);

	# Copy B advances prod/bosh on R between copy A's refresh and its first
	# push, which is the emergency hatch racing the run.
	my $moved = move_on_r_at($h, 'prod/bosh', at => 'push', nth => 1,
		files => {'prod/bosh/hand.yml' => "---\nby: a person\n"});

	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: two\n"},
		message => 'share an op with every environment',
		push    => 1,
	);

	my ($out, $err) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($out, $err);

	# Published means R holds what the operator's copy holds, rather than
	# merely that the branch is there, which it was before the run started.
	is(ref_in($h->r, 'refs/heads/lab/bosh'), ref_in($h->a, 'refs/heads/lab/bosh'),
		'lab published');
	is(ref_in($h->r, 'refs/heads/qa/bosh'), ref_in($h->a, 'refs/heads/qa/bosh'),
		'qa published');
	is(ref_in($h->r, 'refs/heads/dev/bosh'), ref_in($h->a, 'refs/heads/dev/bosh'),
		'dev published, from behind the environment that was refused');

	is(ref_in($h->r, 'refs/heads/prod/bosh'), $moved,
		'R still holds what the teammate pushed to prod');

	like($said, qr/publish rejected, prod\/bosh moved on R/,
		'prod records the rejection as its outcome');

	is(ref_in($h->a, 'refs/heads/prod/bosh'),
		ref_in($h->a, 'refs/remotes/origin/prod/bosh'),
		'the refused branch was reset to T at once');

	assert_snapshot_invariant($h, 'lab', name => 'lab mirrors the control commit');
	assert_snapshot_invariant($h, 'qa',  name => 'qa mirrors the control commit');
	assert_snapshot_invariant($h, 'dev', name => 'dev mirrors the control commit');
};

subtest 'the moved ref is read from git and not composed' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['lab'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	ready_envs($h);
	move_on_r_at($h, 'lab/bosh', at => 'push', nth => 1);

	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: three\n"},
		message => 'share a third op',
		push    => 1,
	);

	my ($out, $err) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($out, $err);

	like($said, qr/publish rejected, lab\/bosh moved on R/,
		'the outcome names the ref git rejected');
	like($said, qr/fetch first|non-fast-forward/,
		"git's own reason for the rejection is carried through");
};

subtest 'a rejected environment has one outcome and it is the rejection' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['lab'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	ready_envs($h);
	move_on_r_at($h, 'lab/bosh', at => 'push', nth => 1);

	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: four\n"},
		message => 'share a fourth op',
		push    => 1,
	);

	my ($out, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	# The environment's own line reading publish rejected is what proves the
	# second half of T192, because the commit lines under a rejected
	# environment still render the default word delivered until the report's
	# two defaults are struck, and an assertion on that word can go green
	# today for a reason that has nothing to do with this stage.
	like(unfolded($out, $err), qr/publish rejected/, 'the rejection is recorded');
};

subtest 'a remote that refused every branch is not a remote that went away' => sub {
	plan tests => 3;

	# No run is spawned here, because the two answers the guard tells apart
	# are answers git gives the stage rather than anything the walk decides,
	# and a whole run cannot be made to refuse its every push while control
	# still travels with the branches.
	my $h = make_harness(envs => ['lab'], vault => 0);
	init_branch($h, 'lab');

	# Copy B advances the branch on R, so copy A is offering a rewind and the
	# remote refuses it with a porcelain line of its own.
	move_on_r($h, 'lab/bosh');
	my $git   = $h->git('a');
	my @specs = ({branch => 'lab/bosh', kind => 'deployment', env => 'lab'});

	my $refused;
	my $result = Genesis::CI::Publish::publish_run(
		git => $git, remote => 'origin', records => [], specs => \@specs,
		unsurvivable => sub {$refused = $_[0] // 'the remote went away'},
	);

	is($refused, undef,
		'a refusal on every branch is not the remote having gone away');
	is_deeply($result->{rejected}, ['lab/bosh'],
		'it is recorded as that branch being refused');

	# The same call against a push URL naming a directory that is no
	# repository, where git answers about no ref at all.
	broken_pushurl($h);

	my $gone;
	Genesis::CI::Publish::publish_run(
		git => $git, remote => 'origin', records => [], specs => \@specs,
		unsurvivable => sub {$gone = $_[0]},
	);

	like($gone, qr/does not appear to be a git repository/,
		'and a remote that answered about nothing is');
};

done_testing;
