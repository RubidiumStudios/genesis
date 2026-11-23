#!/usr/bin/env perl
# Proves T513 (D179): the all group.  With pipeline.provider.show_all_group
# set, the Concourse pipeline carries an all group listing every job, after
# every other group.  It is off unless asked for, so a pipeline applied before
# the key existed compiles as it did.
#
# Concourse shows every job at once only where a pipeline has no groups, and
# this pipeline always has some, so without the group no view shows the whole
# pipeline.  The v2 pipeline carried one.
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

my %SLACK = (
	'pipeline.notifications.slack.webhook' => 'ci/slack:webhook',
	'pipeline.notifications.slack.channel' => '#deploys',
);

sub groups     { @{$_[0]->{groups} || []} }
sub group_names { map {$_->{name}} groups($_[0]) }
sub job_names  { sort map {$_->{name}} @{$_[0]->{jobs} || []} }

subtest 'by default there is no all group' => sub {
	my $h = contract_harness();
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	ok(!grep({$_ eq 'all'} group_names($p)), 'no group is named all');
	is((group_names($p))[-1], 'propagation', 'and propagation is the last, as it was');
};

subtest 'show_all_group lists every job in a last group' => sub {
	my $without = contract_harness();
	my ($plain) = dry_pipeline($without);

	my $h = contract_harness(config => {'pipeline.provider.show_all_group' => 'true'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my @groups = groups($p);
	is($groups[-1]{name}, 'all', 'the last group is all');
	is($groups[-2]{name}, 'propagation', 'after propagation');
	is_deeply($groups[-1]{jobs}, [job_names($p)], 'holding every job the pipeline has, each once, sorted');
	ok(scalar(grep {$_ eq 'propagate'} @{$groups[-1]{jobs}}), 'propagate among them');
	is_deeply([@groups[0 .. $#groups - 1]], [groups($plain)],
		'and every other group is as it is without the key');
};

subtest 'it holds every job where other groups are split out' => sub {
	my $h = contract_harness(
		config => {%SLACK,
			'pipeline.provider.show_all_group' => 'true',
			'pipeline.redeploy.style'          => 'grouped',
			'pipeline.notifications.style'     => 'grouped'},
		pipeline => {manual => 'true'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my @groups = groups($p);
	is($groups[-1]{name}, 'all', 'all is still the last group');
	is_deeply($groups[-1]{jobs}, [job_names($p)], 'and still holds every job');
	ok(scalar(grep {/^notify-/} @{$groups[-1]{jobs}}), 'the notify job among them');
	ok(scalar(grep {/^redeploy-/} @{$groups[-1]{jobs}}), 'and the redeploy');
	is(scalar(grep {$_ eq 'all'} group_names($p)), 1, 'one group is named all');
};

subtest 'a pipeline whose own group is named all is refused' => sub {
	my $h = contract_harness(config => {
		'pipeline.provider.show_all_group' => 'true',
		'pipeline.name'                    => 'all'});
	my ($p, $why) = dry_pipeline($h);
	ok(!$p, 'the dry apply refuses') or return;
	like($why, qr/^exit 78\b/, 'at CONFIG');
	like($why, qr/pipeline\.provider\.show_all_group/, 'naming the key');

	$h = contract_harness(config => {'pipeline.name' => 'all'});
	($p, $why) = dry_pipeline($h);
	ok($p, 'without the key a pipeline named all compiles') or diag($why);
};

subtest 'a value that is not a boolean is refused at load' => sub {
	my $h = contract_harness(config => {'pipeline.provider.show_all_group' => 'sometimes'});
	my ($p, $why) = dry_pipeline($h);
	ok(!$p, 'the dry apply refuses') or return;
	like($why, qr/^exit 78\b/, 'at CONFIG');
	like($why, qr/show_all_group/, 'naming the key');
};

done_testing;
