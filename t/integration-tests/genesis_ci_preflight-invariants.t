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

	# Three spellings of a forced write, each asked whether control is what
	# it names: the service's own primitive, git's plumbing, and git's
	# porcelain.  Comments come out first, so a note that merely mentions one
	# of the three is not read as a call.
	#
	# A write that reached control through a variable spelled some other way
	# would pass all three unseen, so this row is a tripwire for the obvious
	# ways back in rather than a proof.  The proof is the row above it, which
	# reads the ref itself after a run and would go red whatever spelling
	# moved it.
	my $src = join("\n", map {strip_comment($_)} split(/\n/,
		join('', map { slurp($_) }
			qw(lib/Genesis/CI/Preflight.pm lib/Genesis/Commands/Pipelines.pm)), -1));
	unlike($src,
		qr{set_branch_ref\([^)]*control
		  |update-ref[^;]*control
		  |['"]branch['"][^;]*-f[^;]*control}xi,
		'and no spelling of a forced write in the run names control');
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

	# The branch name can wrap at its slash, so it is matched a segment at a
	# time wherever a row reads it out of the run's own account of itself.
	my $qa_re = join('\s*/\s*', map {quotemeta} split m{/}, $qa);

	my (undef, $err) = run_genesis($h, 'propagate');
	like($err, qr{reset\s+$qa_re\s+to\s+\S*origin/$qa_re},
		'the marker-only commit is reset, which is the one forced write');

	# Call sites rather than occurrences, with the comments taken out first.
	# Counting the bare name made a later comment that merely named the sub
	# turn this row red, which says nothing about what the module does.
	my $src = join("\n", map {strip_comment($_)} split(/\n/,
		slurp('lib/Genesis/CI/Preflight.pm'), -1));
	my @calls = ($src =~ m{(\$git->set_branch_ref\()}g);
	is(scalar @calls, 2,
		'and the module calls the forced write at two sites only, the reset and the fast-forward');
};

subtest 'every divergence refusal names the branch and both counts' => sub {
	# Six rows, and one more for each of the three runs.
	plan tests => 9;

	# Both control harnesses call the branch trunk rather than taking the
	# harness's default, and both rows read the remote-qualified spelling.
	# The refusal's own prose carries the bare word control twice, in "The
	# control branch" and in "Genesis never moves control", so a row that
	# asked for that word alone against a branch called control matched the
	# sentence whether or not the branch was named in it and could not go
	# red.  Naming the branch trunk takes the word out of the collision, and
	# reading origin/trunk asks for the one form only a named branch
	# produces, since a refusal that dropped the name would have nothing to
	# qualify.

	# Control ahead.
	my $h1 = make_harness(envs => ['qa'], control => 'trunk');
	init_branch($h1, 'qa');
	commit_on_control($h1, files => {'ops/mine.yml' => "---\n"}, push => 0);
	my (undef, $ahead_err) = run_genesis($h1, 'propagate');
	like($ahead_err, qr/is\s+ahead\s+of\s+\S*origin\/\Q@{[$h1->control]}\E\b/,
		'the control-ahead refusal names the branch');
	like($ahead_err, qr/by\s+1\s+commit/, 'and names the count');

	# Control behind.
	my $h2 = make_harness(envs => ['qa'], control => 'trunk');
	init_branch($h2, 'qa');
	publish_from_b($h2, files => {'ops/theirs.yml' => "---\n"});
	my (undef, $behind_err) = run_genesis($h2, 'propagate');
	like($behind_err, qr/is\s+behind\s+\S*origin\/\Q@{[$h2->control]}\E\b/,
		'the control-behind refusal names the branch');
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
	# Nine rows, and one more for each of the two runs.
	plan tests => 11;

	# The kit is here so the walk can reach an environment at all.  Each
	# environment is loaded before it is diffed, and a kitless harness leaves
	# every one of them skipped, so the row about the branch with nothing due
	# would rest on a walk that considered nothing.
	my $h    = make_harness(envs => ['qa', 'prod'], kit => 'omega-v2.7.0');
	my $qa   = $h->slug('qa');
	my $prod = $h->slug('prod');
	my $pr   = $h->pr_branch('qa');

	init_branch($h, $_) for qw/qa prod/;
	refresh($h, 'a', $qa, $prod);
	# Nothing here opens a pull request branch, so this push cannot fire
	# today.  It is here for the publish and the pull request paths, which
	# give the pull request branch its own actions, and those are what would
	# make the row below it bite.
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
	# The other environment is delivered the same control commit here in
	# copy A, which pushes it, so prod stands in step with the remote and
	# with control and the walk finds nothing due for it.  Without that the
	# walk would have something to deliver to prod, and the writer still
	# switches to the environment's own name, which is a branch a typed
	# repository cannot hold.
	deliver($h, 'prod', control => $control, copy => 'a');
	refresh($h, 'a', $qa);
	my $before_control  = ref_in($h->a, "refs/heads/@{[$h->control]}");
	my $before_prod_now = ref_in($h->a, "refs/heads/$prod");

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	# The exit code is read because the three rows below it are all rows
	# about something that did not move, and a run that fell over would
	# satisfy every one of them.  Should prod ever fall due here again, the
	# writer would switch to the environment's own name and fail on a branch
	# a typed repository cannot hold, and without this row the subtest would
	# stay green across that run.
	is($exit, 0, 'the run finishes cleanly');
	# The walk is where an environment is judged due or not due, so the rows
	# below rest on a walk that ran rather than on one that skipped
	# everything before it decided anything.
	like($err, qr{Propagating from}, 'the run reaches the walk');
	is(ref_in($h->a, "refs/heads/@{[$h->control]}"), $before_control,
		'fast-forwarding a deployment branch moved control no way at all');
	is(ref_in($h->r, $h->control), ref_in($h->a, "refs/heads/@{[$h->control]}"),
		'and control on the remote is where it was');
	# The walk reads an environment's own deployment record only once it has
	# loaded the environment, found the branch the pre-flight settled, and
	# read the marker that branch carries.  A read under prod's exodus base
	# is therefore the run saying it judged prod, rather than skipping it
	# before it decided anything.  The base is matched without its leading
	# slash, because the deployments reader spells the path without one.
	(my $prod_base = $h->env_path('prod')) =~ s{^/}{};
	ok((grep {m{\Q$prod_base\E}} @{vault_read_log($h)}),
		'and it judged the other environment rather than passing it over');
	is(ref_in($h->a, "refs/heads/$prod"), $before_prod_now,
		'which it found nothing due for, and left where it stood');
};

done_testing;
