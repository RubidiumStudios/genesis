#!/usr/bin/env perl
# Proves the composing half of T2: each named scenario leaves the state its
# name says, and a row that wants something else passes options through.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'ready_envs does the five things a walking row needs' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['lab', 'qa']);
	ready_envs($h);

	ok(remote_sha($h, $h->slug('lab')), 'lab has its branch on R');
	ok(remote_sha($h, $h->slug('qa')), 'and so does qa');
	ok(record_at($h, $h->applied_path), 'the applied record is written');
	ok(record_at($h, $h->env_path('lab')), "and lab's certified commit");
};

subtest 'the named shapes each add the one thing their name says' => sub {
	plan tests => 5;

	my $ready = ready_harness();
	ok(record_at($ready, $ready->applied_path), 'ready_harness is walked');

	my $seeded = seeded_harness();
	isnt(harness_marker($seeded, $seeded->slug('qa')), undef,
		'seeded_harness carries a delivery');

	my $due = due_harness();
	isnt(tip_of($due, $due->control), harness_marker($due, $due->slug('qa')),
		'due_harness leaves a control commit undelivered');

	my $held = held_harness();
	ok(record_at($held, $held->env_path('prod') . '/hold'),
		'held_harness carries the hold record');

	my $pr = ready();
	ok($pr->{gh}, 'ready stands the GitHub double up for PR mode');
};

subtest 'a row that wants something else passes options through' => sub {
	plan tests => 2;

	my $h = ready_harness(envs => ['lab', 'qa', 'prod'], type => 'vault');
	is($h->type, 'vault', 'the type reached make_harness');
	ok(remote_sha($h, $h->slug('prod')),
		'and the third environment has its branch');
};

subtest 'the second deployment root is delivered under its own prefix' => sub {
	plan tests => 3;

	my $h = two_roots();
	my $second = files_at($h, $h->slug('lab', type => 'vault'));
	ok(exists $second->{'vault/lab.yml'},
		"the second root's branch holds its own environment file");
	ok(!exists $second->{'lab.yml'},
		"and not the first root's");
	ok(exists files_at($h, $h->slug('lab'))->{'lab.yml'},
		"while the first root's branch holds its own");
};

subtest 'the scenarios that write on control publish it' => sub {
	plan tests => 4;

	my $t = tracked_harness(qw/lab ops/);
	is(remote_sha($t, $t->control), tip_of($t, $t->control),
		'tracked_harness leaves control on R where copy A stands');
	like(slurp($t->a . '/qa.yml'), qr{lab/bosh},
		'and qa names the prerequisite it tracks');

	my $i = inherited_harness();
	is(remote_sha($i, $i->control), tip_of($i, $i->control),
		'inherited_harness leaves control on R where copy A stands');
	like(slurp($i->a . '/site.yml'), qr/manual_gate/,
		'and the pipeline keys sit on the site file');
};

subtest 'the pair, and one delivery per environment in one line' => sub {
	plan tests => 4;

	my $two = two_env_harness();
	isnt(harness_marker($two, $two->slug('lab')), undef,
		'two_env_harness delivers lab');
	isnt(harness_marker($two, $two->slug('qa')), undef, 'and qa');

	my $bare = ready_harness(delivered => []);
	is(harness_marker($bare, $bare->slug('qa')), undef,
		'a harness asked for no delivery has none');
	isnt(harness_marker($bare->deliver_all, $bare->slug('qa')), undef,
		'and deliver_all gives every environment one');
};

subtest 'the one-line shapes that stand on a scenario' => sub {
	plan tests => 9;

	my $h = ready_harness();
	is(a_delivery($h, 'qa'), remote_sha($h, $h->slug('qa')),
		'a_delivery publishes the delivery it wrote');

	my ($s, $control, $delivered) = seeded();
	is(harness_marker($s, $s->slug('qa')), $control,
		"seeded's branch marker names the control commit it answers");
	is($delivered, remote_sha($s, $s->slug('qa')),
		'and the delivered sha it answers is the branch tip');

	my $due = ready_harness(envs => ['qa']);
	my $taken = harness_marker($due, $due->slug('qa'));
	my @two = two_due($due);
	is(scalar(@two), 2, 'two_due lays two control commits');
	is(harness_marker($due, $due->slug('qa')), $taken,
		'and the branch has taken neither');

	is(scalar(my @three = three_due(ready_harness(envs => ['qa']))), 3,
		'three_due lays three');
	is(scalar(my @same = three(ready_harness(envs => ['qa']))), 3,
		'and three lays the same, because it is the same sub');

	my @chain = chain($h);
	is(scalar(@chain), 2, 'chain writes one control commit per environment');
	like(files_at($h, $chain[-1])->{'qa.yml'}, qr/kit: \{name: dev\}/,
		'chain touches one environment per commit, in order');
};

subtest 'the shapes that write a record or a configuration' => sub {
	plan tests => 4;

	my $h = ready_harness(envs => ['qa']);
	my ($body) = run({dir => $h->a}, 'git', 'log', '-1', '--format=%B',
		gated($h, files => {'gate.yml' => "---\ng: 1\n"}));
	like($body, qr/Genesis-Stage: prod/, 'gated puts the stage on its commit');

	proposed($h, 'qa', pr => 7);
	is(record_at($h, $h->env_path('qa') . '/proposed')->{number}, 7,
		'proposed writes the record naming the pull request');

	like(slurp(automated($h)->a . '/.genesis/config'), qr/concourse/,
		'automated names the provider the repository runs under');

	isa_ok(top_for(make_harness(envs => ['qa'], vault => 0)), 'Genesis::Top',
		'the Top top_for answers');
};

subtest 'top_for can replace the whole configuration first' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0, pipeline => 1);
	like(slurp($h->a . '/.genesis/config'), qr/pipeline/,
		'the repository starts with a pipeline section');

	top_for($h, config => {version => 2, deployment_type => 'bosh',
		creator_version => '3.2.0'});
	unlike(slurp($h->a . '/.genesis/config'), qr/pipeline/,
		'and the config option writes the whole file over it');
};

done_testing;
