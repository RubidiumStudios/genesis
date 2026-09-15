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
use Genesis::Exit;
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

subtest "the environment reads its record through its own vault" => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], type => 'bosh');
	fixture_pipeline_record($h, 'qa', dependencies => ['lab/bosh']);

	my $top = Genesis::Top->new($h->a);
	my $env = Genesis::Env->bare('qa', $top);
	my $path = $env->pipeline_record_path;

	# An environment that sets genesis.vault keeps its exodus record, and so
	# the pipeline subpath beside it, in a vault of its own, and reading that
	# subpath through the repository's vault would answer undef and drop the
	# environment out of the walk.  The harness cannot stand a second live
	# vault up beside its own to show that, because spinning one switches the
	# safe target the repository's default vault resolves through and the two
	# stop being tellable apart in one process.  So the environment's own
	# vault is stood in for, and the stand-in answers a set the harness never
	# wrote.  The stand-in is the shared one, because more than one row in
	# the suite reads through a vault it did not spin.
	my @asked;
	my $own = standin_vault(\@asked,
		{dependencies => 'other/bosh', discovery => 'incomplete'});
	no warnings 'redefine';
	local *Genesis::Env::vault = sub {$own};

	my $record = $env->pipeline_record;

	is_deeply(\@asked, [$path],
		"the environment's own vault is the one asked, at its own path");
	is_deeply($record->{dependencies}, ['other/bosh'],
		'and the set that vault holds is the one that comes back');
	is($record->{discovery}, 'incomplete', 'with the mark beside it');
};

subtest 'a write with no value for any field refuses before the vault' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], type => 'bosh');
	my $top = Genesis::Top->new($h->a);

	# The vault is stood in for by a sub that records being reached and
	# answers nothing, so a guard that ran after the handle was asked for
	# would both leave its mark in the ledger and die on an undefined
	# handle rather than on the sentence this row is looking for.  The
	# address is composed before the guard runs and composes without a
	# vault, so nothing in the ledger can come from that.
	my @reached;
	no warnings 'redefine';
	local *Genesis::Top::vault = sub {push @reached, 'vault'; return undef};

	local $ENV{GENESIS_IGNORE_EVAL} = '';
	my $wrote = eval {
		$top->applied_record(control_commit => undef, provider => undef)
	};
	my $err = $@;

	is($wrote, undef, 'the write answers nothing');
	# The sentence is matched along with the field names, because the stack
	# trace a die carries here repeats the argument list, and a row reading
	# for the names alone would find them there whatever raised the death.
	like($err,
		qr{asked to write the applied record.*control_commit.*provider.*at}s,
		'and names the three fields it was given no value for');
	is_deeply(\@reached, [], 'and the vault was never reached');
};

subtest 'a pipeline with no environment cannot address its record' => sub {
	plan tests => 3;

	my $h = make_harness(envs => [], vault => 0);

	local $ENV{GENESIS_IGNORE_EVAL} = '';
	my $path = eval {
		Genesis::Top->new($h->a, no_vault => 1)->applied_record_path
	};
	my $err = $@;

	is($path, undef, 'the address does not answer');
	like($err, qr{no environment to resolve},
		'and the refusal says there is nothing to read the mount from');

	# An exit code only exists in a process that exits, and bail dies rather
	# than exiting whenever it is reached from inside an eval, which a test
	# file always is.  So the refusal is provoked in a process of its own and
	# its status is read back from there.
	my $cmd = sprintf(
		q{%s -I%s/lib -MGenesis::Top -e '}.
		q{Genesis::Top->new($ARGV[0], no_vault => 1)->applied_record_path}.
		q{' %s},
		$^X, $helper::TOPDIR, $h->a
	);
	run_fails($cmd, Genesis::Exit::CONFIG,
		'the refusal exits Genesis::Exit::CONFIG');
};

done_testing;
