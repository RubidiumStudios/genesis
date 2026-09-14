#!perl
#
# What pipeline-apply says about a repository's configuration before it
# compiles anything.  Two things happen there.  A repository whose
# provider is manual has no pipeline to apply, and that refusal is a
# configuration refusal, so it carries the named exit code a caller can
# test for rather than the bare one that means a crash.  And a
# repository still carrying the .genesis/ci/ directory is compiled from
# somewhere else entirely, so the run says out loud that the directory
# is not being read and names the section that is.
#
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

use Genesis;
use Genesis::Exit qw/CONFIG/;
provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the manual provider refusal is a configuration refusal' => sub {
	plan tests => 3;

	# The vault is stood up, because the command checks for one before it
	# reads the provider and the refusal under test is the second of the
	# two.
	my $h = make_harness(envs => ['qa'], provider => 'manual');

	my (undef, $err, $exit) = $h->run_genesis({restore => 0}, 'pipeline-apply');

	is($exit, CONFIG,
		'the refusal exits on the configuration code');
	isnt($exit, 1,
		'and not the bare one that stands for a crash');
	like($err, qr/Manual provider has no pipeline to apply/,
		'the operator is told why there is nothing to do');
};

subtest 'a leftover ci directory is named at the compile gate' => sub {
	plan tests => 2;

	# No pipeline section, so the run reaches the compile gate rather
	# than reading the topology off the environment files.
	my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);
	mkdir_or_fail($h->a.'/.genesis/ci');
	put_file($h->a.'/.genesis/ci/pipeline.yml', "pipeline:\n  name: stale\n");

	my ($out, $err) = $h->run_genesis({restore => 0}, 'pipeline-describe');
	my $said = ($out // '') . ($err // '');

	like($said, qr{\.genesis/ci/},
		'the run names the directory it is not reading');
	like($said, qr{pipeline:},
		'and points at the section that configures the repository now');
};

done_testing;
