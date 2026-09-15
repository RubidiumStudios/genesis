#!/usr/bin/env perl
# Proves T122 and T129: the apply creates each missing deployment branch as an
# orphan root commit adding one init file under the [ci skip] subject, names it
# from the deployment slug, and leaves the operator's working state alone.
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
use Genesis::Commands::Pipelines;

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

# _unfolded - what the run said, put back on one line
#
# A run folds what it says to the terminal's width on the way out, so a
# phrase can arrive with a newline and an indent in the middle of it.  The
# rows below read what the operator was told rather than where the fold
# landed, so the two streams are joined and their whitespace is collapsed
# before anything is matched.  The streams are joined on a newline so that no
# phrase can match across the seam where one ends and the other begins.
sub _unfolded {
	my $said = join("\n", map {$_ // ''} @_);
	$said =~ s/\s+/ /g;
	return $said;
}

subtest 'an environment with no branch gets an orphan init branch' => sub {
	# Seven rows, and one more for the run's own restoration assertion, which
	# run_genesis makes unless a row turns it off.  The creation is plumbing,
	# so a working state that moved would be a defect this row should catch.
	plan tests => 8;

	my $h = make_harness(envs => ['qa']);
	my (undef, undef, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0');

	my $sha = ref_in($h->r, 'qa/bosh');
	ok($sha, 'R carries qa/bosh');

	is_deeply(tree_of($h->r, 'qa/bosh'), ['init'],
		'the init branch holds the init file alone');

	# The bytes and not the shape.  An init file written empty, or written
	# with the commit message in it, passes every other row in this file,
	# and the body is the whole reason the file is there, since an operator
	# who meets the branch in a fresh clone has nothing else to read.
	is(blob_at($h->r, 'qa/bosh', 'init'),
		Genesis::Commands::Pipelines::INIT_FILE_BODY(),
		'the init file carries the body the command writes, byte for byte');

	is(git_in($h->r, 'log', '-1', '--format=%s', 'qa/bosh'),
		'Initialize qa/bosh branch [ci skip]',
		'the root commit carries the subject and the [ci skip] marker');

	is(git_in($h->r, 'log', '-1', '--format=%P', 'qa/bosh'), '',
		'the init commit is an orphan root');

	my $shared = run({dir => $h->r, passfail => 1},
		'git', 'merge-base', '--is-ancestor', $h->control, 'qa/bosh');
	ok(!$shared, 'it shares no history with control');
};

subtest 'a branch the clone alone holds is published' => sub {
	# Four rows, and one for the run's own restoration assertion.
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);
	my $local = init_branch($h, 'qa', push => 0);
	is(remote_sha($h, 'qa/bosh'), undef, 'R does not carry the branch yet');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0');

	is(remote_sha($h, 'qa/bosh'), $local,
		'R now holds the branch at the tip the clone already had');
	like(_unfolded($out, $err), qr{published qa/bosh},
		'and the run reports it as published rather than created');
};

subtest 'the publish goes to the remote the configuration names' => sub {
	# Three rows, and one for the run's own restoration assertion.
	plan tests => 4;

	# git lists remotes alphabetically, so dev stands ahead of origin, and a
	# stage that published to the first remote it found would publish there
	# rather than to the remote pipeline.source_control.remote names.
	my $h = make_harness(envs => ['qa'], source_control => {remote => 'origin'});
	my $other = second_remote($h, name => 'dev');

	my (undef, undef, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0');

	ok(remote_sha($h, 'qa/bosh'),
		'the branch landed on the remote the configuration names');
	is_deeply([sort keys %{refs_in($other, prefix => 'refs/heads')}], [],
		'and nothing was pushed to the remote git happens to list first');
};

subtest 'a clone without the configured remote is refused before anything is cut' => sub {
	# Four rows, and one for the run's own restoration assertion.
	plan tests => 5;

	# The remote is named in the configuration and absent from the clone,
	# which is how a repository reaches the stage with nowhere to publish
	# to.  A repository that names no remote either is turned away earlier
	# still, by the source-control derivation, and that is a different
	# refusal about a different thing.
	my $h = make_harness(envs => ['qa'], source_control => {remote => 'origin'});
	drop_remotes($h);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = _unfolded($out, $err);

	is($exit, Genesis::Exit::CONFIG,
		'the refusal exits Genesis::Exit::CONFIG, because a missing remote is configuration');
	like($said, qr/no git remote named origin/,
		'the refusal names the remote it looked for');
	like($said, qr/No branch was created/,
		'and says that nothing was written');
	is(ref_in($h->a, 'refs/heads/qa/bosh'), undef,
		'no orphan is left standing behind the refusal');
};

subtest 'a standing branch is left where it is' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	my $before = init_branch($h, 'qa');

	my (undef, undef, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0 with the branch already standing');

	is(ref_in($h->r, 'qa/bosh'), $before,
		'the standing branch was not recreated');
};

subtest 'two roots serving one environment get two branches' => sub {
	# Four rows, and one restoration assertion for each of the two runs.
	plan tests => 6;

	my $h = make_harness(envs => ['qa']);
	add_deployment_root($h, type => 'doomsday', envs => ['qa'], path => 'doomsday');

	my (undef, undef, $first)  = run_genesis($h, 'pipeline-apply');
	my (undef, undef, $second) = run_genesis($h, {dir => 'doomsday'}, 'pipeline-apply');
	is($first,  0, 'the apply in the bosh root exits 0');
	is($second, 0, 'the apply in the doomsday root exits 0');

	my @branches = @{branches_on_r($h)};

	is_deeply([grep {$_ ne $h->control} @branches], ['qa/bosh', 'qa/doomsday'],
		'each deployment has its own branch, composed from its own type');
	ok(!(grep {$_ eq 'qa'} @branches),
		'nothing cut the bare environment name the baseline would have used');
};

done_testing;
