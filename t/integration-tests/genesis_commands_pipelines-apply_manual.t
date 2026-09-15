#!/usr/bin/env perl
# Proves T123: under the manual provider the apply creates each missing init
# branch, applies the protection, writes the applied record, contacts no
# Concourse target, and exits 0, and no environment carries a pipeline record
# until it has run.  The dry run is the same command writing nothing.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

subtest 'the manual provider gets everything but a pipeline' => sub {
	# Seven rows, and one more for the run's own restoration assertion, which
	# run_genesis makes unless a row turns it off.
	plan tests => 8;

	my $h  = make_harness(envs => ['qa', 'prod'], provider => 'manual', github => 1);
	my $gh = github_double($h, admin => 1);
	write_env_file($h, 'prod', pipeline => {prior_env => 'qa'});

	no_secret($h->env_path('qa') . '/pipeline:discovery',
		'no environment is known before the apply runs');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0');

	is_deeply(branches_on_r($h), [$h->control, 'prod/bosh', 'qa/bosh'],
		'every missing init branch was created');
	ok((grep {($_->{url} // '') =~ m{/rulesets}} gh_calls($gh)),
		'the protection was applied');
	have_secret($h->applied_path . ':provider',
		'the applied record was written');
	have_secret($h->env_path('qa') . '/pipeline:discovery',
		'and every environment now carries its pipeline record');

	# The run names Concourse where it tells the operator which providers do
	# host a pipeline, so what this row asks is whether a target was reached
	# for rather than whether the word was said.  Reaching for one runs fly,
	# and nothing on the manual path may run it.
	unlike(unfolded($out, $err), qr/\bfly\b/i,
		'no Concourse target was contacted');
};

subtest 'the dry run previews the whole command and writes nothing' => sub {
	# Eight rows, and one more for the run's own restoration assertion.  Four
	# of them read what the preview said and four ask what it left behind,
	# because a preview that reports a stage it silently performed and a
	# preview that performs nothing and reports nothing are each half of the
	# rule, and only the pair of them together is the rule.
	plan tests => 9;

	my $h  = make_harness(envs => ['qa'], provider => 'manual', github => 1);
	my $gh = github_double($h, admin => 1);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '--dry-run');
	my $said = unfolded($out, $err);

	is($exit, 0, 'the dry run exits 0');
	like($said, qr{would create \Qqa/bosh\E},
		'it names the branch it would create');
	like($said, qr{would protect \Qqa/bosh\E with \S},
		'and the branch it would protect, with the settings it would send');
	like($said, qr{would record the applied pipeline},
		'and the applied record it would write');

	is_deeply(branches_on_r($h), [$h->control],
		'no branch was created');
	ok(!(grep {($_->{url} // '') =~ m{/rulesets}} gh_calls($gh)),
		'no ruleset was sent');
	no_secret($h->applied_path . ':provider',
		'no record was written');
	no_secret($h->env_path('qa') . '/pipeline:discovery',
		'and no environment carries a pipeline record either');
};

done_testing;
