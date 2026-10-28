#!/usr/bin/env perl
# Proves T431 (D61, noted 2026-10-28): a commit split from its fix is never a
# blocker.  A commit whose set cannot be read, its environment naming a kit
# the commit does not yet carry, rides with the next commit that routes, and
# only a newest due commit that cannot be read fails the environment.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $kits = 't/repos/compiled-kit-test/.genesis/kits';

sub env_file {
	my ($version) = @_;
	return "---\nkit:\n  name:     compiled\n  version:  $version\n  features: []\n".
	       "genesis:\n  env: qa\n";
}

# A repository whose qa names compiled/0.0.1, carried, with qa/bosh already
# delivered to, since a first delivery is a squash that reads no history
# (D125); then the commit that bumps qa to compiled/0.0.2 without its archive.
sub broken_bump {
	# A dev kit as well, so the commit that introduced qa.yml, on the dev
	# kit, is readable and the bump is the only commit that is not.
	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	fixture_vault($h);
	install_compiled_kit($h, "$kits/compiled-0.0.1.tar.gz");
	commit_on_control($h, files => {'qa.yml' => env_file('0.0.1')},
		message => 'qa on compiled 0.0.1', push => 1);
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	fixture_pipeline_record($h, 'qa');
	init_branch($h, 'qa');
	run_genesis($h, {answers => ['y']}, 'propagate');
	refresh($h, 'a');

	my $broken = commit_on_control($h, files => {'qa.yml' => env_file('0.0.2')},
		message => 'bump qa to compiled 0.0.2', push => 1);
	return ($h, $broken);
}

subtest 'a commit whose fix follows it rides with the fix' => sub {
	# Five rows, and one more for each of the two runs' restoration
	# assertions, the seeding run's included.
	plan tests => 7;

	my ($h, $broken) = broken_bump();
	install_compiled_kit($h, "$kits/compiled-0.0.2.tar.gz");
	push_from($h, 'a', $h->control);
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the run succeeded');
	like($said, qr{\Q@{[substr($broken, 0, 7)]}\E.*could not be read}i,
		'the report names the commit whose set could not be read');

	my $ref   = 'refs/remotes/origin/'.$h->slug('qa');
	my @files = @{tree_of($h->a, $ref)};
	ok((grep {$_ eq '.genesis/kits/compiled-0.0.2.tar.gz'} @files),
		'the delivery carries the archive the fix added');
	my ($qa) = run({dir => $h->a}, 'git', 'show', "$ref:qa.yml");
	like($qa, qr/version:\s+0\.0\.2/, 'and the bumped environment file');
	is(harness_marker($h, $h->slug('qa')), $h->git('a')->sha($h->control),
		'the branch ends at the newest due commit');
};

subtest 'a newest due commit that cannot be read still fails' => sub {
	# Three rows, and one more for each of the two runs' restoration
	# assertions, the seeding run's included.
	plan tests => 5;

	my ($h, $broken) = broken_bump();
	refresh($h, 'a');
	my $ref    = 'refs/remotes/origin/'.$h->slug('qa');
	my ($tip)  = run({dir => $h->a}, 'git', 'rev-parse', $ref);

	my ($out, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($out, $err);
	# The environment cannot be loaded at the tip either, so it fails at its
	# load, before any set is read; what the row holds is that it fails.
	isnt($exit, 0, 'the run does not succeed');
	like($said, qr{\bqa: failed\b}, 'the environment fails');
	refresh($h, 'a');
	my ($now) = run({dir => $h->a}, 'git', 'rev-parse', $ref);
	is($now, $tip, 'and nothing was delivered');
};

done_testing;
