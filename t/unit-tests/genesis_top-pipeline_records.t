#!/usr/bin/env perl
# Proves T50, the two records having two paths and two owners, and T51,
# the applied record's address being unreachable from any environment.
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
use Genesis::Env;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the two records have two paths' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], type => 'bosh');
	my $top = Genesis::Top->new($h->a);
	my $env = Genesis::Env->bare('qa', $top);

	is($top->applied_record_path, '/secret/exodus/_pipelines/bosh',
		'the applied record sits under the mount with a leading underscore');
	is($top->applied_record_path, $h->applied_path,
		'the harness and the product agree on that address');

	is($env->pipeline_record_path, '/secret/exodus/qa/bosh/pipeline',
		"the environment's pipeline facts sit beside its own record");
	is($env->pipeline_record_path, $h->env_path('qa') . '/pipeline',
		'which is the address the harness writes');

	unlike($env->pipeline_record_path, qr{_pipelines},
		'and neither object spells the other path');
};

subtest 'each accessor reads its own path' => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], type => 'bosh');
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);

	my $top = Genesis::Top->new($h->a);
	my $env = Genesis::Env->bare('qa', $top);

	is($top->applied_record, undef, 'an absent applied record reads undef');
	is($env->pipeline_record, undef,
		'and an absent pipeline subpath reads undef, which is the membership test');

	fixture_applied($h, control => $control, provider => 'manual');
	fixture_pipeline_record($h, 'qa',
		dependencies => ['lab/bosh'], discovery => 'incomplete',
	);

	my $applied = Genesis::Top->new($h->a)->applied_record;
	is($applied->{control_commit}, $control, 'the applied commit comes back');
	is($applied->{provider}, 'manual', 'with the provider beside it');

	my $record = Genesis::Env->bare('qa', Genesis::Top->new($h->a))->pipeline_record;
	is_deeply($record->{dependencies}, ['lab/bosh'],
		'the compiled dependency set comes back');
	is($record->{discovery}, 'incomplete',
		"with discovery's incomplete mark beside it");
};

subtest 'no environment can claim the applied record address' => sub {
	plan tests => 4;

	my $err = Genesis::Env::_env_name_errors('_pipelines');
	ok($err, '_pipelines is not a valid environment name');
	like($err, qr{must start with a lowercase letter},
		'because a name must start with a lowercase letter');

	my $h = make_harness(envs => ['qa'], type => 'bosh');
	put_file($h->a . '/_pipelines.yml', "---\ngenesis:\n  env: _pipelines\n");
	my $top = Genesis::Top->new($h->a);

	my (undef, @errors) = Genesis::Env->is_valid_env_file('_pipelines', $top);
	like($errors[0], qr{Invalid environment name},
		'so a file named for it is refused');

	my $name = '_pipelines';
	isnt($top->applied_record_path, $top->deployment_slug_for($name),
		'and the record address is reachable by no environment slug');
};

done_testing;
