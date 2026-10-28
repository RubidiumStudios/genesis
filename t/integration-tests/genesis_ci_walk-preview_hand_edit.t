#!/usr/bin/env perl
# Proves T434: the preview names an overwritten hand edit only where there is
# one.  A preview commits no marker, so each previewed delivery after the
# first compares against the control commit the delivery before it would
# have marked, as the writing run compares against the marker it committed.
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

# qa delivered to once, then two commits each touching qa.yml, the second
# also carrying a non-triggering .genesis/config change.
sub two_due {
	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	fixture_pipeline_record($h, 'qa');
	init_branch($h, 'qa');
	run_genesis($h, {answers => ['y']}, 'propagate');
	refresh($h, 'a');

	my $qa = helper::get_file($h->a . '/qa.yml');
	commit_on_control($h, files => {'qa.yml' => "$qa\nfirst: 1\n"},
		message => 'first change');
	my $config = helper::get_file($h->a . '/.genesis/config');
	commit_on_control($h, files => {
		'qa.yml'          => "$qa\nfirst: 1\nsecond: 2\n",
		'.genesis/config' => "$config\n# carried\n",
	}, message => 'second change, carrying config', push => 1);
	refresh($h, 'a');
	return $h;
}

subtest 'a preview over an unedited branch names no hand edit' => sub {
	# One row, and one more for each of the two runs' restoration
	# assertions.
	plan tests => 3;

	my $h = two_due();
	my ($said) = unfolded(run_genesis($h, 'propagate', '--dry-run'));
	unlike($said, qr/overwrote-hand-edit/, 'no hand edit is named');
};

subtest 'a preview over a hand-edited branch names it once' => sub {
	# Two rows, and one more for each of the two runs' restoration
	# assertions.
	plan tests => 4;

	my $h = two_due();
	my $branch = $h->slug('qa');
	run({dir => $h->a}, 'git', 'checkout', '-q', '-B', $branch, "origin/$branch");
	helper::put_file($h->a . '/qa.yml', "---\n# edited by hand\n");
	run({dir => $h->a}, 'git', 'commit', '-qam', 'a hand edit');
	run({dir => $h->a}, 'git', 'push', '-q', 'origin', $branch);
	stand_on($h, $h->control);
	refresh($h, 'a');

	my ($said) = unfolded(run_genesis($h, 'propagate', '--dry-run'));
	my @named = $said =~ /overwrote-hand-edit (\S+)/g;
	is_deeply(\@named, ['qa.yml'], 'the edited file is named, once');
	like($said, qr/"?first change"?.*overwrote-hand-edit qa\.yml.*"?second change/s,
		'on the first commit that delivers it');
};

done_testing;
