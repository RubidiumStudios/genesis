#!/usr/bin/env perl
# Proves T510 (D177): where GITHUB_AUTH_TOKEN is not set, pipeline-apply acts
# on GitHub with the token pipeline.source_control.api_token names, read from
# the provider's secrets store where Concourse reads it.
#
# The apply read its token from the operator's shell and nowhere else, so
# without one it skipped the branch protection and the push hook, in a
# repository whose own configuration named a token that could have set them.
#
# The rows read what the apply did with a token from the store, that the
# shell's token still wins, and that each way of having no token says why.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/mkfile_or_fail mkdir_or_fail run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# A fly that answers a version and a dry run, so a real apply reaches the end.
mkdir_or_fail("$ENV{HOME}/bin") unless -d "$ENV{HOME}/bin";
$ENV{GENESIS_FLY_BIN} = "$ENV{HOME}/bin/fly";
mkfile_or_fail("$ENV{HOME}/.flyrc",
	"targets:\n  harness-main:\n    api: https://ci.harness.example\n    team: main\n");
mkfile_or_fail("$ENV{HOME}/bin/fly", 0755, join("\n",
	'#!/bin/sh',
	'case "$*" in *--version*) echo 7.11.0; exit 0;; esac',
	'case "$*" in *--dry-run*) echo "jobs:"; exit 0;; esac',
	'case "$*" in *"pipelines --json"*) echo "[]"; exit 0;; esac', # none held yet (D184)
	'exit 0', ''));

my $CHECK  = qr{/api/v1/teams/main/pipelines/[^/]+/resources/control-branch/check/webhook};
my $STORED = 'the-token-the-store-holds';
my @SCOPES = ('concourse/main/bosh/gh', 'concourse/main/gh', 'concourse/shared/gh');

# A Concourse pipeline with webhooks on, whose api_token names gh:pipeline_admin
# unless the row says it names none.
sub harness {
	my (%o) = @_;
	my $h = make_harness(envs => ['qa'], provider => 'concourse', github => 1);
	$h->set_repo_config('pipeline.provider.git.webhooks' => 'true');
	$h->set_repo_config('pipeline.source_control.api_token' => 'gh:pipeline_admin')
		unless $o{no_key};
	# The vault is one for the whole file, so each row says where the token is.
	my $safe = Harness::Propagation::_real_safe();
	run({env => {SAFE_TARGET => $h->fixture_vault}, passfail => 1, stderr => 0},
		$safe, 'rm', '-f', $_) for @SCOPES;
	$h->_write_record($o{held_at}, pipeline_admin => $STORED) if $o{held_at};
	return $h;
}

# An apply with no token in the shell, unless the row gives it one.
sub apply {
	my ($h, $how, @args) = @_;
	my ($out, $err, $exit) = run_genesis($h, {restore => 0, no_token => 1, %$how},
		'pipeline-apply', @args);
	return ($exit, "$out\n$err");
}

sub our_hooks { grep {($_->{config}{url} // '') =~ $CHECK} @{gh_hooks($_[0]->{gh})} }
sub tokens    { my %seen = map {(($_->{token} // '(none)') => 1)} gh_calls($_[0]->{gh}); sort keys %seen }

subtest 'with no token in the shell, the apply uses the one api_token names' => sub {
	plan tests => 7;

	my $h = harness(held_at => 'concourse/main/gh');
	my ($exit, $said) = apply($h, {}, '-y');
	is($exit, 0, 'the apply succeeds') or diag($said);
	unlike($said, qr/skipped\s+the branch protection/, 'the branch protection is not skipped');
	unlike($said, qr/skipped\s+the GitHub webhook/, 'nor the push hook');
	is(scalar(our_hooks($h)), 1, 'and the hook is made');
	is_deeply([tokens($h)], [$STORED], 'every call to GitHub carried the token the store holds');
	like($said, qr{GitHub token at /concourse/main/gh:pipeline_admin.*pipeline\.source_control\.api_token}s,
		'the apply says where its token came from');
	unlike($said, qr/\Q$STORED\E/, 'and never prints it');
};

subtest 'the token is found where Concourse would find it' => sub {
	plan tests => 2;

	my $h = harness(held_at => 'concourse/shared/gh');
	my ($exit, $said) = apply($h, {}, '-y');
	is($exit, 0, 'the apply succeeds') or diag($said);
	like($said, qr{GitHub token at /concourse/shared/gh:pipeline_admin},
		'at the shared path, where the team scope holds none');
};

# The token the repository names is known to be the one for this
# repository.  The shell's may be there for another reason altogether.
subtest "the store's token wins over the shell's" => sub {
	plan tests => 3;

	my $h = harness(held_at => 'concourse/main/gh');
	my ($exit, $said) = apply($h, {no_token => 0}, '-y');
	is($exit, 0, 'the apply succeeds') or diag($said);
	is_deeply([tokens($h)], [$STORED], 'every call carried the token the store holds');
	like($said, qr{GitHub token at /concourse/main/gh:pipeline_admin.*in place of GITHUB_AUTH_TOKEN}s,
		'and the apply says it set the shell\'s aside');
};

subtest "the shell's token serves where the store gives none" => sub {
	plan tests => 5;

	my $h = harness();
	my ($exit, $said) = apply($h, {no_token => 0}, '-y', '--missing-secrets-ok');
	is($exit, 0, 'with the reference found nowhere the apply succeeds') or diag($said);
	is_deeply([tokens($h)], [$h->{gh}{token}], 'every call carried the token the shell gave');
	like($said, qr{using GITHUB_AUTH_TOKEN, as gh\.pipeline_admin, which pipeline\.source_control\.api_token names, is at none of},
		'and the apply says why it is the shell\'s');

	$h = harness(no_key => 1);
	($exit, $said) = apply($h, {no_token => 0}, '-y');
	is_deeply([tokens($h)], [$h->{gh}{token}], 'with no api_token the shell\'s is used as it always was');
	unlike($said, qr/using GITHUB_AUTH_TOKEN|GitHub token at/, 'with nothing said of it');
};

# The token a pipeline task is given where api_token is unset (contract f8),
# so the apply acts with the one the pipeline itself will (D178).
subtest "with no api_token, an https clone credential's password is the token" => sub {
	plan tests => 4;

	my $h = harness(no_key => 1);
	$h->set_repo_config('pipeline.source_control.auth.type' => 'https');
	$h->set_repo_config('pipeline.source_control.auth.path' => 'gh');
	$h->_write_record('concourse/main/gh', username => 'bot', password => $STORED);
	my ($exit, $said) = apply($h, {}, '-y');
	is($exit, 0, 'the apply succeeds') or diag($said);
	is_deeply([tokens($h)], [$STORED], 'every call to GitHub carried the password the store holds');
	like($said, qr{GitHub token at /concourse/main/gh:password, which pipeline\.source_control\.auth names},
		'and the apply says the clone credential named it');
	unlike($said, qr/\Q$STORED\E/, 'never printing it');
};

subtest 'a dry run reads the token too' => sub {
	plan tests => 3;

	my $h = harness(held_at => 'concourse/main/gh');
	my ($exit, $said) = apply($h, {}, '--dry-run');
	is($exit, 0, 'the dry run succeeds') or diag($said);
	unlike($said, qr/skipped\s+the branch protection/, 'and says what it would protect');
	is(scalar(our_hooks($h)), 0, 'making no hook');
};

subtest 'with no token anywhere, each skip says why' => sub {
	plan tests => 8;

	my ($exit, $said) = apply(harness(no_key => 1), {}, '-y');
	is($exit, 0, 'with no api_token the apply goes on') or diag($said);
	like($said, qr/skipped\s+the branch protection, because GITHUB_AUTH_TOKEN is not set and pipeline\.source_control\.api_token names no token/,
		'saying neither gave one');
	like($said, qr/skipped\s+the GitHub webhook, because GITHUB_AUTH_TOKEN is not set and pipeline\.source_control\.api_token names no token/,
		'for the hook as for the protection');

	($exit, $said) = apply(harness(), {}, '-y', '--missing-secrets-ok');
	is($exit, 0, 'with the token found nowhere the apply goes on') or diag($said);
	like($said, qr{skipped\s+the branch protection, because GITHUB_AUTH_TOKEN is not set and gh\.pipeline_admin, which pipeline\.source_control\.api_token names, is at none of /concourse/main/bosh/gh, /concourse/main/gh, /concourse/shared/gh},
		'naming the reference and every path it looked at');

	($exit, $said) = apply(harness(held_at => 'concourse/main/gh'), {}, '-y', '--skip-vault');
	is($exit, 0, 'with the vault skipped the apply goes on') or diag($said);
	like($said, qr/skipped\s+the branch protection, because GITHUB_AUTH_TOKEN is not set and the token pipeline\.source_control\.api_token names was not read \(--skip-vault was given\)/,
		'saying the token was not read, and why');
	unlike($said, qr/\Q$STORED\E/, 'and no value is printed on any of the three');
};

done_testing;
