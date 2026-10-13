#!/usr/bin/env perl
# Proves T362: pipeline-hold and pipeline-release, in both their environment
# and deployment-root forms, refuse a pipeline that is not enabled at CONFIG,
# naming pipeline.enabled, and none of them writes or deletes a hold record
# (D64, noted 2026-10-13).  A hold only stops a propagation, and a pipeline
# that is not enabled has none to stop.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# A one-environment prod tree whose pipeline is off and was never applied,
# which is the state the disowned refusal does not cover.
sub disabled_prod {
	return held_prod(kit => 'omega-v2.7.0', pipeline => 0, applied => 0);
}

for my $form (['prod'], []) {
	my $how = @$form ? 'genesis prod pipeline-hold' : 'genesis pipeline-hold';

	subtest "$how refuses a pipeline that is not enabled" => sub {
		my $h    = disabled_prod();
		my $path = $h->env_path('prod').'/hold';

		my ($out, $err, $exit) = run_genesis($h, @$form, 'pipeline-hold',
			'waiting on the capacity report');
		my $said = unfolded($out, $err);

		is($exit, CONFIG, 'it is refused at CONFIG') or diag($said);
		like($said, qr/pipeline\.enabled/, 'naming the key');
		like($said, qr/no pipeline to hold/, 'and saying there is nothing to hold');
		no_secret $path;
	};
}

for my $form (['prod'], []) {
	my $how = @$form ? 'genesis prod pipeline-release' : 'genesis pipeline-release';

	subtest "$how refuses a pipeline that is not enabled" => sub {
		my $h    = disabled_prod();
		my $path = $h->env_path('prod').'/hold';
		$h->fixture_hold('prod', reason => 'set while the pipeline was on');

		my ($out, $err, $exit) = run_genesis($h, @$form, 'pipeline-release');
		my $said = unfolded($out, $err);

		is($exit, CONFIG, 'it is refused at CONFIG') or diag($said);
		like($said, qr/pipeline\.enabled/, 'naming the key');
		like($said, qr/no pipeline to release a hold on/,
			'and saying there is nothing to release');
		is(secret("$path:reason"), 'set while the pipeline was on',
			'and the record already standing is left in place');
	};
}

done_testing;
