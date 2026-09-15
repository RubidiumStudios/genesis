#!perl
#
# What pipeline-apply makes of a repository's configuration before it
# compiles anything.  Two things happen there.  A repository whose
# provider is manual has branches to create and no pipeline to set, so
# the apply does the branch work, says which stage it skipped, and exits
# 0 rather than refusing.  And a repository still carrying the
# .genesis/ci/ directory is compiled from the pipeline section of
# .genesis/config alone, so the leftover directory is ignored and the
# run never names it.
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

subtest 'the manual provider skips the stages it has nothing for' => sub {
	plan tests => 3;

	# The vault is stood up, because the command checks for one before it
	# reads the provider and the skip under test comes after that.
	my $h = make_harness(envs => ['qa'], provider => 'manual');

	my ($out, $err, $exit) = $h->run_genesis({restore => 0}, 'pipeline-apply');
	my $said = _unfolded($out, $err);

	is($exit, 0,
		'the manual apply exits 0, because a skipped stage is not a failure');
	isnt($exit, CONFIG,
		'and not the configuration code, which would say the run was refused');
	like($said, qr/manual provider has no pipeline to set/i,
		'the operator is told which stage was skipped and why');
};

# _unfolded - what the run said, put back on one line
#
# A run folds what it says to the terminal's width on the way out, so a
# phrase can arrive with a newline and an indent in the middle of it.
# The rows below read what the operator was told rather than where the
# fold landed, so the two streams are joined and their whitespace is
# collapsed before anything is matched.
sub _unfolded {
	my $said = join('', map {$_ // ''} @_);
	$said =~ s/\s+/ /g;
	return $said;
}

subtest 'a leftover ci directory is ignored and never named' => sub {
	plan tests => 2;

	# No pipeline section, so the run reaches the compile gate rather
	# than reading the topology off the environment files.
	my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);
	mkdir_or_fail($h->a.'/.genesis/ci');
	# The pipeline the leftover file names is the row's marker, so it is
	# spelled as something no other message could say by accident.
	put_file($h->a.'/.genesis/ci/pipeline.yml',
		"pipeline:\n  name: leftover-ci-directory-marker\n");

	my ($out, $err) = $h->run_genesis({restore => 0}, 'pipeline-describe');
	my $said = _unfolded($out, $err);

	unlike($said, qr{\.genesis/ci\b},
		'the run never names a directory it does not read');
	unlike($said, qr{leftover-ci-directory-marker},
		'and nothing inside that directory reaches the run');
};

done_testing;
