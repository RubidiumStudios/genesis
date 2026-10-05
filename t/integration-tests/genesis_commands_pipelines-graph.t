#!perl
# Proves the half of T350 run without --from: pipeline-graph draws the
# shape control holds, each environment under the one it follows.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'pipeline-graph draws the chain control holds' => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['lab', 'qa', 'prod'], chained => 1,
		vault => 0);

	# Writing pipeline.md is the command's job, so the row asserts the
	# restoration itself, once the drawing is read and taken away.
	my $w = $h->snapshot_w;
	my (undef, $err, $exit) = run_genesis($h, {restore => 0},
		'pipeline-graph');

	is($exit, 0, 'the command succeeds')
		or diag($err);
	like($err, qr{Wrote pipeline\.md}, 'and says where it wrote the drawing');

	my $file = $h->a . '/pipeline.md';
	my $md   = -f $file ? slurp($file) : '';
	like($md, qr{^```mermaid$}m, 'the drawing is a mermaid block');
	like($md, qr{^\s*lab --> qa$}m, 'qa follows lab');
	like($md, qr{^\s*qa --> prod$}m, 'and prod follows qa');

	unlink $file;
	assert_w_restored($w, 'and the drawing is all the run leaves behind');
};

done_testing;
