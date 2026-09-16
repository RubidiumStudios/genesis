#!/usr/bin/env perl
# Proves T152, T173, T174, and T175: the four held qualifiers in their exact
# forms, one outcome per environment in scope, one line per routed control
# commit, and overwrote-hand-edit per file.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The environment file a row commits by hand, written here for the reason the
# hold rows write one: the harness's own writer commits without publishing,
# and every file it lays down has to carry the shared ops file, because a
# commit that changes a file no environment tracks changes nothing any
# environment's set holds.
sub env_file {
	my (%opts) = @_;
	my @lines = (
		'---', 'kit:', '  name:    dev', '  version: latest',
		'  features: []', 'genesis:', "  env: $opts{env}", '  pipeline:',
	);
	push @lines, "    prior_env: $opts{prior}" if $opts{prior};
	push @lines, '    track_additional_files:', '    - ops/shared.yml';
	push @lines, "leaf: $opts{leaf}" if defined $opts{leaf};
	return join("\n", @lines, '');
}

subtest 'three holds print three exact forms' => sub {
	# Five rather than four, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 5;

	# lab leads the chain, qa follows it, prod follows qa, and dev has never
	# been applied at all.  So qa waits on lab, prod is held by a hold
	# somebody wrote, and dev waits on the command that cuts its branch.
	my $h = make_harness(kit => 'omega-v2.7.0', chained => 1,
		tracked => ['ops/shared.yml'],
		envs    => ['lab', 'qa', 'prod', 'dev']);
	# Every environment but dev, which is left with no branch at all so that
	# it reads as one the pipeline has never been applied to.
	$h->ready_envs(envs => ['lab', 'qa', 'prod']);
	fixture_hold($h, 'prod', reason => 'waiting on the DBA');
	commit_on_control($h,
		files => {
			'ops/shared.yml' => "---\nshared: 4\n",
			'qa.yml'         => env_file(env => 'qa', prior => 'lab', leaf => 4),
		},
		message => 'Bump shared ops and tune qa', push => 1);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	like($err, qr/held, awaiting deployment \(lab at control\@[0-9a-f]+\)/,
		'the awaiting-deployment form');
	like($err, qr/held, needs clearing \(waiting on the DBA\)/,
		'the needs-clearing form');
	like($err, qr/held, awaiting pipeline-apply/,
		'the awaiting-pipeline-apply form');
	like($err, qr/held by .?lab.?/, 'the reason per commit sits beneath it');
};

subtest 'five environments, five outcomes, none omitted' => sub {
	plan tests => 7;

	my $h = make_harness(kit => 'omega-v2.7.0', chained => 1,
		tracked => ['ops/shared.yml'],
		envs    => ['lab', 'qa', 'prod', 'dev', 'sandbox']);
	$h->ready_envs;
	commit_on_control($h,
		files   => {'lab.yml' => env_file(env => 'lab', leaf => 6)},
		message => 'Tune lab', push => 1);
	break_vault($h, envs => ['prod']);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	for my $env (qw/lab qa prod dev sandbox/) {
		like($err, qr/^\s*\Q$env\E\b/m, "$env appears in the report");
	}
	like($err, qr/\bidempotent\b/,
		'an environment with nothing due reads idempotent rather than being omitted');
};

subtest 'four routed commits, four lines, delivered or held' => sub {
	plan tests => 6;

	my $h = make_harness(kit => 'omega-v2.7.0', chained => 1,
		tracked => ['ops/shared.yml'], envs => ['lab', 'qa']);
	$h->ready_envs;

	my @due;
	for my $n (1, 2) {
		push @due, commit_on_control($h,
			files   => {'qa.yml' => env_file(env => 'qa', prior => 'lab', leaf => $n)},
			message => "Tune qa $n", push => 1);
		certify($h, 'lab', control_commit => $due[-1]);
	}
	push @due, commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: 9\n"},
		message => 'Bump shared ops', push => 1);
	push @due, commit_on_control($h,
		files   => {'qa.yml' => env_file(env => 'qa', prior => 'lab', leaf => 4)},
		message => 'Tune qa 4', push => 1);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	like($err, qr/\Q@{[substr($due[0], 0, 7)]}\E.*delivered/,
		'the first is delivered');
	like($err, qr/\Q@{[substr($due[1], 0, 7)]}\E.*delivered/,
		'the second is delivered');
	like($err, qr/\Q@{[substr($due[2], 0, 7)]}\E.*held/, 'the third is held');
	like($err, qr/\Q@{[substr($due[3], 0, 7)]}\E.*held/,
		'the fourth is held with it');
	unlike($err, qr/entry point/i, 'the retired term appears nowhere');
};

subtest 'an overwritten hand edit is named beside its commit' => sub {
	plan tests => 3;

	my $h = make_harness(kit => 'omega-v2.7.0', chained => 1,
		tracked => ['ops/shared.yml'], envs => ['lab', 'qa']);
	$h->ready_envs;

	hand_commit($h, $h->slug('qa'),
		files   => {'ops/shared.yml' => "---\nshared: edited by hand\n"},
		message => 'Patch the shared ops in place');

	my $due = commit_on_control($h,
		files   => {'qa.yml' => env_file(env => 'qa', prior => 'lab', leaf => 7)},
		message => 'Tune qa', push => 1);
	certify($h, 'lab', control_commit => $due);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	like($err, qr/overwrote-hand-edit/, 'the file axis has its word');
	like($err,
		qr/overwrote-hand-edit.*ops\/shared\.yml|ops\/shared\.yml.*overwrote-hand-edit/,
		'the file is named beside it');
};

done_testing;
