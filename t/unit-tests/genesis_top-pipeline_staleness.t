#!/usr/bin/env perl
# Proves T52: the staleness query reads the applied commit, a path diff
# over the pipeline-defining paths, and each environment's compiled set
# against its last-read set, and no second copy of it exists.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Top;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

sub staleness_for {
	my ($h) = @_;
	return Genesis::Top->new($h->a)->pipeline_staleness($h->git('a'));
}

# Every publishing commit below moves ops/shared.yml, because git makes no
# commit out of an unchanged tree.  The rows only need a control sha to put
# in the applied record, and no environment inherits that file, so what it
# holds carries no meaning.

subtest 'an applied pipeline that nothing has changed is not stale' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['lab', 'prod'], type => 'bosh');
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);
	fixture_applied($h, control => $control, provider => 'manual');
	fixture_pipeline_record($h, $_, dependencies => []) for qw/lab prod/;
	certify($h, $_, control_commit => $control, dependencies_read => [])
		for qw/lab prod/;

	is_deeply(staleness_for($h), [], 'nothing is stale');

	# With no applied record there is nothing to be stale against, and the
	# awaiting pipeline-apply outcome is a different read.
	my $fresh = make_harness(envs => ['lab'], type => 'bosh');
	commit_on_control($fresh,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);
	is_deeply(staleness_for($fresh), [],
		'and a pipeline that was never applied reports no staleness');
};

subtest 'a changed pipeline-defining path names its environment' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['lab', 'prod'], type => 'bosh');
	my $applied = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);
	fixture_applied($h, control => $applied, provider => 'manual');
	fixture_pipeline_record($h, $_, dependencies => []) for qw/lab prod/;
	certify($h, $_, control_commit => $applied, dependencies_read => [])
		for qw/lab prod/;

	write_env_file($h, 'prod', pipeline => {redeploy_cron => '0 3 * * *'});

	my $changes = staleness_for($h);
	is(scalar(@$changes), 1, 'one environment changed');
	is($changes->[0]{env}, 'prod', 'and it is the one whose file moved');
	is($changes->[0]{reason}, 'configuration-changed',
		'with the reason the caller prints');
};

subtest 'a compiled set that differs from the last-read set is stale' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['lab'], type => 'bosh');
	my $applied = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);
	fixture_applied($h, control => $applied, provider => 'manual');
	fixture_pipeline_record($h, 'lab', dependencies => ['ops/bosh']);
	certify($h, 'lab',
		control_commit     => $applied,
		dependencies_read  => ['ops/bosh', 'shared/vault'],
	);

	my $changes = staleness_for($h);
	is($changes->[0]{env}, 'lab', 'the environment is named');
	is($changes->[0]{reason}, 'dependencies-changed',
		'and the reason says which of the two inputs differed');
};

subtest 'the comparison has one home' => sub {
	plan tests => 2;

	my @composers;
	my @queue = ('lib');
	while (my $dir = shift @queue) {
		opendir(my $dh, $dir) or next;
		for my $entry (sort readdir($dh)) {
			next if $entry eq '.' or $entry eq '..';
			my $path = "$dir/$entry";
			if (-d $path) {
				push @queue, $path;
			} elsif ($path =~ m{\.pm$}) {
				push @composers, $path if slurp($path) =~ m{_pipelines/};
			}
		}
		closedir($dh);
	}

	is_deeply(\@composers, ['lib/Genesis/Top.pm'],
		'the applied record address is composed in one module')
		or diag("a second composition: @composers");
	ok(Genesis::Top->can('pipeline_staleness'),
		'and the comparison is a method its three callers will ask');
};

done_testing;
