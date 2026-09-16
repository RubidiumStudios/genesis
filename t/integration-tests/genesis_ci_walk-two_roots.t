#!/usr/bin/env perl
# Proves T320: two deployment roots that share an environment name walk
# their own branches, read their own markers, and land apart.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis::CI::Walk ();

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $ENV_NAME = 'lmelt-vsphere-canwest-1-mgmt';

# An environment file in the shape write_env_file writes, with one parameter
# changed, so a commit on control is a delta the walk can route.  It composes
# a string and builds no state, so it stays beside the rows that read it.
sub tuned_env_file {
	my ($n) = @_;
	return "---\nkit:\n  name:    dev\n  version: latest\n  features: []\n"
	     . "genesis:\n  env: $ENV_NAME\nparams:\n  tuned: $n\n";
}

subtest 'each root walks the branch its own slug names' => sub {
	# Six rows, and one restoration assertion for each of the two runs.
	plan tests => 8;

	my $h = make_harness(envs => [$ENV_NAME], type => 'bosh', root => 'bosh',
		kit => 'omega-v2.7.0');
	add_deployment_root($h, type => 'vault', envs => [$ENV_NAME],
		path => 'vault', kit => 'omega-v2.7.0');
	$h->ready_envs(envs => [$ENV_NAME]);
	$h->ready_envs(envs => [$ENV_NAME], type => 'vault', root => 'vault');

	my $bosh_slug  = $h->slug($ENV_NAME, type => 'bosh');
	my $vault_slug = $h->slug($ENV_NAME, type => 'vault');
	isnt($bosh_slug, $vault_slug, 'the two slugs differ');

	my $bosh_due = commit_on_control($h,
		files   => {"bosh/$ENV_NAME.yml" => tuned_env_file(1)},
		message => 'Tune the bosh deployment', push => 1);
	my $vault_due = commit_on_control($h,
		files   => {"vault/$ENV_NAME.yml" => tuned_env_file(1)},
		message => 'Tune the vault deployment', push => 1);

	run_genesis($h, {answers => ['y'], dir => 'bosh'}, 'propagate');
	run_genesis($h, {answers => ['y'], dir => 'vault'}, 'propagate');

	is(harness_marker($h, $bosh_slug), $bosh_due,
		'the bosh branch names the bosh commit');
	is(harness_marker($h, $vault_slug), $vault_due,
		'the vault branch names the vault commit');
	isnt(harness_marker($h, $bosh_slug), $vault_due,
		'the bosh branch never read the vault marker');
	isnt(harness_marker($h, $vault_slug), $bosh_due,
		'the vault branch never read the bosh marker');

	assert_snapshot_invariant($h, $ENV_NAME, type => 'bosh', root => 'bosh',
		name => 'the bosh deployment holds its own set alone');
};

subtest 'scope_for composes every branch through the deployment slug' => sub {
	plan tests => 7;

	my $h = make_harness(envs => ['lab', 'qa'], type => 'bosh', root => 'bosh',
		chained => 1, vault => 0);
	add_deployment_root($h, type => 'vault', envs => ['lab', 'qa'],
		path => 'vault');

	my $bosh  = top_for($h, root => 'bosh');
	my $vault = top_for($h, root => 'vault');

	my ($whole) = Genesis::CI::Walk::scope_for($bosh);
	is_deeply([map {$_->{env}} @$whole], ['lab', 'qa'],
		'a run that narrows nothing walks the whole topology in DAG order');
	is_deeply([map {$_->{branch}} @$whole], ['lab/bosh', 'qa/bosh'],
		'every branch is composed from the deployment slug');
	is_deeply([map {$_->{type}} @$whole], ['bosh', 'bosh'],
		'every entry names the type this root declares');

	my ($beside) = Genesis::CI::Walk::scope_for($vault);
	is_deeply([map {$_->{branch}} @$beside], ['lab/vault', 'qa/vault'],
		'the root beside it composes branches of its own');

	my ($narrowed) = Genesis::CI::Walk::scope_for($bosh, scope => ['qa']);
	is_deeply([map {$_->{env}} @$narrowed], ['qa'],
		'a scope narrows the list to the environments it names');
	is($narrowed->[0]{prior_env}, 'lab',
		'a narrowed environment still reads the ancestor it inherits from');
	is($narrowed->[0]{depth}, 1,
		'and still reads the depth the whole topology gives it');
};

done_testing;
