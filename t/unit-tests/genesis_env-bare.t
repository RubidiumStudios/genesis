#!/usr/bin/env perl
# Proves T55, an environment read without a deployment behind it, T56, an
# inherited pipeline key found through the merged read, which the load and
# the topology share now the compiler's leaf-only reader is gone, and T312,
# the same merged read from whichever branch the checkout stands on.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $LEAF = 'lmelt-vsphere-canwest-1-mgmt';
my $SITE = 'lmelt-vsphere-canwest';
# A per-environment pipeline key the site file carries and the leaf
# does not.  It is a key no capability gates, because these rows are
# about where a value is found rather than about what a provider can
# do with it, and the harness leaves the repository on the manual
# provider, which can do none of the six.
my $TRACKED = ['ops/<env>.yml'];

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
		site => $SITE, pipeline_keys => {track_additional_files => $TRACKED},
		leaf_keys => {prior_env => 'lmelt-vsphere-canwest-1-lab'});
	# The predecessor the leaf names is an environment of the repository, as
	# every prior_env has to be where the shape is read.
	commit_on_control($h, message => 'the predecessor the leaf names', push => 1,
		files => {'lmelt-vsphere-canwest-1-lab.yml'
			=> "---\ngenesis:\n  env: lmelt-vsphere-canwest-1-lab\n"});
	my $top = Genesis::Top->new($h->a, no_vault => 1);

	# The compiler's leaf-only reader, the hazard's shape, is gone (D117):
	# the topology and the load read the same merged hierarchy, so the
	# load-time read answers what lookup answers.
	is_deeply($top->_merged_env_params($LEAF)->{genesis}{pipeline}{track_additional_files},
		$TRACKED, 'the load-time read finds the inherited key');

	my $env = Genesis::Env->bare($LEAF, $top);
	is_deeply(scalar($env->lookup('genesis.pipeline.track_additional_files')), $TRACKED,
		'the merged read returns the site file value');
	is($env->lookup('genesis.pipeline.prior_env'),
		'lmelt-vsphere-canwest-1-lab',
		'and the nearer file still wins for a key the leaf sets');
};

subtest 'the merged read is the same from either branch' => sub {
	plan tests => 4;

	my $h = inherited_harness(envs => [$LEAF], type => 'bosh', vault => 0,
		site => $SITE, pipeline_keys => {track_additional_files => $TRACKED},
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

		is_deeply(scalar($env->lookup('genesis.pipeline.track_additional_files')), $TRACKED,
			"the site file's value is found while standing on $branch");
		ok(!defined($env->{kit}), "with no kit loaded on $branch");
	}
};

subtest 'bare reads of the same files share one merge' => sub {
	plan tests => 4;

	# The walk reads an environment afresh at every commit it crosses, each
	# time from a new checkout of the commit's tree.  The merged manifest is
	# cached by a file name the files' content decides, so a read whose
	# files match an earlier read's takes that merge rather than repeating
	# it, and a read whose parent file differs gets a merge of its own.
	my $checkout = sub {
		my ($region) = @_;
		my $top = make_top(name => 'thing', no_vault => 1);
		put_file($top->path('us.yml'), "---\nparams:\n  region: $region\n");
		put_file($top->path('us-west.yml'), "---\ngenesis:\n  env: us-west\n");
		return Genesis::Top->new($top->path, no_vault => 1);
	};

	my $merges = 0;
	my $merge  = \&Genesis::Env::ManifestProvider::merge;
	no warnings 'redefine';
	local *Genesis::Env::ManifestProvider::merge = sub {$merges++; goto &$merge};

	is(Genesis::Env->bare('us-west', $checkout->('one'))->lookup('params.region'),
		'one', 'the first read answers from its own merge');
	my $after_first = $merges;

	is(Genesis::Env->bare('us-west', $checkout->('one'))->lookup('params.region'),
		'one', 'a read of the same files in another checkout answers the same');
	is($merges, $after_first, 'and takes the first merge rather than merging again');

	is(Genesis::Env->bare('us-west', $checkout->('two'))->lookup('params.region'),
		'two', 'while a changed parent file is merged afresh, never served stale');
};

done_testing;
