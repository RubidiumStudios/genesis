#!/usr/bin/env perl
# Proves T102, T103, and T314: no path force-writes control, only the
# pre-flight's reset forces a deployment branch, every divergence refusal
# names the branch and both counts, and one class's action leaves the
# other two classes alone.
#
# This file asserts across everything the eight tasks before it built and
# it adds no product code of its own.  Where a row here is green from the
# day it is written, that is the sweep confirming a claim one of those
# tasks already landed rather than a row that proves nothing.
#
# Every phrase is matched across the wrap.  A refusal and an event line are
# both wrapped to the terminal width before they reach standard error, so a
# clause the reader sees on one line can arrive with a newline and an indent
# inside it, and a branch name can break at its slash.
#
# Genesis accounts for itself on standard error, which is where info writes,
# so every line the run reports is read out of the second value rather than
# the first.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit qw/DATAERR/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'no path force-writes the local control ref' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	plan tests => 4;

	my $h  = make_harness(envs => ['qa']);
	my $qa = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $qa);

	my $mine = commit_on_control($h,
		files => {'ops/mine.yml' => "---\nmine: 1\n"}, push => 0);
	publish_from_b($h,
		files   => {'ops/theirs.yml' => "---\ntheirs: 1\n"},
		message => 'a teammate publishes onto control');

	my (undef, undef, $exit) = run_genesis($h, 'propagate');

	is($exit, DATAERR, 'the run refuses the diverged control');
	is(ref_in($h->a, "refs/heads/@{[$h->control]}"), $mine,
		'and my commit is exactly where I left it');

	my $src = join('', map { slurp($_) }
		qw(lib/Genesis/CI/Preflight.pm lib/Genesis/Commands/Pipelines.pm));
	unlike($src, qr{set_branch_ref\([^)]*control}i,
		'nothing in the run forces the control ref at all');
};

subtest 'an absent local ref is created from the remote and nothing else is' => sub {
	plan tests => 3;

	my $h    = make_harness(envs => ['qa', 'prod']);
	my $qa   = $h->slug('qa');
	my $prod = $h->slug('prod');
	init_branch($h, $_) for qw/qa prod/;
	refresh($h, 'a', $qa, $prod);
	delete_local($h, 'a', $prod);

	my $before = refs_in($h->a);
	my (undef, $result) = $h->git('a')->fetch_branches([$qa, $prod, $h->control]);
	my $after = refs_in($h->a);

	is_deeply($result->{created}, [$prod], 'one ref was created');
	is($after->{"refs/heads/$prod"}, ref_in($h->r, $prod),
		'and it holds what the remote holds');
	is_deeply(
		{map { $_ => $after->{$_} } grep { $_ ne "refs/heads/$prod" && !m{^refs/remotes/} } keys %$after},
		{map { $_ => $before->{$_} } grep { !m{^refs/remotes/} } keys %$before},
		'and no other local ref moved');
};

subtest 'the only forced write onto a deployment branch is the reset' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	my $h  = make_harness(envs => ['qa']);
	my $qa = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $qa);

	# An ops file rather than a rewritten qa.yml.  The environment file is
	# where the pipeline metadata lives, so overwriting it strips qa out of
	# the topology and the run bails on an empty one several steps before
	# the reset this row is about.
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nfrom: control\n"}, push => 1);
	# The marker is what makes this a commit the walk reproduces.  No
	# message goes with it, because the harness discards a message whenever
	# a marker is asked for.
	local_only_commit($h, $qa, marker => $control);
	# local_only_commit checks the branch out and leaves the copy standing
	# there, and a deployment branch here is the init branch, whose whole
	# tree is one file called init, so a command run from it finds no
	# deployment root at all.
	stand_on($h, $h->control);

	my (undef, $err) = run_genesis($h, 'propagate');
	like($err, qr{reset\s+qa\s*/\s*bosh\s+to\s+\S*origin/qa\s*/\s*bosh},
		'the marker-only commit is reset, which is the one forced write');

	my $src = slurp('lib/Genesis/CI/Preflight.pm');
	my @forces = ($src =~ m{(set_branch_ref)}g);
	is(scalar @forces, 2,
		'and the module forces a branch in two places only, the reset and the fast-forward');
};

subtest 'every divergence refusal names the branch and both counts' => sub {
	# Six rows, and one more for each of the three runs.
	plan tests => 9;

	# Control ahead.
	my $h1 = make_harness(envs => ['qa']);
	init_branch($h1, 'qa');
	commit_on_control($h1, files => {'ops/mine.yml' => "---\n"}, push => 0);
	my (undef, $ahead_err) = run_genesis($h1, 'propagate');
	like($ahead_err, qr/\Q@{[$h1->control]}\E/, 'the control-ahead refusal names the branch');
	like($ahead_err, qr/by\s+1\s+commit/, 'and names the count');

	# Control behind.
	my $h2 = make_harness(envs => ['qa']);
	init_branch($h2, 'qa');
	publish_from_b($h2, files => {'ops/theirs.yml' => "---\n"});
	my (undef, $behind_err) = run_genesis($h2, 'propagate');
	like($behind_err, qr/\Q@{[$h2->control]}\E/, 'the control-behind refusal names the branch');
	like($behind_err, qr/by\s+1\s+commit/, 'and names the count');

	# A diverged deployment branch carrying a hand commit.
	my $h3  = make_harness(envs => ['qa']);
	my $qa3 = $h3->slug('qa');
	# The branch name can wrap at its slash, so it is matched a segment at
	# a time wherever a row reads it out of a refusal.
	my $qa3_re = join('\s*/\s*', map {quotemeta} split m{/}, $qa3);
	init_branch($h3, 'qa');
	refresh($h3, 'a', $qa3);
	commit_on_control($h3,
		files => {'ops/shared.yml' => "---\nfrom: control\n"}, push => 1);
	diverge($h3, $qa3, local => 0, remote => 2);
	hand_commit($h3, $qa3, copy => 'a', push => 0, message => 'a hand edit');
	# hand_commit leaves copy A standing on the deployment branch, which
	# carries no deployment root, so the copy stands back on control.
	stand_on($h3, $h3->control);
	my (undef, $div_err) = run_genesis($h3, 'propagate');
	like($div_err, qr/$qa3_re\s+is\s+ahead\s+of\s+\S*origin\/$qa3_re\s+by\s+1\s+commit/,
		'the diverged-branch refusal names the branch and the ahead count');
	like($div_err, qr/behind\s+it\s+by\s+2\s+commits/, 'and the behind count');
};

subtest 'one class action leaves the other two classes alone' => sub {
	# Six rows, and one more for each of the two runs.
	plan tests => 8;

	my $h    = make_harness(envs => ['qa', 'prod']);
	my $qa   = $h->slug('qa');
	my $prod = $h->slug('prod');
	my $pr   = $h->pr_branch('qa');

	init_branch($h, $_) for qw/qa prod/;
	refresh($h, 'a', $qa, $prod);
	push_from($h, 'a', $pr) if $h->git('a')->branch_exists($pr);

	# The control action: create the local ref from the remote.  The working
	# tree steps off control onto control's own commit rather than onto a
	# deployment branch, because git refuses to fetch into the branch it is
	# standing on and a deployment branch carries none of the repository's
	# configuration.
	stand_on($h, ref_in($h->a, "refs/heads/@{[$h->control]}"));
	delete_local($h, 'a', $h->control);
	my $before_qa   = ref_in($h->a, "refs/heads/$qa");
	my $before_prod = ref_in($h->a, "refs/heads/$prod");
	run_genesis($h, 'pipeline-status');
	is(ref_in($h->a, "refs/heads/$qa"), $before_qa,
		'creating control moved no deployment branch');
	is(ref_in($h->a, "refs/heads/$prod"), $before_prod, 'nor the other one');
	is(ref_in($h->a, "refs/heads/$pr"), undef,
		'and it made no pull request branch');

	# The deployment-branch action: fast-forward one of them.
	stand_on($h, $h->control);
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nfrom: control\n"}, push => 1);
	deliver($h, 'qa', control => $control, copy => 'b');
	refresh($h, 'a', $qa);
	my $before_control  = ref_in($h->a, "refs/heads/@{[$h->control]}");
	my $before_prod_now = ref_in($h->a, "refs/heads/$prod");

	run_genesis($h, 'propagate');

	is(ref_in($h->a, "refs/heads/@{[$h->control]}"), $before_control,
		'fast-forwarding a deployment branch moved control no way at all');
	is(ref_in($h->r, $h->control), ref_in($h->a, "refs/heads/@{[$h->control]}"),
		'and control on the remote is where it was');
	is(ref_in($h->a, "refs/heads/$prod"), $before_prod_now,
		'and the deployment branch with nothing due was left alone');
};

done_testing;
