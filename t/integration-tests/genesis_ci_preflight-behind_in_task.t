#!/usr/bin/env perl
# Proves T455 and T456 (D30, noted 2026-10-30): in a pipeline task, a control
# that is only behind its remote is the version Concourse had found when it
# made the build, so the run fast-forwards its clone's control to the remote's
# tip and delivers that, naming both commits; where the tip carries a
# different .genesis/bin/genesis, the run replaces itself with it, once.
# Ahead still refuses there, and behind still refuses for an operator.
#
# What the rows catch: a build red for nothing but timing, which is what the
# lmelt PoC's propagate showed after two quick pushes and after a prior
# environment's deploy started it before Concourse had found a push; an
# older Genesis reading a tip that embeds a newer one; and a pass that waved
# through an unpublished control, or an operator's stale clone, which D30
# refuses.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# A Genesis committed at the tip that records how it was run and succeeds.
sub stub_genesis {
	my ($record) = @_;
	return "#!/bin/sh\n# the tip's Genesis, recording its run\n" .
		"printf '%s\\n' \"\$*\" > '$record'\n" .
		"printf '%s\\n' \"\$GENESIS_PROPAGATE_TIP\" >> '$record'\n" .
		"exit 0\n";
}

# The teammate's commit that changes the embedded Genesis, executable as
# Top::embed writes it.
sub publish_new_genesis {
	my ($h, $record) = @_;
	helper::put_file($h->b . '/.genesis/bin/genesis', 0755, stub_genesis($record));
	return publish_from_b($h,
		files   => {'.genesis/bin/genesis' => stub_genesis($record)},
		message => 'embed a newer genesis');
}

subtest 'behind in a pipeline task delivers the tip' => sub {
	my $h = make_harness(envs => ['qa'], applied => 1,
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	init_branch($h, 'qa');
	my $slug  = $h->slug('qa');
	my $given = ref_in($h->a, "refs/heads/@{[$h->control]}");
	my $before_q = remote_sha($h, $slug);
	my $newer = publish_from_b($h,
		files   => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'a newer control commit');

	my ($out, $err, $exit) = run_genesis($h, {pipeline_task => 'propagate', restore => 0}, 'propagate');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the run succeeds') or diag($said);
	like($said, qr/\Q@{[substr($given, 0, 8)]}\E/, 'naming the commit the build was given')
		or diag($said);
	like($said, qr/propagating from control\@\Q@{[substr($newer, 0, 8)]}\E/i,
		'and the tip it propagates') or diag($said);
	isnt(remote_sha($h, $slug), $before_q, 'the environment was delivered to');
	ok((grep {/control\@\Q$newer\E\b/} subjects_of($h, $slug, 3)),
		'with the tip') or diag(join("\n", subjects_of($h, $slug, 3)));
	is(remote_sha($h, $h->control), $newer, 'and control on the remote is where it was');
};

subtest 'a detached clone, as the git resource checks one out, delivers the tip' => sub {
	my $h = make_harness(envs => ['qa'], applied => 1,
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	init_branch($h, 'qa');
	my $slug = $h->slug('qa');
	run({dir => $h->a}, 'git', 'checkout', '-q', '--detach', $h->control);
	my $newer = publish_from_b($h,
		files   => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'a newer control commit');

	my ($out, $err, $exit) = run_genesis($h, {pipeline_task => 'propagate', restore => 0}, 'propagate');
	is($exit, 0, 'the run succeeds') or diag(unfolded($out, $err));
	ok((grep {/control\@\Q$newer\E\b/} subjects_of($h, $slug, 3)),
		'delivering the tip') or diag(join("\n", subjects_of($h, $slug, 3)));
	is(tip_of($h, $h->control), $newer, 'with the clone\'s control moved forward to it');
};

subtest 'a tip embedding another Genesis runs it, with the same arguments' => sub {
	my $h = make_harness(envs => ['qa'], applied => 1,
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	init_branch($h, 'qa');
	my $record = "$h->{tmp}/tip-genesis-ran";
	my $newer  = publish_new_genesis($h, $record);

	my ($out, $err, $exit) = run_genesis($h, {pipeline_task => 'propagate', restore => 0},
		'propagate', '--no-color');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the run succeeds, as the tip\'s Genesis did') or diag($said);
	ok(-f $record, 'the tip\'s Genesis ran') or diag($said);
	my ($args, $guard) = -f $record ? split(/\n/, slurp($record)) : ();
	is($args, 'propagate --no-color', 'with the run\'s own arguments');
	is($guard, $newer, 'told which tip it was run for');
	like($said, qr/\.genesis\/bin\/genesis.*\Q@{[substr($newer, 0, 8)]}\E/i,
		'and the run says it handed over to the tip\'s Genesis') or diag($said);
};

subtest 'the replacement does not replace itself again' => sub {
	my $h = make_harness(envs => ['qa'], applied => 1,
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	init_branch($h, 'qa');
	my $record = "$h->{tmp}/tip-genesis-ran";
	my $newer  = publish_new_genesis($h, $record);

	local $ENV{GENESIS_PROPAGATE_TIP} = $newer;
	my ($out, $err, $exit) = run_genesis($h, {pipeline_task => 'propagate', restore => 0}, 'propagate');
	is($exit, 0, 'the run succeeds') or diag(unfolded($out, $err));
	ok(!-f $record, 'as itself, the tip\'s Genesis never run');
};

subtest 'an unchanged Genesis goes on as itself' => sub {
	my $h = make_harness(envs => ['qa'], applied => 1,
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	init_branch($h, 'qa');
	publish_from_b($h, files   => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'a newer control commit');
	my ($out, $err, $exit) = run_genesis($h, {pipeline_task => 'propagate', restore => 0}, 'propagate');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the run succeeds') or diag($said);
	unlike($said, qr/\.genesis\/bin\/genesis/, 'without handing over') or diag($said);
};

subtest 'ahead in a pipeline task still refuses' => sub {
	my $h = make_harness(envs => ['qa'], applied => 1,
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	init_branch($h, 'qa');
	commit_on_control($h, files => {'qa.yml' => "---\nkit:\n  name: dev\n"},
		message => 'an unpushed control commit', push => 0);
	my (undef, $err, $exit) = run_genesis($h, {pipeline_task => 'propagate', restore => 0}, 'propagate');
	is($exit, Genesis::Exit::DATAERR, 'the run exits DATAERR') or diag($err);
	like(unfolded($err), qr/\bahead\b/, 'naming the state');
};

subtest 'behind for an operator still refuses' => sub {
	my $h = make_harness(envs => ['qa'], applied => 1,
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	init_branch($h, 'qa');
	my $before_q = remote_sha($h, $h->slug('qa'));
	publish_from_b($h, files   => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'a newer control commit');
	my (undef, $err, $exit) = run_genesis($h, 'propagate');
	is($exit, Genesis::Exit::DATAERR, 'the run exits DATAERR') or diag($err);
	like(unfolded($err), qr/\bbehind\b/, 'naming the state');
	is(remote_sha($h, $h->slug('qa')), $before_q, 'and nothing was delivered');
};

done_testing;
