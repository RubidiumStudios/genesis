#!/usr/bin/env perl
# Proves T180: control is re-checked against the remote before the first push,
# a control that moved refuses the publish naming behind as stale, nothing is
# pushed, every branch the run wrote is put back, and control is never among
# the branches the run publishes.
#
# Every phrase is matched across the wrap.  A refusal is wrapped to the
# terminal width before it reaches standard error, so a clause the reader sees
# on one line can arrive with a newline and an indent inside it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a control that moved during the walk refuses the publish' => sub {
	# Six rather than five, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 6;

	my $h = make_harness(envs => ['lab', 'qa'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	ready_envs($h);

	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: ten\n"},
		message => 'share an op with every environment',
		push    => 1,
	);

	# A teammate publishes to control while the run is walking.  The commit
	# is taken from what the remote holds now, so the run comes back from
	# the fetch behind by one rather than diverged, which is the state the
	# refusal below reads.
	my $theirs = move_on_r_at($h, $h->control, at => 'commit', nth => 1,
		files   => {'ops/theirs.yml' => "---\nby: the teammate\n"},
		message => 'a teammate pushed to control',
	);

	my @before = map {ref_in($h->r, "refs/heads/$_/bosh")} qw/lab qa/;

	my ($out, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($out, $err);

	is($exit, Genesis::Exit::DATAERR, 'the run refuses on its own input');
	like($said, qr/is behind .* so everything this run computed is stale/,
		'and it names behind as stale');

	is_deeply([map {ref_in($h->r, "refs/heads/$_/bosh")} qw/lab qa/], \@before,
		'neither branch moved on R, because nothing was pushed');

	is(ref_in($h->a, 'refs/heads/lab/bosh'),
		ref_in($h->a, 'refs/remotes/origin/lab/bosh'),
		'every branch the run wrote was reset to T');

	is(ref_in($h->r, 'refs/heads/'.$h->control), $theirs,
		'control is where the teammate left it');
};

subtest 'control is never in the push set' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['lab'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	ready_envs($h);

	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: eleven\n"},
		message => 'add an op for lab',
		push    => 1,
	);

	my ($out, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($out, $err);

	is($exit, 0, 'the run published');
	is(ref_in($h->r, 'refs/heads/lab/bosh'),
		ref_in($h->a, 'refs/heads/lab/bosh'), 'lab published');

	# The publish names each branch it pushed, one line apiece, so the
	# absence of control's own line is the absence of control from the set.
	# The specs cannot be read back out of the step log, because the log
	# stringifies a hashref, so the run's own words answer instead.
	unlike($said, qr/\Q@{[$h->control]}\E: published/,
		'control was not among the branches the run published');
};

done_testing;
