#!perl
# Proves T342: a provider answers for its toolchain once.  A Concourse
# provider whose repository declares a minimum fly version is refused by
# a fly that does not meet it, the refusal names both versions, it exits
# 86, and no second check_prereqs stands on any class the command can be
# handed.  The last subtest proves that the caller's provider type wins
# over the type the pipeline block declares, which belongs beside the
# floor because both are about the provider the compile hands back.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

use File::Find;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

sub flatten {
	my ($text) = @_;
	$text //= '';
	$text =~ s/\s+/ /g;
	return $text;
}

# An assertion helper, beside the test that uses it.  It reports every
# file under a directory that defines check_prereqs, so the rows read
# what the tree holds rather than a list somebody wrote down.  The scan
# takes a directory and a file, because the provider base sits at
# lib/Genesis/CI/Provider.pm and the concretes sit in the directory
# beside it.
sub defining_check_prereqs {
	my (@roots) = @_;

	my @files;
	for my $root (@roots) {
		if (-d $root) {
			find(sub {push @files, $File::Find::name if -f && /\.pm$/}, $root);
		} elsif (-f $root) {
			push @files, $root;
		}
	}

	my @found;
	for my $file (sort @files) {
		open my $fh, '<', $file or die "cannot read $file: $!\n";
		while (my $line = <$fh>) {
			next if $line =~ /^\s*#/;
			push @found, $file if $line =~ /^\s*sub\s+check_prereqs\b/;
		}
		close $fh;
	}
	return @found;
}

subtest 'a fly below the declared floor is refused' => sub {
	# Three rows, and one more for the run's own restoration assertion,
	# which run_genesis makes unless a row turns it off.
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	compilable_pipeline($h);
	$h->set_repo_config('pipeline.provider.min_fly_version', '7.9.0');
	fixture_fly($h, version => '7.4.0');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = flatten($err);

	# The three assertions that separate the arrangements.  The
	# compiler-side check answered yes for any fly that was present, so
	# under the old arrangement this run carries past the check and
	# exits for reasons of its own, with neither version named anywhere.
	is($exit, 86, 'the prerequisites refusal exits 86');
	like($said, qr/requires fly >= 7\.9\.0/, 'it names the version it requires');
	like($said, qr/found 7\.4\.0/, 'and the version it found');
};

subtest 'a fly that meets the floor is let through' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	compilable_pipeline($h);
	$h->set_repo_config('pipeline.provider.min_fly_version', '7.9.0');
	fixture_fly($h, version => '7.11.2');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	isnt($exit, 86, 'the prerequisites check does not refuse');
	unlike(flatten($err), qr/requires fly/,
		'and nothing is said about a fly version');
};

subtest 'an absent fly is still refused, by the same check' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	compilable_pipeline($h);
	fixture_fly($h, absent => 1);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 86, 'the refusal exits 86');
	like(flatten($err), qr/requires the .?fly.? CLI but it was not found/,
		'and it is the provider-side message');
};

subtest 'a fly whose version cannot be read is refused' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	# A floor nothing can be compared against is a floor that is not
	# enforced, and a check that carried on regardless enforced nothing
	# while reporting nothing.
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	compilable_pipeline($h);
	$h->set_repo_config('pipeline.provider.min_fly_version', '7.9.0');
	fixture_fly($h, version => 'fly (development)');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 86, 'the prerequisites refusal exits 86');
	like(flatten($err), qr/could not read a fly version from/,
		'and the refusal names what it read instead of a version');
};

subtest 'a floor written with a leading v is the same floor' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	# v7.9.0 is how a Concourse release names itself, so a repository
	# that copies the name into the key means the floor it says it
	# means.  Split on the dots alone it read as major zero, and every
	# fly on earth cleared it.
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	compilable_pipeline($h);
	$h->set_repo_config('pipeline.provider.min_fly_version', 'v7.9.0');
	fixture_fly($h, version => '7.4.0');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 86, 'the prerequisites refusal exits 86');

	# The floor is echoed as the repository wrote it, v and all, so the
	# pattern names that rendering exactly.  Admitting an optional v
	# would pass whether the message kept it or dropped it, and the
	# stripping this row is about would go unsaid either way.
	like(flatten($err), qr/requires fly >= v7\.9\.0 but found 7\.4\.0/,
		'and it names the floor the repository declared, as written');
};

subtest 'a release candidate floor is read the way Genesis reads versions' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	plan tests => 4;

	# 7.9.0 is newer than 7.9.0-rc.1, so this run carries past the
	# check.  A comparison that split on the dots had nothing to say
	# about the suffix and warned about a non-numeric string on its way
	# to saying it, which is the warning the third row reads for.
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	compilable_pipeline($h);
	$h->set_repo_config('pipeline.provider.min_fly_version', '7.9.0-rc.1');
	fixture_fly($h, version => '7.9.0');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = flatten($err);

	isnt($exit, 86, 'the prerequisites check does not refuse');
	unlike($said, qr/requires fly/, 'and nothing is said about a fly version');
	unlike($said, qr/isn't numeric/, 'and no comparison warns on its way past');
};

# The compiler family the second row below sweeps.  A root that is not on
# disk contributes nothing, so an empty answer from a family that moved
# reads exactly like an empty answer from one that is there, which is why
# the row asserts the roots before it trusts the sweep.
my @COMPILER_ROOTS = (
	'lib/Genesis/CI/ProviderCompiler.pm',
	'lib/Genesis/CI/ProviderCompiler',
);

subtest 'no second check_prereqs stands on any class the command can be handed' => sub {
	plan tests => 3;

	is_deeply([grep {!-e} @COMPILER_ROOTS], [],
		'both roots the compiler sweep reads are on disk');

	# The provider family keeps two, which are the base's default at
	# lib/Genesis/CI/Provider.pm and the Concourse override in the
	# directory beside it, so the scan reads both the file and the
	# directory.  Any third is the divergence coming back.
	is_deeply([defining_check_prereqs('lib/Genesis/CI/Provider.pm',
	                                  'lib/Genesis/CI/Provider')],
		['lib/Genesis/CI/Provider.pm', 'lib/Genesis/CI/Provider/Concourse.pm'],
		'the base declares the default and Concourse overrides it');

	is_deeply([defining_check_prereqs(@COMPILER_ROOTS)],
		[],
		'and no compiler class answers the question at all');
};

subtest 'the provider the caller asked for is the provider it gets' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	# pipeline-diff names Concourse itself, whatever the block says, so a
	# repository whose block declares github-actions
	# tells the two apart: github-actions has no compiling class, and a
	# compile that read the type off the block would be refused by the
	# registry and exit CONFIG before any fly was reached.
	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	load_with($h, automated_config('github-actions'));
	compilable_pipeline($h);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-diff');
	my $said = flatten("$out\n$err");

	unlike($said, qr/has no compiler for it yet/,
		'the block\'s own type is not the one the compile resolved');
	like($said, qr/does not exist on target/,
		'and the run reached the fly the Concourse half calls');
};

done_testing;
