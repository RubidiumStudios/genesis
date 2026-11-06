#!/usr/bin/env perl
# Proves T476 and T478's compile half (D146, D148; contract a16, c10) through
# the dry apply: two Classic environments on one director, each naming it in
# genesis.bosh_env, share that director's checks, read with its published
# credentials, and one notify job hears them; no deploy or redeploy does.
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

my $SLACK = {'pipeline.notifications.slack.webhook' => 'ci/slack:webhook'};

# Written through the pipeline option, which nests the tag one level deeper
# than a pipeline block handed in under genesis can.
sub on_mgmt {
	my (%o) = @_;
	my $h = contract_harness(envs => ['qa', 'prod'], config => $SLACK);
	for my $e (qw/qa prod/) {
		write_env_file($h, $e, genesis => {bosh_env => 'mgmt'}, pipeline => {
			($o{track}{$e} ? (track_bosh_configs => $o{track}{$e}) : ()),
			($o{tag}{$e}   ? (provider => {tag => $o{tag}{$e}})    : ()),
		});
	}
	return $h;
}

sub config_resources {
	my ($p) = @_;
	return sort map {$_->{name}} grep {$_->{type} eq 'bosh-config'} @{$p->{resources} || []};
}

my %TRACK = (qa => ['cloud', 'runtime'], prod => ['cloud', 'runtime']);

subtest "a director's configs notify" => sub {
	my $h = on_mgmt(track => \%TRACK);
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	is_deeply([config_resources($p)], ['mgmt-bosh-cloud-config', 'mgmt-bosh-runtime-config'],
		'a16: one check per type on the director, and none per environment');
	for my $type (qw/cloud runtime/) {
		my $src = pipeline_resource($p, "mgmt-bosh-$type-config")->{source};
		is($src->{config}, $type, "the $type check reads its type");
		ok($src->{all}, 'with all: true');
	}

	my $job = pipeline_job($p, 'notify-mgmt-bosh-configs');
	ok($job, 'c10: notify-mgmt-bosh-configs is emitted') or return;
	my @gets = grep {exists $_->{get}} plan_steps($job);
	is_deeply([sort map {$_->{get}} @gets], ['mgmt-bosh-cloud-config', 'mgmt-bosh-runtime-config'],
		'getting both checks');
	ok((!grep {!$_->{trigger}} @gets), 'with trigger: true');
	my ($put) = grep {($_->{put} // '') eq 'slack'} plan_steps($job);
	ok($put, 'and putting one Slack message') or return;
	like($put->{params}{text}, qr/mgmt/, 'naming the director');
	like($put->{params}{text}, qr/\bprod\b.*\bqa\b/, 'and both environments');

	for my $name (grep {/^(?:re)?deploy-/} map {$_->{name}} @{$p->{jobs}}) {
		my @got = grep {($_->{get} // '') =~ /-bosh-\w+-config$/} plan_steps(pipeline_job($p, $name));
		ok(!@got, "c10: $name gets no check");
	}
};

subtest "the check reads the director with its published credentials" => sub {
	my $h = on_mgmt(track => \%TRACK);
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	# all is a boolean the YAML reader may bless, so it is read apart.
	my %src = %{pipeline_resource($p, 'mgmt-bosh-cloud-config')->{source}};
	ok(delete $src{all}, 'all: true');
	is_deeply(\%src, {
		target        => '((bosh/mgmt.url))',
		ca_cert       => '((bosh/mgmt.ca_cert))',
		client        => '((bosh/mgmt.client))',
		client_secret => '((bosh/mgmt.client_secret))',
		config        => 'cloud',
	}, 'D148: the four references under bosh/mgmt, and nothing else');
};

subtest 'one shared tag is carried' => sub {
	my $h = on_mgmt(track => \%TRACK, tag => {qa => 'net-a', prod => 'net-a'});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	is_deeply(pipeline_resource($p, $_)->{tags}, ['net-a'], "b5: $_ carries the tag")
		for config_resources($p);
};

subtest 'environments disagreeing on the tag are refused' => sub {
	my $h = on_mgmt(track => \%TRACK, tag => {qa => 'net-a', prod => 'net-b'});
	my ($out, $err, $exit) = run_genesis($h, {dir => $Harness::Contract::ROOT},
		'pipeline-apply', '--dry-run', '--skip-vault');
	isnt($exit, 0, 'the compile refuses');
	like("$out$err", qr/mgmt.*prod.*net-b.*qa.*net-a/s, 'naming the director and each environment');
};

subtest 'an environment tracking nothing makes no check' => sub {
	my $h = on_mgmt(track => {qa => ['cloud']});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	is_deeply([config_resources($p)], ['mgmt-bosh-cloud-config'], 'the one check is qa\'s');
	my ($put) = grep {($_->{put} // '') eq 'slack'}
		plan_steps(pipeline_job($p, 'notify-mgmt-bosh-configs'));
	unlike($put->{params}{text}, qr/\bprod\b/, 'and the message leaves prod out');

	$h = on_mgmt();
	($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	is_deeply([config_resources($p)], [], 'with nothing tracked there is no check');
	ok(!pipeline_job($p, 'notify-mgmt-bosh-configs'), 'and no job');
};

done_testing;
