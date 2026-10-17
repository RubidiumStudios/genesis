#!perl
# Proves T381: a preview of a repository with no pipeline says so before it
# compiles anything (runbook finding 27).  With no pipeline section in
# .genesis/config, pipeline-describe, pipeline-graph and pipeline-diff refuse
# at CONFIG naming the section, and none of them reaches the parser; in a
# version 2 repository the refusal also names the move to version 3.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/mkfile_or_fail/;
use Genesis::Exit;
provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my @PREVIEWS = (['pipeline-describe'], ['pipeline-graph'], ['pipeline-diff']);

sub refused_plainly {
	my ($h, $label, $extra) = @_;
	for my $argv (@PREVIEWS) {
		my (undef, $err, $exit) = run_genesis($h, @$argv);
		my $said = unfolded($err);
		is($exit, Genesis::Exit::CONFIG, "`genesis @$argv` refuses at CONFIG, $label");
		like($said, qr/no pipeline is configured.*\bpipeline\b section/i,
			'saying no pipeline is configured, and naming the section');
		unlike($said, qr/Parsing pipeline configuration|Pipeline configuration is invalid/,
			'without reaching the parser');
		like($said, $extra, 'and naming the move to version 3') if $extra;
	}
}

subtest 'a version 3 repository with no pipeline section' => sub {
	# Three rows per preview, and one restoration assertion for each run.
	plan tests => 12;
	my $h = make_harness(envs => ['qa'], pipeline => 'none', vault => 0);
	refused_plainly($h, 'on v3');
};

subtest 'a version 2 repository, which takes no pipeline' => sub {
	# Four rows per preview, and one restoration assertion for each run.
	plan tests => 15;
	my $h = make_harness(envs => ['qa'], pipeline => 'none', vault => 0);
	mkfile_or_fail($h->a . '/.genesis/config', join("\n",
		'---', 'creator_version: 3.1.0', 'deployment_type: bosh',
		'manifest_store: exodus', 'version: 2', ''));
	refused_plainly($h, 'on v2', qr/genesis config --set version 3/);
};

done_testing;
