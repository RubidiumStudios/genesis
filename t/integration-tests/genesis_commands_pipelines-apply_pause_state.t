#!/usr/bin/env perl
# Proves T520: the pause state a real pipeline-apply leaves a Concourse
# pipeline in is the one pipeline.provider.pipeline_state_after_apply names,
# or --paused or --unpaused for the one run (D184).  A stub fly logs every
# call and answers `pipelines --json` with the state a row says Concourse
# holds; the harness names its Concourse https://ci.harness.example, team
# main, and its pipeline is bosh.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/mkfile_or_fail mkdir_or_fail slurp/;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $KEY = 'pipeline.provider.pipeline_state_after_apply';

my $log = "$ENV{HOME}/fly.log";
mkdir_or_fail("$ENV{HOME}/bin");
$ENV{GENESIS_FLY_BIN} = "$ENV{HOME}/bin/fly";
mkfile_or_fail("$ENV{HOME}/.flyrc",
	"targets:\n  harness-main:\n    api: https://ci.harness.example\n    team: main\n");

# What Concourse holds beside the pipeline under test: one of another name
# in this team and one of this name in another team, each in the state the
# pipeline under test is not in, so a row that read either reads wrong.
sub listing {
	my ($found) = @_;
	my $other = ($found // '') eq 'paused' ? 'false' : 'true';
	return '[' . join(',',
		qq({"name":"cf","paused":$other,"public":false,"team_name":"main"}),
		qq({"name":"bosh","paused":$other,"public":false,"team_name":"other"}),
		(defined $found
			? sprintf('{"name":"bosh","paused":%s,"public":false,"team_name":"main"}',
				$found eq 'paused' ? 'true' : 'false')
			: ()),
	) . "]\n";
}

# A fly that logs its arguments and answers:
#   found   - `pipelines --json` with the pipeline paused or unpaused, without
#             it where undef, or with a failure where it is 'unreadable'
#   changed - set-pipeline --dry-run with a change, or with none where false
sub stub_fly {
	my (%opts) = @_;
	my $found   = $opts{found};
	my $changed = exists $opts{changed} ? $opts{changed} : 1;
	unlink $log;

	my $dry  = "$ENV{HOME}/bin/fly-dry-run.txt";
	my $list = "$ENV{HOME}/bin/fly-pipelines.json";
	mkfile_or_fail($dry, $changed
		? "jobs:\n  job deploy-qa has changed:\n  + serial: true\n"
		: "no changes to apply\n");
	my $unreadable = ($found // '') eq 'unreadable';
	mkfile_or_fail($list, $unreadable ? '' : listing($found));

	mkfile_or_fail("$ENV{HOME}/bin/fly", 0755, join("\n",
		'#!/bin/sh',
		"echo \"\$*\" >> '$log'",
		'case "$*" in *--version*) echo 7.11.0; exit 0;; esac',
		"case \"\$*\" in *--dry-run*) cat '$dry'; exit 0;; esac",
		($unreadable
			? 'case "$*" in *"pipelines --json"*) echo "error: not authorized" >&2; exit 1;; esac'
			: "case \"\$*\" in *\"pipelines --json\"*) cat '$list'; exit 0;; esac"),
		'exit 0', ''));
}

sub fly_calls { -f $log ? grep {!/--version/} split /\n/, slurp($log) : () }

# The calls that pause, set or unpause, in the order they were made.
sub fly_verbs {
	map {/\b(pause-pipeline|set-pipeline|unpause-pipeline)\b/ ? $1 : ()}
		grep {!/--dry-run|validate-pipeline/} fly_calls();
}

# One apply against a fly in the state named, answering its exit code and
# what it said.  The apply writes branches and records, so no restoration row.
sub apply_with {
	my ($h, $fly, @flags) = @_;
	stub_fly(%$fly);
	my (undef, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply', '-y', @flags);
	return ($exit, unfolded($err));
}

subtest 'with no key, a pipeline is left as the apply found it' => sub {
	plan tests => 16;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');

	# Found running.
	my ($exit, $said) = apply_with($h, {found => 'unpaused'});
	is($exit, 0, 'found unpaused: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [qw/pause-pipeline set-pipeline unpause-pipeline/],
		'it is paused for the set and unpaused after') or diag(join("\n", fly_calls()));
	my @calls = fly_calls();
	my ($read)  = grep {$calls[$_] =~ /pipelines --json/} 0..$#calls;
	my ($pause) = grep {$calls[$_] =~ /\bpause-pipeline/} 0..$#calls;
	ok(defined $read && defined $pause && $read < $pause,
		'the state is read before the pipeline is paused') or diag(join("\n", @calls));
	like($said, qr/unpaused bosh: as it was found/, 'and the apply says it is unpaused, as found');
	like($said, qr/\Q$KEY\E: unchanged/, 'naming the key and its value');

	# Found paused.
	($exit, $said) = apply_with($h, {found => 'paused'});
	is($exit, 0, 'found paused: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [qw/pause-pipeline set-pipeline/],
		'it is set and not unpaused') or diag(join("\n", fly_calls()));
	like($said, qr/(?<!un)paused bosh: as it was found/, 'the apply says it is paused, as found');
	like($said, qr/--unpaused/, 'and names the flag that starts it');

	# Not there yet.
	($exit, $said) = apply_with($h, {found => undef});
	is($exit, 0, 'a new pipeline: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [qw/pause-pipeline set-pipeline/],
		'it is set and not unpaused') or diag(join("\n", fly_calls()));
	like($said, qr/(?<!un)paused bosh: a new pipeline.*--unpaused/,
		'the apply says a new pipeline is left paused, naming the flag that starts it');

	# Nothing to set.
	($exit, $said) = apply_with($h, {found => 'paused', changed => 0});
	is($exit, 0, 'nothing changed: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [], 'it neither pauses, sets nor unpauses')
		or diag(join("\n", fly_calls()));
	like($said, qr/already set/, 'it says the pipeline is already set');
	like($said, qr/(?<!un)paused bosh: as it was found/, 'and that it is paused, as found');
};

subtest 'a state that cannot be read stops the apply before it pauses' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	my ($exit, $said) = apply_with($h, {found => 'unreadable'});
	isnt($exit, 0, 'the apply refuses') or diag($said);
	is_deeply([fly_verbs()], [], 'nothing was paused or set')
		or diag(join("\n", fly_calls()));
	like($said, qr/whether.*bosh.*is paused.*--paused.*--unpaused/,
		'it says what it could not read, and names the flags that need no reading');
};

subtest 'a flag says the state for the one run' => sub {
	plan tests => 12;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');

	my ($exit, $said) = apply_with($h, {found => 'unpaused'}, '--paused');
	is($exit, 0, '--paused: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [qw/pause-pipeline set-pipeline/],
		'a pipeline found unpaused is left paused') or diag(join("\n", fly_calls()));
	like($said, qr/(?<!un)paused bosh: as --paused asks/, 'and the apply says so, naming the flag');

	($exit, $said) = apply_with($h, {found => 'paused'}, '-U');
	is($exit, 0, '-U: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [qw/pause-pipeline set-pipeline unpause-pipeline/],
		'a pipeline found paused is unpaused') or diag(join("\n", fly_calls()));
	like($said, qr/unpaused bosh: as --unpaused asks/, 'and the apply says so, naming the flag');

	# Nothing to set, and the state is still the one asked for.
	($exit, $said) = apply_with($h, {found => 'paused', changed => 0}, '--unpaused');
	is($exit, 0, '--unpaused with nothing changed: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [qw/unpause-pipeline/],
		'the pipeline is unpaused and not set again') or diag(join("\n", fly_calls()));
	like($said, qr/unpaused bosh: as --unpaused asks/, 'and the apply says so');

	# Both, which is no answer.  The reason given is not asserted: a usage
	# error under test prints the command's help in its place.
	stub_fly(found => 'unpaused');
	my (undef, undef, $both) = run_genesis($h, 'pipeline-apply', '-y', '-P', '-U');
	is($both, 2, '-P with -U is a usage error');
	is_deeply([fly_calls()], [], 'and fly is never asked anything');
};

subtest 'the key says the state, and a flag beats it' => sub {
	plan tests => 15;

	my $paused = make_harness(envs => ['qa'], provider => 'concourse');
	$paused->set_repo_config($KEY, 'paused');

	my ($exit, $said) = apply_with($paused, {found => 'unpaused'});
	is($exit, 0, 'paused: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [qw/pause-pipeline set-pipeline/],
		'a pipeline found unpaused is left paused') or diag(join("\n", fly_calls()));
	like($said, qr/(?<!un)paused bosh: as \Q$KEY\E asks/, 'and the apply says so, naming the key');

	($exit, $said) = apply_with($paused, {found => 'unpaused', changed => 0});
	is($exit, 0, 'paused, with nothing changed: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [qw/pause-pipeline/],
		'the pipeline is paused and not set again') or diag(join("\n", fly_calls()));
	like($said, qr/(?<!un)paused bosh: as \Q$KEY\E asks/, 'and the apply says so');

	($exit, $said) = apply_with($paused, {found => 'paused'}, '--unpaused');
	is($exit, 0, 'paused, with --unpaused: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [qw/pause-pipeline set-pipeline unpause-pipeline/],
		'the flag wins and the pipeline is unpaused') or diag(join("\n", fly_calls()));
	like($said, qr/unpaused bosh: as --unpaused asks/, 'and the apply names the flag, not the key');

	my $unpaused = make_harness(envs => ['qa'], provider => 'concourse');
	$unpaused->set_repo_config($KEY, 'unpaused');

	($exit, $said) = apply_with($unpaused, {found => 'paused'});
	is($exit, 0, 'unpaused: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [qw/pause-pipeline set-pipeline unpause-pipeline/],
		'a pipeline found paused is unpaused') or diag(join("\n", fly_calls()));
	like($said, qr/unpaused bosh: as \Q$KEY\E asks/, 'and the apply says so, naming the key');

	($exit, $said) = apply_with($unpaused, {found => 'unpaused'}, '-P');
	is($exit, 0, 'unpaused, with -P: the apply succeeds') or diag($said);
	is_deeply([fly_verbs()], [qw/pause-pipeline set-pipeline/],
		'the flag wins and the pipeline is left paused') or diag(join("\n", fly_calls()));
	like($said, qr/(?<!un)paused bosh: as --paused asks/, 'and the apply names the flag, not the key');
};

done_testing;
