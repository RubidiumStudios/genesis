#!/usr/bin/env perl
# Proves T417's second half: under an automated provider the progression
# labels every environment automatic or manual, as its merged
# genesis.pipeline.manual makes it (contract c1).  The manual provider, where
# nothing deploys by itself, refuses that key (D101), and labels none.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

sub progression {
	my ($provider) = @_;
	my $h = make_harness(envs => ['qa', 'prod'], chained => 1, provider => $provider, vault => 0);
	unless ($provider eq 'manual') {
		compilable_pipeline($h);
		write_env_file($h, 'prod', pipeline => {prior_env => 'qa', manual => 'true'});
	}
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-describe');
	is($exit, 0, "the $provider describe succeeds") or diag($err);
	return $out;
}

subtest 'an automated provider labels every environment' => sub {
	my $out = progression('concourse');
	like($out, qr{^  qa  \(automatic\)$}m, 'qa deploys on its branch, so automatic');
	like($out, qr{^    prod  \(manual\)$}m, 'prod is held, so manual');
};

subtest 'the manual provider labels none' => sub {
	my $out = progression('manual');
	like($out, qr{^  qa$}m, 'qa unlabelled, nothing deploying by itself');
	like($out, qr{^    prod$}m, 'and prod');
};

done_testing;
