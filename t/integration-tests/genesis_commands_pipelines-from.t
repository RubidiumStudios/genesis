#!perl
# Proves T350: pipeline-graph and pipeline-describe preview the tree in front
# of them, a feature branch included, and --from <ref> reads the shape at that
# ref instead; both say so in a banner and validate the shape as control's
# would be, while every command that acts keeps reading control and refuses
# the flag (D112, noted 2026-10-16).  The pipeline-status clause of step (c)
# is proved in genesis_ci_status-control_shape.t, on a branch that switches
# the pipeline off.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# Control has qa and prod both following lab, and the operator stands on a
# feature branch cut from it, where the row's changes are committed.
sub on_feature_branch {
	my $h = make_harness(envs => ['lab', 'qa', 'prod'], fanned => 'lab',
		vault => 0);
	local_branch($h, 'feature/reshape', at => $h->control);
	stand_on($h, 'feature/reshape');
	return $h;
}

sub commit_here {
	my ($h, $message) = @_;
	run({dir => $h->a}, 'git', 'commit', '-q', '-am', $message);
	return $h->git('a')->sha('HEAD');
}

# pipeline-graph prints the drawing (T375), so the run's own restoration
# assertion is the proof it left nothing behind.
sub graph {
	my ($h, @args) = @_;
	return run_genesis($h, 'pipeline-graph', @args);
}

subtest '(a) the branch re-parents prod, and the previews show it' => sub {
	# Ten rows, and one restoration assertion for each of the four runs.
	plan tests => 14;

	my $h = on_feature_branch();
	write_env_file($h, 'prod', pipeline => {prior_env => 'qa'});
	commit_here($h, 'prod follows qa here');
	my $t     = 'origin/' . $h->control;
	my $short = substr($h->git('a')->sha($t), 0, 7);

	my ($md, $err, $exit) = graph($h);
	is($exit, 0, 'pipeline-graph on the branch succeeds') or diag($err);
	like($md, qr{^\s*qa --> prod$}m, "and draws prod following qa, the branch's shape");
	like(unfolded($err), qr{This preview assumes feature/reshape is merged into \Q${\ $h->control}\E},
		'under a banner naming the branch as previewed as if merged into control');

	my ($out, $derr, $dexit) = run_genesis($h, 'pipeline-describe');
	is($dexit, 0, 'pipeline-describe on the branch succeeds') or diag($derr);
	like($out, qr{^ {6}prod$}m, 'and shows prod under qa');
	like(unfolded($derr), qr{This preview assumes feature/reshape is merged},
		'under the same banner');

	($md, $err, $exit) = graph($h, '--from', $t);
	is($exit, 0, "pipeline-graph --from $t succeeds") or diag($err);
	like($md, qr{^\s*lab --> prod$}m, "and draws control's shape, prod following lab");
	like($err, qr{shape from \Q$t\E at \Q$short\E, not from control},
		'under a banner naming the ref and its commit');

	($out) = run_genesis($h, 'pipeline-describe', '--from', $t);
	like($out, qr{^ {4}prod$}m, "pipeline-describe --from $t shows control's shape too");
};

subtest '(b) a cycle on the branch is refused as it would be on control' => sub {
	# Three rows, and the run's own restoration assertion.
	plan tests => 4;

	my $h = on_feature_branch();
	write_env_file($h, 'prod', pipeline => {prior_env => 'qa'});
	write_env_file($h, 'lab',  pipeline => {prior_env => 'prod'});
	commit_here($h, 'lab follows prod, closing a cycle');

	my (undef, $err, $exit) = graph($h);
	is($exit, 78, 'pipeline-graph refuses at CONFIG');
	like($err, qr{prior_env forms a cycle}, 'naming the cycle');
	like($err, qr{lab follows prod}, 'and the file that closes it');
};

subtest '(c) a pipeline disabled on the branch is reported as disabled there' => sub {
	# Three rows, and the run's own restoration assertion.
	plan tests => 4;

	my $h = on_feature_branch();
	require Genesis::Config;
	my $config = Genesis::Config->new($h->a . '/.genesis/config');
	$config->set('pipeline.enabled' => 0);
	$config->save;
	commit_here($h, 'switch the pipeline off here');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-describe');
	is($exit, 0, 'pipeline-describe succeeds') or diag($err);
	like($out, qr{pipeline is disabled in the working tree},
		'and reports the pipeline disabled in its preview');
	unlike($out, qr{Environment progression}, 'drawing no progression for it');
};

subtest '(d) the commands that act refuse --from' => sub {
	# Four rows, and one restoration assertion for each run.
	plan tests => 6;

	my $h = on_feature_branch();

	# An option a command does not declare is refused with the command's
	# usage and exit 2; genesis-cli.t pins that neither declares from.
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--from', 'HEAD');
	is($exit, 2, 'propagate --from HEAD is refused as a usage error');
	like($err, qr{Usage: genesis propagate}, 'with the usage it does accept');

	(undef, $err, $exit) = run_genesis($h, 'prod', 'deploy', '--from', 'HEAD');
	is($exit, 2, 'prod deploy --from HEAD is refused as a usage error');
	like($err, qr{Usage: genesis .*deploy}, 'with the usage it does accept');
};

subtest 'a ref that names no commit is refused by name' => sub {
	# Two rows, and the run's own restoration assertion.
	plan tests => 3;

	my $h = on_feature_branch();
	my (undef, $err, $exit) = run_genesis($h, 'pipeline-describe', '--from', 'no-such-ref');
	isnt($exit, 0, 'pipeline-describe --from no-such-ref is refused');
	like($err, qr{from no-such-ref, which names no commit},
		'naming the ref it could not read');
};

done_testing;
