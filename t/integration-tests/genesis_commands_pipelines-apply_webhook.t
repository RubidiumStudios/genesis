#!/usr/bin/env perl
# Proves T475 (D145): with pipeline.provider.git.webhooks on, pipeline-apply
# owns the pipeline's webhook token and the GitHub push hook that uses it.  It
# writes a token where none is, leaves one that is, and replaces it on
# --rotate-webhook-token; it creates its one hook, reports it in place or
# updated, never touches a hook it does not own, and removes its own when
# webhooks are turned off.  No value is ever printed.  Without the rights to
# manage hooks, or at GitHub's limit, it says so and the apply goes on, and a
# dry run says what it would write and writes nothing.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/mkfile_or_fail mkdir_or_fail slurp run/;

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
	'exit 0', ''));

my $CHECK = qr{/api/v1/teams/main/pipelines/[^/]+/resources/control-branch/check/webhook};

sub harness {
	my $h = make_harness(envs => ['qa'], provider => 'concourse', github => 1);
	$h->set_repo_config('pipeline.provider.git.webhooks' => 'true');
	return $h;
}

sub apply {
	my ($h, @args) = @_;
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply', @args);
	return ($exit, "$out\n$err");
}

# The token where the store keeps it, at the pipeline scope, or undef.
sub token_of {
	my ($h) = @_;
	my $safe = Harness::Propagation::_real_safe();
	my ($paths) = run({env => {SAFE_TARGET => $h->fixture_vault}}, $safe, 'paths', 'concourse/main');
	my ($path) = grep {m{/webhook$}} split /\n/, $paths // '';
	return undef unless $path;
	my ($token, $rc) = run({env => {SAFE_TARGET => $h->fixture_vault}}, $safe, 'get', "$path:token");
	return $rc ? undef : $token;
}

sub our_hooks { grep {($_->{config}{url} // '') =~ $CHECK} @{gh_hooks($_[0]->{gh})} }

# The vault is one for the whole file, so a row that needs no token yet removes
# the one an earlier row's apply wrote.
sub forget_token {
	my ($h) = @_;
	my $safe = Harness::Propagation::_real_safe();
	my ($paths) = run({env => {SAFE_TARGET => $h->fixture_vault}}, $safe, 'paths', 'concourse/main');
	run({env => {SAFE_TARGET => $h->fixture_vault}, passfail => 1}, $safe, 'rm', '-f', $_)
		for grep {m{/webhook$}} split /\n/, $paths // '';
}

subtest 'a first apply writes the token and creates the hook' => sub {
	my $h = harness();
	forget_token($h);
	my ($exit, $said) = apply($h, '-y');
	is($exit, 0, 'the apply succeeds') or return diag($said);
	my $token = token_of($h);
	like($token // '', qr/^[0-9a-f]{32,}$/, 'a token of at least 128 bits is written');
	unlike($said, qr/\Q$token\E/, 'and never printed') if $token;
	my @ours = our_hooks($h);
	is(scalar(@ours), 1, 'one hook is created');
	like($ours[0]{config}{url} // '', qr/[?&]webhook_token=\Q$token\E$/, 'carrying the token') if $token;
	is_deeply($ours[0]{events}, ['push'], 'on push');
	like($said, qr/created.*hook|hook.*created/i, 'and reported created');

	($exit, $said) = apply($h, '-y');
	is($exit, 0, 'a second apply succeeds');
	is(token_of($h), $token, 'leaving the token as it was');
	is(scalar(our_hooks($h)), 1, 'and the one hook');
	like($said, qr/already in place/i, 'reported already in place');

	($exit, $said) = apply($h, '-y', '--rotate-webhook-token');
	is($exit, 0, 'a rotating apply succeeds');
	my $rotated = token_of($h);
	isnt($rotated, $token, 'replacing the token');
	like((our_hooks($h))[0]{config}{url} // '', qr/webhook_token=\Q$rotated\E$/, 'and the hook with it')
		if $rotated;
	like($said, qr/updated/i, 'reported updated');
};

subtest 'a hook it does not own is never touched' => sub {
	my $h = harness();
	my @theirs = ('https://chat.example.test/github',
		'https://ci.harness.example/api/v1/teams/main/pipelines/another-root/resources/control-branch/check/webhook?webhook_token=x');
	gh_hooks($h->{gh}, add => \@theirs);
	my ($exit, $said) = apply($h, '-y');
	is($exit, 0, 'the apply succeeds') or return diag($said);
	my @urls = map {$_->{config}{url}} @{gh_hooks($h->{gh})};
	ok((grep {$_ eq $theirs[0]} @urls), "another tool's hook stands");
	ok((grep {$_ eq $theirs[1]} @urls), "another root's hook stands");
	is(scalar(@urls), 3, 'beside the one it created');

	$h->set_repo_config('pipeline.provider.git.webhooks' => 'false');
	($exit, $said) = apply($h, '-y');
	is($exit, 0, 'an apply with webhooks off succeeds') or return diag($said);
	is_deeply([sort map {$_->{config}{url}} @{gh_hooks($h->{gh})}], [sort @theirs],
		'removing its own hook alone');
	like($said, qr/removed/i, 'and reporting it removed');
};

subtest 'without the rights to manage hooks the apply goes on' => sub {
	my $h = harness();
	gh_protection($h->{gh}, admin => 0);
	my ($exit, $said) = apply($h, '-y');
	is($exit, 0, 'the apply succeeds') or return diag($said);
	like($said, qr/unverified/i, 'reporting the hook unverified');
	like($said, $CHECK, 'and printing the URL to configure');
	my $token = token_of($h);
	unlike($said, qr/\Q$token\E/, 'without the token in it') if $token;
};

subtest 'at the limit GitHub sets, the apply goes on' => sub {
	my $h = harness();
	gh_hooks($h->{gh}, limit => 1, add => ['https://chat.example.test/github']);
	my ($exit, $said) = apply($h, '-y');
	is($exit, 0, 'the apply succeeds') or return diag($said);
	like($said, qr/cannot have more than 1 hooks?/i, "naming GitHub's refusal");
	like($said, qr/1 push hook/i, 'and the push hooks already there');
	is(scalar(our_hooks($h)), 0, 'creating none');
};

subtest 'a dry run says what it would write and writes nothing' => sub {
	my $h = harness();
	forget_token($h);
	my ($exit, $said) = apply($h, '--dry-run');
	is($exit, 0, 'the dry run succeeds') or return diag($said);
	like($said, qr/would generate/i, 'it would generate the token');
	like($said, qr/would create/i, 'and create the hook');
	unlike($said, qr/missing\s+webhook\.token/, 'the secret check counting the token as coming');
	is(token_of($h), undef, 'no token is written');
	is(scalar(our_hooks($h)), 0, 'and no hook made');
};

done_testing;
