#!/usr/bin/env perl
# Proves T337 and T338: two deployment roots sharing an environment name are
# reported separately, each with its own label, branch, and reading, and every
# line of the mapping table has a fixture giving the reading, the routing
# result, and the divergence state that line names.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use JSON::PP qw/decode_json/;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $SHARED = 'lmelt-vsphere-canwest-1-mgmt';

# An environment file that parses and cannot be loaded, which is the situation
# the mapping table's error line names.  It names a kit this repository does
# not hold, so Genesis::Env::is_valid_env_file still reads it as an
# environment and Genesis::Top::load_env cannot load it, and the row gets the
# per-environment failure of D60.  A file no YAML reader will take is a
# different fault: the command refuses the whole repository before it reads a
# row, and no line of the mapping table is about that.
sub ghost_env_file {
	my ($env) = @_;
	return join("\n", '---', 'kit:', '  name:    ghost', '  version: 9.9.9',
		'  features: []', 'genesis:', "  env: $env", '  pipeline:',
		'    track_additional_files:', '    - ops/shared.yml', '');
}

subtest 'two roots sharing an environment name never share a reading' => sub {
	# A guard.  D66 settles the per-root reading by construction, since each
	# root composes its branches from its own deployment slug, so every row
	# here was green the day it was written and no code landed with it.  It
	# stands because nothing else in the suite runs one command in each of two
	# roots: it catches a reader that took one branch per environment name, as
	# the baseline's status did, and one that read either root's label or type
	# off whichever Genesis::Top it happened to be holding.
	#
	# Nine assertions and one restoration for each of the two commands.
	plan tests => 11;

	my $h = make_harness(envs => [$SHARED], type => 'bosh',
		kit => 'omega-v2.7.0');
	add_deployment_root($h, type => 'vault', envs => [$SHARED],
		kit => 'omega-v2.7.0');

	# The bosh root is delivered and certified, and the vault root is
	# delivered and never certified, so the two readings differ and a marker
	# read across the roots would show up as one reading in both.
	$h->ready_envs(envs => [$SHARED]);
	$h->ready_envs(envs => [$SHARED], type => 'vault', root => 'vault',
		certified => []);

	set_repo_config($h, 'pipeline.name', 'canwest-bosh');
	set_repo_config($h, 'pipeline.name', 'canwest-vault', root => 'vault');
	refresh($h, 'a');

	my ($bosh_out, undef, $bosh_exit) = run_genesis($h, 'pipeline-status', '--json');
	my ($vault_out, undef, $vault_exit) =
		run_genesis($h, {dir => 'vault'}, 'pipeline-status', '--json');

	is($bosh_exit, 0, 'the command reports the bosh root');
	is($vault_exit, 0, 'and the vault root when it is run in it');

	my $bosh  = decode_json($bosh_out);
	my $vault = decode_json($vault_out);

	is($bosh->{pipeline}, 'canwest-bosh', 'each root carries its own label');
	is($vault->{pipeline}, 'canwest-vault', 'and the second names itself');
	is($bosh->{type}, 'bosh', 'the deployment type stands beside the label');
	is($vault->{type}, 'vault', 'and it is the type that tells the roots apart');

	is($bosh->{environments}[0]{branch},  "$SHARED/bosh",
		'the bosh root reads its own branch');
	is($vault->{environments}[0]{branch}, "$SHARED/vault",
		'the vault root reads its own branch');
	isnt($bosh->{environments}[0]{reading}, $vault->{environments}[0]{reading},
		"one root's marker never becomes the other root's reading");
};

subtest 'every line of the mapping table has its reading' => sub {
	# Four of the six lines below were green the day they were written, and
	# they are guards.  The mapping table is the document's promise that every
	# situation the six status strings covered still has a reading, so the
	# whole table is walked rather than the two lines that needed code: a row
	# left out is a situation an operator used to see and would stop seeing
	# without anything failing.  Together they catch a read model that answered
	# one reading for two different situations, and one that dropped a
	# situation and answered nothing for it.
	my @lines = (
		{name => 'no branch anywhere', build => sub {
			my ($h) = @_;
			commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
		 }, reading => 'not-propagated', routing => qr/awaiting pipeline-apply/,
		    divergence => undef},

		{name => 'the init commit alone', build => sub {
			my ($h) = @_;
			my $c = commit_on_control($h,
				files => {'ops/shared.yml' => "---\none\n"}, push => 1);
			init_branch($h, 'env');
			fixture_applied($h, control => $c);
			fixture_pipeline_record($h, 'env');
		 }, reading => 'unseeded', routing => qr/unseeded/, divergence => 'in-sync'},

		{name => 'the environment fails to load', build => sub {
			my ($h) = @_;
			init_branch($h, 'env');
			my $c = commit_on_control($h,
				files => {'env.yml' => ghost_env_file('env')}, push => 1);
			fixture_applied($h, control => $c);
		 }, reading => 'not-propagated', routing => qr/load error/,
		    divergence => 'in-sync'},

		{name => 'delivered and deployed', build => sub {
			my ($h) = @_;
			my $c = commit_on_control($h,
				files => {'ops/shared.yml' => "---\none\n"}, push => 1);
			init_branch($h, 'env');
			deliver($h, 'env', copy => 'a', control => $c);
			certify($h, 'env', control_commit => $c);
			fixture_applied($h, control => $c);
			fixture_pipeline_record($h, 'env');
		 }, reading => 'deployed', routing => qr/deployed/, divergence => 'in-sync'},

		{name => 'delivered and awaiting its deploy', build => sub {
			my ($h) = @_;
			my $c1 = commit_on_control($h,
				files => {'ops/shared.yml' => "---\none\n"}, push => 1);
			init_branch($h, 'env');
			deliver($h, 'env', copy => 'a', control => $c1);
			certify($h, 'env', control_commit => $c1);
			my $c2 = commit_on_control($h,
				files => {'ops/shared.yml' => "---\ntwo\n"}, push => 1);
			deliver($h, 'env', copy => 'a', control => $c2);
			fixture_applied($h, control => $c2);
			fixture_pipeline_record($h, 'env');
		 }, reading => 'pending-deploy', routing => qr/awaiting deployment/,
		    divergence => 'in-sync'},

		{name => 'the seed, annotated on pending', build => sub {
			my ($h) = @_;
			# Deployed before the pipeline existed, then seeded with the
			# branch's first delivery, which is the one marked commit the
			# annotation turns on.
			my $c0 = commit_on_control($h,
				files => {'ops/first.yml' => "---\nfirst\n"}, push => 1);
			init_branch($h, 'env');
			certify($h, 'env', control_commit => $c0);
			my $c1 = commit_on_control($h,
				files => {'ops/shared.yml' => "---\none\n"}, push => 1);
			deliver($h, 'env', copy => 'a', control => $c1);
			fixture_applied($h, control => $c1);
			fixture_pipeline_record($h, 'env');
		 }, reading => 'pending-deploy', routing => qr/seeded/, divergence => 'in-sync'},
	);

	# Three assertions per line, and one restoration for each of the two
	# commands each line runs.
	plan tests => scalar(@lines) * 5;

	for my $line (@lines) {
		my $h = make_harness(envs => ['env'], kit => 'omega-v2.7.0',
			tracked => ['ops/shared.yml']);
		fixture_vault($h);
		$line->{build}->($h);
		refresh($h, 'a');

		my ($json) = run_genesis($h, 'pipeline-status', '--json');
		my $row = decode_json($json)->{environments}[0];

		is($row->{reading}, $line->{reading}, "$line->{name}: the reading");
		is($row->{divergence} ? $row->{divergence}{state} : undef,
			$line->{divergence}, "$line->{name}: the divergence");

		my ($tree) = run_genesis($h, 'pipeline-status');
		like(unfolded($tree), $line->{routing}, "$line->{name}: the routing result")
			or diag($tree);
	}
};

done_testing;
