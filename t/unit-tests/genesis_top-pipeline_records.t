#!/usr/bin/env perl
# Proves T50, the two records having two paths and two owners, T51, the
# applied record's address being unreachable from any environment, and
# T351's address half, the mount read from pipeline.exodus_mount with no
# environment loaded to learn it.
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

	my $h = make_harness(envs => ['qa'], type => 'bosh', vault => 1);
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

	my $h = make_harness(envs => ['qa'], type => 'bosh', vault => 1);
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

# The accessor that receives the record owns its correctness (D161).  What
# the vault gave it with fidelity and is still not an applied record is
# neither a record nor an absence: answered as a record it is compared
# against real commits and matches none, and answered as absent it is
# written over by the next apply.
subtest 'the applied record is judged by the accessor that receives it' => sub {
	plan tests => 13;

	my $h = make_harness(envs => ['qa'], type => 'bosh', vault => 1);
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);
	my $path = $h->applied_path;

	my %cases = (
		'no control commit' => {
			fields => {provider => 'manual', at => '2026-11-14 12:00:00 +0000'},
			says   => qr/holds at and provider, and no control_commit/,
		},
		'a control commit that is not a commit sha' => {
			fields => {control_commit => 'fatal: ambiguous argument', provider => 'manual'},
			says   => qr/its control_commit is "fatal: ambiguous argument", which is not a commit sha/,
		},
	);
	for my $case (sort keys %cases) {
		$h->_write_record($path, %{$cases{$case}{fields}});
		my $read = eval {Genesis::Top->new($h->a)->applied_record};
		my $raised = Genesis::raised($@);
		my $err  = ($@ // '') =~ s/\s+/ /gr;
		is($read, undef, "$case: nothing is answered");
		is($raised && $raised->state, 'invalid', "$case: it raises as an invalid record (D163)");
		is($raised && $raised->exitcode, Genesis::Exit::DATAERR, "$case: which exits DATAERR");
		like($err, qr/\Q$path\E is not a valid applied record/, "$case: it raises, naming the record");
		like($err, $cases{$case}{says}, "$case: and what it found there");
		like($err, qr/safe get \Q$path\E.*safe rm \Q$path\E.*genesis pipeline-apply/,
			"$case: and how to look at it and repair it");
		Genesis::run({env => {SAFE_TARGET => $h->{vault_target}}, stderr => 0},
			Harness::Propagation::_real_safe(), 'rm', '-f', $path);
	}

	# A record with only its control commit is one an older apply could have
	# written, and it is enough to route from.
	$h->_write_record($path, control_commit => $control);
	is_deeply(Genesis::Top->new($h->a)->applied_record, {control_commit => $control},
		'a record holding a control commit alone is accepted');
};

# The applied record is read by the reader every other record is read by, so
# a read the vault refuses says what theirs say: the path, the vault, the
# reason, and what to do about a refusal.  It had a reader of its own, which
# gave safe's bare words and named neither the path nor the vault.
subtest 'an applied record the vault refuses reads as every other refused record does' => sub {
	plan tests => 7;

	my $h = make_harness(envs => ['qa'], type => 'bosh', vault => 1);
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);
	fixture_applied($h, control => $control, provider => 'manual');
	my $path = $h->applied_path;
	break_vault_reads($h, $path);

	# The harness's safe goes on the path for the read, as a run's does.
	local $ENV{PATH} = "$h->{tmp}/bin:$ENV{PATH}" if -d "$h->{tmp}/bin";
	# Carp::Always, which the harness loads, appends a stack trace to every
	# die; the operator sees the message without it
	local $SIG{__DIE__} = 'DEFAULT';
	my $read = eval {Genesis::Top->new($h->a)->applied_record};
	my $raw  = $@ // '';
	my $raised = Genesis::raised($raw);
	my $err  = $raw =~ s/\s+/ /gr;
	is($read, undef, 'nothing is answered');
	is($raised && $raised->state, 'refused', 'the reader\'s error comes through whole, as a refusal');
	is($raised && $raised->exitcode, Genesis::Exit::NOPERM, 'which exits NOPERM (D163)');
	like($err, qr/Could not read \Q$path\E from vault at \S+: .*permission denied/,
		'it raises with the path, the vault and what the vault said');
	like($err, qr/The vault refused the read.*safe auth/, 'and what to do about a refusal');
	unlike($raw, qr/\[FATAL\]/, 'as text a caller can put in its own message, with no prefix of its own');
	unlike($raw, qr/\n[ \t]+\S/, 'and no wrap');
};

subtest 'no environment can claim the applied record address' => sub {
	plan tests => 4;

	my $err = Genesis::Env::_env_name_errors('_pipelines');
	ok($err, '_pipelines is not a valid environment name');
	like($err, qr{must start with a lowercase letter},
		'because a name must start with a lowercase letter');

	my $h = make_harness(envs => ['qa'], type => 'bosh', vault => 1);
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

	my $h = make_harness(envs => ['qa'], type => 'bosh', vault => 1);
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

	my $h = make_harness(envs => ['qa'], type => 'bosh', vault => 1);
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

subtest 'the record stage refuses a control commit that is not a sha' => sub {
	plan tests => 3;

	require Genesis::Commands::Pipelines;

	my $h = make_harness(envs => ['qa'], type => 'bosh', vault => 1);
	my $top = Genesis::Top->new($h->a);

	# Service::Git resolves a ref through git rev-parse, and that command
	# folds its own error text into the answer rather than failing, so a
	# clone missing the branch hands back a sentence beginning `fatal`
	# instead of a sha or an undef.  The stage refuses that before the
	# vault, because a record holding it would be compared against real
	# shas by every reader below and would never match one.
	my @reached;
	no warnings 'redefine';
	local *Genesis::Top::vault = sub {push @reached, 'vault'; return undef};

	local $ENV{GENESIS_IGNORE_EVAL} = '';
	my $wrote = eval {
		Genesis::Commands::Pipelines::_apply_records($top,
			control_commit => "fatal: ambiguous argument 'control'\ncontrol",
			provider       => 'manual')
	};
	my $err = $@;

	is($wrote, undef, 'the stage answers nothing');
	like($err, qr{not a commit sha},
		'and says the value it was given is not a commit sha');
	is_deeply(\@reached, [], 'and the vault was never reached');
};

# The record stage compares what is stored with what it compiled and writes
# the difference, so a read it could not make must stop it: answering such a
# read as nothing stored is how a record gets written over.
subtest 'the record stage writes nothing over a record it could not read' => sub {
	plan tests => 8;

	require Genesis::Commands::Pipelines;

	my $h = make_harness(envs => ['qa'], type => 'bosh', vault => 1);
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);
	my $top = Genesis::Top->new($h->a);
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	my @written;
	my $stage = sub {
		my (%opts) = @_;
		@written = ();
		my $ok = eval {
			Genesis::Commands::Pipelines::_apply_records($top,
				control_commit => $control, provider => 'manual', %opts);
			1;
		};
		return $ok ? '' : "$@";
	};

	no warnings 'redefine';
	{
		# The applied record cannot be read.
		local *Genesis::Top::applied_record = sub {
			my ($self, %fields) = @_;
			if (%fields) { push @written, 'applied'; return \%fields }
			die "Could not read /secret/exodus/_pipelines/bosh from vault at https://v:8200: Code: 403. permission denied\n";
		};
		local *Genesis::Env::pipeline_record = sub {
			my ($self, %fields) = @_;
			push @written, 'pipeline' if %fields;
			return undef;
		};
		like($stage->(), qr{Could not read /secret/exodus/_pipelines/bosh.*Code: 403}s,
			'an applied record that cannot be read stops the stage, with what the vault said');
		is_deeply(\@written, [], 'and nothing is written, the applied record least of all');
		like($stage->(dry_run => 1), qr{Code: 403}, 'a dry run stops on it too, and does not say what it would write');
	}
	{
		# The applied record is absent, and one environment's own record cannot be read.
		local *Genesis::Top::applied_record = sub {
			my ($self, %fields) = @_;
			if (%fields) { push @written, 'applied'; return \%fields }
			return undef;
		};
		local *Genesis::Env::pipeline_record = sub {
			my ($self, %fields) = @_;
			if (%fields) { push @written, 'pipeline'; return \%fields }
			die "Could not read /secret/exodus/qa/bosh/pipeline from vault at https://v:8200: connection refused\n";
		};
		my $err = $stage->() =~ s/\s+/ /gr;
		like($err, qr{Could not read /secret/exodus/qa/bosh/pipeline.*connection refused},
			"an environment's record that cannot be read stops the stage, with what the vault said");
		is_deeply(\@written, ['applied'], 'the applied record had been written, and no environment record after it');
		like($err, qr{applied pipeline.*was (?:written|updated|recorded)}i, 'the stage says what it had already written');
		like($err, qr{qa.*(?:was not|not written|not recorded)}i, 'and what it did not');
		like($err, qr{genesis pipeline-apply}, 'and the command that finishes it');
	}
};

subtest 'the address needs no environment' => sub {
	# T351's address half.  The mount is pipeline.exodus_mount, a key of the
	# pipeline itself, so the record's address is read off the configuration
	# and no environment is loaded to learn it, which is what lets a deploy
	# standing on a deployment branch address it with only its own file there.
	plan tests => 3;

	my $h = make_harness(envs => [], vault => 0);
	my $bare_loads = 0;
	no warnings 'redefine';
	my $bare = \&Genesis::Env::bare;
	local *Genesis::Env::bare = sub {$bare_loads++; goto &$bare};

	is(Genesis::Top->new($h->a, no_vault => 1)->applied_record_path,
		'/secret/exodus/_pipelines/'.$h->{type},
		'a pipeline with no environment addresses its record at the default mount');

	load_with($h, join("\n",
		'pipeline:', '  enabled: true', '  exodus_mount: /secret/other',
		'  source_control:', '    repository: genesis/bosh-deployments'));
	is(Genesis::Top->new($h->a, no_vault => 1)->applied_record_path,
		'/secret/other/_pipelines/'.$h->{type},
		'and at the mount the key names, normalised with its trailing slash');

	is($bare_loads, 0, 'without loading an environment to learn it');
};

done_testing;
