#!perl
# Proves T375, and the drawing half of T350: pipeline-graph draws the shape in
# front of it, each environment under the one it follows, on standard output
# unless --output names a file, so a preview never dirties the tree it reads
# (D112, noted 2026-10-16).
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

subtest 'pipeline-graph prints the chain and writes nothing' => sub {
	# Five rows, and the run's own restoration assertion, which is the
	# proof that no file was written.
	plan tests => 6;

	my $h = make_harness(envs => ['lab', 'qa', 'prod'], chained => 1,
		vault => 0);
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-graph');

	is($exit, 0, 'the command succeeds')
		or diag($err);
	like($out, qr{^```mermaid$}m, 'the drawing is a mermaid block, on standard output');
	like($out, qr{^\s*lab --> qa$}m, 'qa follows lab');
	like($out, qr{^\s*qa --> prod$}m, 'and prod follows qa');
	ok(!-f $h->a . '/pipeline.md', 'and no pipeline.md was written');
};

subtest '--output writes the drawing to the file it names' => sub {
	# Four rows, and the restoration assertion once the file is taken away.
	plan tests => 5;

	my $h = make_harness(envs => ['lab', 'qa', 'prod'], chained => 1,
		vault => 0);
	my $w = $h->snapshot_w;
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'pipeline-graph', '--output', 'graph.md');

	is($exit, 0, 'the command succeeds')
		or diag($err);
	like($err, qr{Wrote graph\.md}, 'and says where it wrote the drawing');
	unlike($out, qr{mermaid}, 'printing nothing of the chart');

	my $file = $h->a . '/graph.md';
	my $md   = -f $file ? slurp($file) : '';
	like($md, qr{^\s*qa --> prod$}m, 'the file holds the drawing');

	unlink $file;
	assert_w_restored($w, 'and the file is all the run leaves behind');
};

done_testing;
