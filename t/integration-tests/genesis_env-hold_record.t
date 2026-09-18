#!/usr/bin/env perl
# Proves T305, that the hold record's `at` is a value in EXODUS_TIME_FORMAT
# while no component of its path is a timestamp, and T306, that the record at
# the sibling path survives the rewrite a successful deploy makes under
# <exodus_base>.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Env;
use Genesis::Top;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'set_hold writes the four fields and nothing else' => sub {
	# Seven rows and no run, so nothing here asserts a restoration.
	plan tests => 7;

	my $h = held_prod();

	my $top  = Genesis::Top->new($h->a);
	my $env  = Genesis::Env->bare('prod', $top)->with_vault;
	my $path = $env->set_hold(reason => 'waiting on the capacity report');

	is($path, $h->env_path('prod').'/hold',
		'the record sits at <exodus_base>/hold, beside the deployments');

	have_secret "$path:reason";
	have_secret "$path:user";
	have_secret "$path:hostname";
	have_secret "$path:at";

	is(secret("$path:reason"), 'waiting on the capacity report',
		'the reason is the string it was given');

	like(secret("$path:at"),
		qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [-+]\d{4}$/,
		'the time is a value in EXODUS_TIME_FORMAT');
};

subtest 'the record round-trips through a fresh environment' => sub {
	# Nine rows and no run.  Every read is made through an environment
	# built after the write, so what comes back is what vault holds and
	# not what the writing object happens to remember.
	plan tests => 9;

	my $h = held_prod();

	my $top = Genesis::Top->new($h->a);
	Genesis::Env->bare('prod', $top)->with_vault->set_hold(
		reason   => 'the first hold',
		user     => 'operator',
		hostname => 'bastion.example.com',
		at       => '2026-09-18 10:04:12 -0400',
	);

	my $record = Genesis::Env->bare('prod', Genesis::Top->new($h->a))
		->with_vault->hold_record;
	is_deeply([sort keys %$record], [qw(at hostname reason user)],
		'the record carries the four fields and no fifth');
	is($record->{reason},   'the first hold',           'the reason came back');
	is($record->{user},     'operator',                 'the user came back');
	is($record->{hostname}, 'bastion.example.com',      'the hostname came back');
	is($record->{at},       '2026-09-18 10:04:12 -0400','the time came back');

	Genesis::Env->bare('prod', Genesis::Top->new($h->a))->with_vault
		->set_hold(reason => 'the second hold');

	my $replaced = Genesis::Env->bare('prod', Genesis::Top->new($h->a))
		->with_vault->hold_record;
	is($replaced->{reason}, 'the second hold',
		'the later hold replaced the earlier one');
	is_deeply([sort keys %$replaced], [qw(at hostname reason user)],
		'and left none of the first hold behind');

	my $fresh = Genesis::Env->bare('prod', Genesis::Top->new($h->a))->with_vault;
	ok($fresh->clear_hold, 'the release reports that a hold stood');
	is(Genesis::Env->bare('prod', Genesis::Top->new($h->a))
		->with_vault->hold_record, undef,
		'and the reader answers undef afterwards');
};

subtest 'clear_hold deletes the path and keeps no fields' => sub {
	# Three rows and no run.
	plan tests => 3;

	my $h = held_prod();

	my $top  = Genesis::Top->new($h->a);
	my $env  = Genesis::Env->bare('prod', $top)->with_vault;
	my $path = $env->set_hold(reason => 'waiting on the capacity report');

	ok($env->clear_hold, 'the release reports that a hold stood');
	no_secret $path;
	ok(!$env->clear_hold, 'a second release reports that none stood');
};

subtest 'the hold survives the deploy rewrite of the deployment data' => sub {
	# Seven rows, two of which are restorations.  The secrets run asserts its
	# own in run_genesis's words, and the deploy is given restore => 0 so
	# this row asserts the deploy's in its own.
	plan tests => 7;

	# The deploy is the real one, taken to success, because the rewrite this
	# row is about is the one update_deployment_exodus makes and only a
	# successful deploy makes it.  Which means the environment has to be one
	# a deploy can finish: a kit that merges, the base domain that kit asks
	# for, the secrets it declares, and a director whose address something is
	# listening on, since the director's status check dials the host before
	# it runs a single BOSH command.  The pipeline is off, because a
	# pipeline-managed deploy first switches to the environment's own branch
	# and the branch it looks for is not the slug the harness stands up.
	my $h = held_prod(kit => 'omega-v2.7.0', pipeline => 0);
	write_env_file($h, 'prod', params => {base_domain => 'example.com'});
	my $director = fake_bosh_director('prod', 25555);
	fixture_director($h, 'prod', url => 'https://127.0.0.1:25555');
	fake_bosh();

	my $top  = Genesis::Top->new($h->a);
	my $env  = Genesis::Env->bare('prod', $top)->with_vault;
	my $path = $env->set_hold(reason => 'waiting on the capacity report');

	my (undef, undef, $secrets_exit) = run_genesis($h, 'prod', 'add-secrets');
	is($secrets_exit, 0, 'the secrets the kit declares were generated');

	my $w = snapshot_w($h);
	my (undef, $err, $exit) = run_genesis($h, {restore => 0},
		'prod', 'deploy', '-y');
	assert_w_restored($w, 'the deploy restored working state');
	is($exit, 0, 'the deploy succeeded')
		or diag($err);
	like($err, qr/updating exodus data for this deployment/,
		'and it rewrote the deployment data under the exodus base');

	have_secret "$path:reason";
	is(secret("$path:reason"), 'waiting on the capacity report',
		'the sibling record survived the rewrite of the deployment data');
};

done_testing;
