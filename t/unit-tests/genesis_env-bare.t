#!/usr/bin/env perl
# Proves T55, an environment read without a deployment behind it, T56, an
# inherited pipeline key found through the merged read where the
# compiler's leaf-only reader misses it, and T312, the same merged read
# from whichever branch the checkout stands on.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Exception;

use Genesis;
use Genesis::Top;
use Genesis::Env;
use Genesis::CI::Compiler::ASTBuilder;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $LEAF = 'lmelt-vsphere-canwest-1-mgmt';
my $SITE = 'lmelt-vsphere-canwest';
my $CRON = '0 3 * * *';

subtest 'an environment can be read without a deployment' => sub {
	plan tests => 5;

	my $h   = make_harness(envs => ['qa'], type => 'bosh', vault => 0);
	write_env_file($h, 'qa', pipeline => {require_pr => 1});
	my $top = Genesis::Top->new($h->a, no_vault => 1);

	my $env = Genesis::Env->bare('qa', $top);
	isa_ok($env, 'Genesis::Env', 'bare returns an environment');
	is($env->name, 'qa', 'which knows its name');
	ok(!defined($env->{kit}), 'and has no kit behind it');
	ok(!-d $top->path('dev'), 'with no kit directory on disk either');

	is($env->lookup('genesis.pipeline.require_pr'), 1,
		'and it answers lookup for a genesis.pipeline key');
};

subtest 'is_valid_env_file runs on the same constructor' => sub {
	plan tests => 5;

	my $h   = make_harness(envs => ['qa'], type => 'bosh', vault => 0);
	my $top = Genesis::Top->new($h->a, no_vault => 1);

	ok(Genesis::Env->is_valid_env_file('qa', $top),
		'a written environment file is valid');

	my (undef, @errors) = Genesis::Env->is_valid_env_file('nowhere', $top);
	like($errors[0], qr{does not exist},
		'a missing file is reported by the shared check');

	my (undef, @name_errors) = Genesis::Env->is_valid_env_file('Nope', $top);
	like($name_errors[0], qr{Invalid environment name},
		'and so is a name the rules refuse');

	# The point of the shared constructor is that the two readers say the
	# same thing, which no assertion above this one actually compares.
	my (undef, @bare_errors) =
		Genesis::Env->_bare_with_errors('nowhere', $top);
	my (undef, @file_errors) =
		Genesis::Env->is_valid_env_file('nowhere', $top);
	is_deeply(\@bare_errors, \@file_errors,
		'both readers report the missing file in the same words');

	throws_ok {Genesis::Env->_bare_with_errors('qa')}
		qr{No 'top' specified when checking an environment name and file},
		'and the check names what it needed, whichever reader called it';
};

subtest 'the merged read finds an inherited key the leaf lacks' => sub {
	plan tests => 3;

	my $h   = inherited_harness(envs => [$LEAF], type => 'bosh', vault => 0,
		site => $SITE, pipeline_keys => {redeploy_cron => $CRON},
		leaf_keys => {prior_env => 'lmelt-vsphere-canwest-1-lab'});
	my $top = Genesis::Top->new($h->a, no_vault => 1);

	# The hazard's shape, which the compiler story fixes and this step
	# does not: the baseline reader opens the leaf alone, finds the key
	# absent, and says nothing about it.
	my $leaf_only = Genesis::CI::Compiler::ASTBuilder::_read_genesis_pipeline_keys(
		$top->path("$LEAF.yml")
	);
	is($leaf_only->{redeploy_cron}, undef,
		'the leaf-only reader finds the inherited key absent, with no error');

	my $env = Genesis::Env->bare($LEAF, $top);
	is($env->lookup('genesis.pipeline.redeploy_cron'), $CRON,
		'the merged read returns the site file value');
	is($env->lookup('genesis.pipeline.prior_env'),
		'lmelt-vsphere-canwest-1-lab',
		'and the nearer file still wins for a key the leaf sets');
};

subtest 'the merged read is the same from either branch' => sub {
	plan tests => 4;

	my $h = inherited_harness(envs => [$LEAF], type => 'bosh', vault => 0,
		site => $SITE, pipeline_keys => {redeploy_cron => $CRON},
		leaf_keys => {prior_env => 'lmelt-vsphere-canwest-1-lab'});

	# The delivery was published from copy B, so copy A knows the deployment
	# branch by its remote-tracking ref alone and cannot stand on it until
	# its own ref is put where R stands.
	my $slug = $h->slug($LEAF);
	local_branch($h, $slug, at => "origin/$slug");

	for my $branch ($h->control, $slug) {
		stand_on($h, $branch);
		my $top = Genesis::Top->new($h->a, no_vault => 1);
		my $env = Genesis::Env->bare($LEAF, $top);

		is($env->lookup('genesis.pipeline.redeploy_cron'), $CRON,
			"the site file's value is found while standing on $branch");
		ok(!defined($env->{kit}), "with no kit loaded on $branch");
	}
};

done_testing;
