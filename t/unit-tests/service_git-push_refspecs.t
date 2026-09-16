#!/usr/bin/env perl
# Proves T181: a deployment branch goes out on a plain refspec with no forced
# form, so R's own non-fast-forward rule is what rejects a branch that moved
# since the refresh, and Genesis refuses to rewrite history on control or on
# any deployment branch even when a lease is asked for.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'Genesis refuses to rewrite history on either protected class' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['lab'], vault => 0);
	init_branch($h, 'lab');
	local_branch($h, $h->pr_branch('lab'), at => 'lab/bosh');
	my $git = $h->git('a');

	for my $spec (
		{branch => 'lab/bosh',  kind => 'deployment', expect => 'deadbeef'},
		{branch => $h->control, kind => 'control',    expect => 'deadbeef'},
	) {
		my $err = '';
		{
			# The refusal is a bail, and a bail inside an eval is only
			# catchable where the ignore flag is unset.
			local $ENV{GENESIS_IGNORE_EVAL} = '';
			eval { $git->push(remote => 'origin', refs => [$spec]) };
			$err = $@ // '';
		}
		like(unfolded($err),
			qr/Refusing to push \Q$spec->{branch}\E, because that would rewrite history/,
			"a lease on $spec->{branch} is refused");
	}

	# The same lease on a pull request branch is allowed, because D31 lets a
	# branch that is derived and private until it merges be rewritten.  The
	# null sha asks for a branch the remote has not got yet, which is what
	# this one is.
	my $pr = $git->push(remote => 'origin', refs => [
		{branch => $h->pr_branch('lab'), kind => 'pr',
		 expect => Service::Git::NULL_SHA()},
	]);
	is($pr->[0]{status}, 'created', 'a lease on a PR branch is allowed');
};

subtest 'a deployment branch that moved is rejected by the remote itself' => sub {
	# Four rather than three, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 4;

	my $h = make_harness(envs => ['lab'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	ready_envs($h);

	# Copy B advances lab/bosh on R between copy A's refresh and its push, so
	# the branch the run is about to publish has moved under it.
	move_on_r_at($h, 'lab/bosh', at => 'push', nth => 1);

	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: seven\n"},
		message => 'share an op with every environment',
		push    => 1,
	);

	my ($out, $err) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($out, $err);

	like($said, qr/publish rejected, lab\/bosh moved on R/,
		'the branch was refused');
	unlike($said, qr/force-with-lease|--force\b/,
		'no forced form was ever named for a deployment branch');

	# A lease git turns down is refused for stale info, and this one was
	# refused for the history it would have rewritten, so the push that went
	# out carried no lease at all.
	like($said, qr/fetch first|non-fast-forward/,
		"R's own rule is what rejected it, which is the refusal a plain push earns");
};

done_testing;
