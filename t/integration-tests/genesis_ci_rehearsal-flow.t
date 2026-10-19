#!/usr/bin/env perl
# Proves T416: a change flows through the pipeline the dry apply compiles.
# Harness::Rehearsal stands in for Concourse's scheduler: it runs each job
# whose triggering input has a new version, the tasks running their own
# commands against the harness's BOSH and vault, until nothing triggers, with
# the locker's keyed pools simulated.  The root is doomsday-typed, with the
# real genesis embedded.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Harness::Rehearsal;

use Test::More;

use Genesis qw/load_yaml/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# A Concourse repository at rest, its environments delivered and certified,
# and the pipeline its dry apply prints, recorded as applied.
sub fixture {
	my (%o) = @_;
	my $h = ready_harness(envs => $o{envs}, chained => $o{chained}, provider => 'concourse',
		type => 'doomsday', embed => 'real', bosh => {envs => $o{envs}});
	compilable_pipeline($h);
	push_from($h, 'a', $h->control);
	my ($out, $err, $rc) = run_genesis($h, {restore => 0}, 'pipeline-apply', '--dry-run', '--skip-vault');
	BAIL_OUT("the dry apply failed: $err") if $rc;
	fixture_applied($h, control => remote_sha($h, $h->control));
	return ($h, load_yaml($out));
}

# A control commit, published: to one environment's file, or to a site file
# every environment beneath it inherits.
sub change {
	my ($h, $env, %o) = @_;
	write_env_file($h, $env, params => {rehearsed => 'yes'}, ($o{site} ? (site => $o{site}) : ()));
	push_from($h, 'a', $h->control);
	return remote_sha($h, $h->control);
}

sub said {
	my ($r) = @_;
	join("\n", map {my $c = $_; map {"$c->{job} $_->{dir}\$ @{$_->{argv}} => $_->{rc}\n$_->{err}"} @{$c->{commands}}} $r->runs);
}

subtest 'one environment: propagate, deploy, rest' => sub {
	my ($h, $p) = fixture(envs => ['qa']);
	my $r = rehearsal($h, $p);
	my $sha = change($h, 'qa');
	$r->settle;

	is_deeply([$r->jobs_run], ['propagate', 'deploy-qa'], 'propagate runs, then deploy-qa, then nothing')
		or diag(said($r));
	my ($prop, $dep) = $r->runs;
	is_deeply($prop->{commands}[0]{argv}, ['.genesis/bin/genesis', 'propagate'], 'propagate ran genesis propagate');
	is_deeply($dep->{commands}[0]{argv}, ['.genesis/bin/genesis', 'qa', 'deploy', '-SFy'], 'the deploy ran qa deploy -SFy');
	is($dep->{outcome}, 'success', 'and succeeded') or diag(said($r));

	like(blob_at($h->{r}, $h->slug('qa'), 'qa.yml') // '', qr/rehearsed: yes/, "qa's branch carries the change");
	is((newest_record($h, $h->env_path('qa').'/deployments') || {})->{git}{control_commit}, $sha,
		"qa's exodus record names the control commit");
	is($r->version('qa-doomsday_ran'), 1, 'the deploy put its _ran once');
	is_deeply($r->held, {}, 'every pool is free at rest');
};

subtest 'chained us-qa to us-prod: each deploy wakes the next propagation' => sub {
	# The change is to us.yml, which both inherit; a change to one
	# environment's own file is due to that environment alone.
	my ($h, $p) = fixture(envs => ['us-qa', 'us-prod'], chained => 1);
	my $r = rehearsal($h, $p);
	my $sha = change($h, 'us-qa', site => 'us');
	$r->settle;

	is_deeply([$r->jobs_run], ['propagate', 'deploy-us-qa', 'propagate', 'deploy-us-prod'],
		"propagate, us-qa's deploy, propagate on its _ran, us-prod's deploy, rest") or diag(said($r));
	is((newest_record($h, $h->env_path('us-prod').'/deployments') || {})->{git}{control_commit}, $sha,
		"us-prod's exodus record names the control commit");
	is_deeply($r->held, {}, 'every pool is free at rest');
};

subtest "contention: a deploy waits on its director's held pool" => sub {
	my ($h, $p) = fixture(envs => ['qa']);
	my $r = rehearsal($h, $p);
	$r->hold('qa-bosh', 'i-need-to-deploy-myself', 'qa-bosh');
	change($h, 'qa');
	$r->settle;

	is_deeply([$r->jobs_run], ['propagate'], 'propagate runs, and the deploy does not') or diag(said($r));
	my ($parked) = grep {$_->{outcome} eq 'parked'} $r->runs;
	is($parked && $parked->{parked_on}, 'qa-bosh', "deploy-qa parked on its director's pool");
	is($parked && scalar(@{$parked->{commands}}), 0, 'before its task ran');

	$r->release('qa-bosh', 'i-need-to-deploy-myself', 'qa-bosh')->settle;
	is_deeply([$r->jobs_run], ['propagate', 'deploy-qa'], 'once the pool is released, the deploy runs')
		or diag(said($r));
	is_deeply($r->held, {}, 'and every pool is free at rest');
};

done_testing;
