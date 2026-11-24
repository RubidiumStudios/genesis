#!/usr/bin/env perl
# Proves T523: a real pipeline-apply under Concourse refuses a control whose
# embedded Genesis is not the one running the apply, before it writes
# anything, and --embed-mismatch-ok has it go on (D189).  Every task of the
# pipeline runs .genesis/bin/genesis from its branch, so the two differing
# means a pipeline compiled by one Genesis and run by another.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/mkfile_or_fail mkdir_or_fail slurp run/;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $log = "$ENV{HOME}/fly.log";
mkdir_or_fail("$ENV{HOME}/bin");
$ENV{GENESIS_FLY_BIN} = "$ENV{HOME}/bin/fly";
mkfile_or_fail("$ENV{HOME}/.flyrc",
	"targets:\n  harness-main:\n    api: https://ci.harness.example\n    team: main\n");
mkfile_or_fail("$ENV{HOME}/bin/fly", 0755, join("\n",
	'#!/bin/sh',
	"echo \"\$*\" >> '$log'",
	'case "$*" in *--version*) echo 7.11.0; exit 0;; esac',
	'case "$*" in *--dry-run*) echo "jobs:"; exit 0;; esac',
	'case "$*" in *"pipelines --json"*) echo "[]"; exit 0;; esac',
	'exit 0', ''));

sub fly_sets { -f $log ? grep {/set-pipeline/ && !/--dry-run/} split /\n/, slurp($log) : () }

sub apply {
	my ($h, @args) = @_;
	unlink $log;
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply', @args);
	return ($exit, unfolded($out, $err));
}

sub remote_refs {
	my ($h) = @_;
	my ($out) = run({dir => $h->a}, 'git', 'ls-remote', $h->r);
	return $out;
}

# Another Genesis at control: a file that is not the one running the apply.
sub embed_another {
	my ($h) = @_;
	my $root = $h->{root} ? "$h->{root}/" : '';
	$h->commit_on_control(message => 'embed another genesis', push => 1,
		files => {"${root}.genesis/bin/genesis" => "#!/bin/sh\n# some other genesis\nexit 0\n"});
}

subtest 'the Genesis running the apply is the one embedded at control' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	my ($exit, $said) = apply($h, '-y');
	is($exit, 0, 'the apply succeeds') or diag($said);
	ok(scalar(fly_sets()), 'and sets the pipeline');
	unlike($said, qr/genesis embed/, 'saying nothing of the embedded Genesis');
};

subtest 'another Genesis at control is refused before anything is written' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	embed_another($h);
	my $before = remote_refs($h);

	my ($exit, $said) = apply($h, '-y');
	is($exit, Genesis::Exit::CONFIG, 'the apply refuses at the configuration exit') or diag($said);
	like($said, qr/Refusing to apply.*embedded/s, 'saying the embedded Genesis is why');
	like($said, qr/genesis embed.*commit.*\.genesis\/bin\/genesis/s,
		'and naming the steps: embed, commit, and getting it to control');
	is(remote_refs($h), $before, 'no deployment branch was created on the remote');
	is_deeply([fly_sets()], [], 'and the pipeline was not set');
};

subtest '--embed-mismatch-ok goes on, and says so' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	embed_another($h);

	my ($exit, $said) = apply($h, '-y', '--embed-mismatch-ok');
	is($exit, 0, 'the apply succeeds') or diag($said);
	ok(scalar(fly_sets()), 'and sets the pipeline');
	like($said, qr/embedded.*--embed-mismatch-ok/s, 'with a warning naming the mismatch and the flag');
};

subtest 'no Genesis embedded at control is refused too' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], provider => 'concourse', embed => 0);
	my ($exit, $said) = apply($h, '-y');
	is($exit, Genesis::Exit::CONFIG, 'the apply refuses at the configuration exit') or diag($said);
	like($said, qr/No Genesis is embedded/, 'saying none is embedded');
	like($said, qr/genesis embed/, 'and naming the command that embeds one');
};

subtest 'a dry run warns where a real apply would refuse' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], provider => 'concourse');
	embed_another($h);

	my ($exit, $said) = apply($h, '--dry-run');
	is($exit, 0, 'the dry run goes through') or diag($said);
	like($said, qr/embedded.*real apply refuses/s, 'saying a real apply refuses');
};

subtest 'the manual provider has no task to run it, so nothing is checked' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa']);
	my ($exit, $said) = apply($h);
	is($exit, 0, 'an apply with no Genesis embedded succeeds') or diag($said);
	unlike($said, qr/genesis embed/, 'saying nothing of one');
};

done_testing;
