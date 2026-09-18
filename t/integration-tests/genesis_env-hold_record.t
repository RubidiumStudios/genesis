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
	# Eight rows and no run, so nothing here asserts a restoration.
	plan tests => 8;

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

	# The key set is read raw rather than through hold_record, because that
	# reader builds a literal four-key hashref and so answers the same four
	# names whatever the vault holds.  This row is the one that can see a
	# fifth key, and it is the row the subtest's own title claims.
	is_deeply([sort keys %{$env->vault->get($path)}],
		[qw(at hostname reason user)],
		'and no fifth key stands beside them');

	is(secret("$path:reason"), 'waiting on the capacity report',
		'the reason is the string it was given');

	like(secret("$path:at"),
		qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [-+]\d{4}$/,
		'the time is a value in EXODUS_TIME_FORMAT');
};

subtest 'the record round-trips through a fresh environment' => sub {
	# Ten rows and no run.  Every read is made through an environment
	# built after the write, so what comes back is what vault holds and
	# not what the writing object happens to remember.
	plan tests => 10;

	my $h    = held_prod();
	my $path = $h->env_path('prod').'/hold';

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
		'the reader answers with its four fields');
	is($record->{reason},   'the first hold',           'the reason came back');
	is($record->{user},     'operator',                 'the user came back');
	is($record->{hostname}, 'bastion.example.com',      'the hostname came back');
	is($record->{at},       '2026-09-18 10:04:12 -0400','the time came back');

	# A key of a shape set_hold never writes, standing at the path before the
	# replacing hold.  Without the clear inside set_hold it would still be
	# there afterwards, and nothing else in this file would notice, because
	# every other read of the key set goes through a reader that builds its
	# own four names.
	Genesis::Env->bare('prod', Genesis::Top->new($h->a))->with_vault
		->vault->set($path, released_by => 'somebody');

	Genesis::Env->bare('prod', Genesis::Top->new($h->a))->with_vault
		->set_hold(reason => 'the second hold');

	my $after = Genesis::Env->bare('prod', Genesis::Top->new($h->a))
		->with_vault;
	is($after->hold_record->{reason}, 'the second hold',
		'the later hold replaced the earlier one');
	no_secret "$path:released_by";
	is_deeply([sort keys %{$after->vault->get($path)}],
		[qw(at hostname reason user)],
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
	# Five rows, one of which is this row's own restoration assertion, since
	# the deploy is given restore => 0 and deployable_prod's own secrets run
	# contributes none.
	#
	# This row guards a property that already held before the writers landed.
	# The rewrite update_deployment_exodus makes removes the base blob with a
	# delete that is not recursive, so a key under <exodus_base>/hold was
	# always out of its reach, and the strategy calls T306 a gap in the
	# coverage rather than a defect in the code.  The row says what the
	# sibling path must go on meaning now that something writes to it.
	plan tests => 5;

	# The deploy is the real one, taken to success, because the rewrite this
	# row is about is the one update_deployment_exodus makes and only a
	# successful deploy makes it.  deployable_prod owns the five things that
	# takes.  The pipeline is off, because a pipeline-managed deploy first
	# switches to the environment's own branch and the branch it looks for is
	# not the slug the harness stands up.
	my $h = deployable_prod(pipeline => 0);

	my $top  = Genesis::Top->new($h->a);
	my $env  = Genesis::Env->bare('prod', $top)->with_vault;
	my $path = $env->set_hold(reason => 'waiting on the capacity report');

	my $w = snapshot_w($h);
	my (undef, $err, $exit) = run_genesis($h, {restore => 0},
		'prod', 'deploy', '-y');
	assert_w_restored($w, 'the deploy restored working state');
	is($exit, 0, 'the deploy succeeded')
		or diag($err);
	like($err, qr/updating exodus data for this deployment/,
		'and it rewrote the deployment data under the exodus base');

	is(secret("$path:reason"), 'waiting on the capacity report',
		'the sibling record survived the rewrite of the deployment data');

	# Read back through the reader the walk itself uses, which is the half of
	# T306 that says the record still holds the next run.  A record left
	# readable to safe but broken for the module would pass the row above
	# and fail this one.
	ok(Genesis::Env->bare('prod', Genesis::Top->new($h->a))
		->with_vault->hold_record,
		'and the reader still answers a hold for the next run');
};

done_testing;
