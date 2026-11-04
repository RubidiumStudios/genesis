#!/usr/bin/env perl
# Proves T468 (D138; contract b4): a job's build log is public only where
# pipeline.provider.public says so.  By default no job is public; with the key
# true every job is, the deploys, the redeploys and propagate alike.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Harness::Contract;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $ENV_NAME = $Harness::Contract::ENV_NAME;

sub jobs_named {
	my ($p) = @_;
	my %jobs = map {($_->{name} => $_)} @{$p->{jobs} || []};
	return \%jobs;
}

subtest 'by default no job is public' => sub {
	my ($p, $why) = dry_pipeline(contract_harness());
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	my $jobs = jobs_named($p);
	ok($jobs->{$_}, "the pipeline has $_") for ("deploy-$ENV_NAME", "redeploy-$ENV_NAME", 'propagate');
	ok(!$jobs->{$_}{public}, "b4: $_ is not public") for sort keys %$jobs;
};

subtest 'public: true makes every job public' => sub {
	my ($p, $why) = dry_pipeline(contract_harness(config => {'pipeline.provider.public' => 'true'}));
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	my $jobs = jobs_named($p);
	ok(keys %$jobs, 'the pipeline has jobs');
	ok($jobs->{$_}{public}, "b4: $_ is public") for sort keys %$jobs;
};

done_testing;
