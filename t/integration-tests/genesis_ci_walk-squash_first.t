#!/usr/bin/env perl
# Proves T432 (D125): the first delivery to a branch with no marker is one
# squash at the control tip, which reads no set but the tip's, and a branch
# that carries a marker is walked from it one commit at a time as before.
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
	my ($version, $leaf) = @_;
	return "---\nkit:\n  name:     compiled\n  version:  $version\n  features: []\n".
	       "genesis:\n  env: qa\n".(defined $leaf ? "leaf: $leaf\n" : '');
}

sub commits_on {
	my ($h, $ref) = @_;
	my ($log) = run({dir => $h->a}, 'git', 'log', '--format=%H', $ref);
	return grep {/\S/} split /\n/, $log // '';
}

subtest 'an unseeded branch takes one squash at the tip' => sub {
	# Nine rows, and one more for each of the two runs' restoration
	# assertions.
	plan tests => 11;

	# qa is introduced on the dev kit, readable; then moved to a compiled kit
	# a commit before its archive arrives, so a walk that read the history
	# would meet a commit it cannot read; then tuned once more.
	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	fixture_vault($h);
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	fixture_pipeline_record($h, 'qa');
	init_branch($h, 'qa');
	my ($e) = grep {/\S/} split /\n/, scalar run({dir => $h->a},
		'git', 'log', '--diff-filter=A', '--format=%H', '--', 'qa.yml');

	commit_on_control($h, files => {'qa.yml' => env_file('0.0.2')},
		message => 'move qa to compiled 0.0.2');
	install_compiled_kit($h, "$kits/compiled-0.0.2.tar.gz");
	my $tip = commit_on_control($h, files => {'qa.yml' => env_file('0.0.2', 'tuned')},
		message => 'tune qa', push => 1);
	refresh($h, 'a');
	# E itself and every commit after it; E may be the root, so no E^.
	my ($n) = run({dir => $h->a}, 'git', 'rev-list', '--count', '--first-parent', "$e..$tip");
	$n = 1 + ($n // 0);

	my $ref = 'refs/remotes/origin/'.$h->slug('qa');
	my ($dry) = unfolded(run_genesis($h, 'propagate', '--dry-run'));
	like($dry, qr{control\@\Q@{[substr($tip, 0, 7)]}\E tune qa\s+would deliver},
		'the preview would deliver the tip');
	like($dry, qr{squashing $n commits}, 'and names the commits it squashes');
	is(scalar(commits_on($h, $ref)), 1, 'and delivers nothing');

	my ($out, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the run succeeded');
	unlike($said, qr/could not be read/, 'no set was read but the tip\'s');
	is(scalar(commits_on($h, $ref)), 2, 'the init commit and one delivery');
	is(harness_marker($h, $h->slug('qa')), $tip, 'whose marker names the tip');

	my @files = @{tree_of($h->a, $ref)};
	ok(!(grep {$_ eq 'init'} @files), 'it deleted init');
	ok((grep {$_ eq '.genesis/kits/compiled-0.0.2.tar.gz'} @files)
		&& (grep {$_ eq 'qa.yml'} @files),
		'and mirrors the set as control holds it');
};

subtest 'a branch with a marker is walked one commit at a time' => sub {
	# Two rows, and one more for each of the two runs' restoration
	# assertions.
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	fixture_vault($h);
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	fixture_pipeline_record($h, 'qa');
	init_branch($h, 'qa');
	run_genesis($h, {answers => ['y']}, 'propagate');
	refresh($h, 'a');
	my $ref    = 'refs/remotes/origin/'.$h->slug('qa');
	my $before = scalar(commits_on($h, $ref));

	# The archive's own commit routes nowhere, qa naming the dev kit then.
	install_compiled_kit($h, "$kits/compiled-0.0.2.tar.gz");
	commit_on_control($h, files => {'qa.yml' => env_file('0.0.2')},
		message => 'move qa to compiled 0.0.2');
	commit_on_control($h, files => {'qa.yml' => env_file('0.0.2', 'tuned')},
		message => 'tune qa', push => 1);
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, 0, 'the run succeeded');
	is(scalar(commits_on($h, $ref)), $before + 2,
		'one delivery per commit that routes, no squash');
};

done_testing;
